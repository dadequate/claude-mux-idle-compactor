#!/usr/bin/env bash
# core.sh -- discovery, locking, and logging primitives for idle-compactor.sh.
# Split out (like prompt_heuristics.sh) so tests/test_core.sh can exercise
# this logic directly, with fake TMUX_BIN/CLAUDE_MUX_BIN stubs, without
# needing a live tmux session or a real claude-mux install.
#
# Every function here reads its config from the env vars set by the caller
# (idle-compactor.sh sets sane defaults; tests override them to point at
# stubs/fixtures). Nothing in this file runs on its own -- it only defines
# functions.

# ---------------------------------------------------------------------------
# Logging (append-only, size-capped by truncating to the last N lines)
# ---------------------------------------------------------------------------
log() {
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "[$ts] $*" >> "$LOG_FILE"
}

rotate_log_if_needed() {
    [[ -f "$LOG_FILE" ]] || return 0
    local line_count
    line_count=$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d '[:space:]')
    [[ -z "$line_count" ]] && return 0
    [[ "$line_count" =~ ^[0-9]+$ ]] || return 0
    if (( line_count > LOG_MAX_LINES )); then
        local dropped=$(( line_count - LOG_MAX_LINES ))
        local tmp
        if ! tmp="$(mktemp "${LOG_FILE}.XXXXXX" 2>/dev/null)"; then
            log "WARN: log rotation skipped -- mktemp failed (check $LOG_DIR is writable)"
            return 0
        fi
        if tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$LOG_FILE"
            log "log rotated, $dropped line(s) dropped"
        else
            log "WARN: log rotation skipped -- failed writing truncated copy"
            rm -f "$tmp"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Locking -- macOS has no flock(1) (that's a Linux util-linux tool), so use an
# atomic mkdir-based lock instead. A stale lock (process died without hitting
# the EXIT trap -- SIGKILL, reboot mid-run) is broken after LOCK_STALE_SECONDS
# so the watcher can't go permanently silent from one bad run.
# ---------------------------------------------------------------------------
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        return 0
    fi

    local lock_age now lock_mtime
    now=$(date +%s)
    lock_mtime=$(stat -f '%m' "$LOCK_DIR" 2>/dev/null || echo "$now")
    lock_age=$(( now - lock_mtime ))

    if (( lock_age > LOCK_STALE_SECONDS )); then
        log "WARN: breaking stale lock at $LOCK_DIR (age ${lock_age}s, likely a killed prior run)"
        rm -rf "$LOCK_DIR"
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo $$ > "$LOCK_DIR/pid"
            return 0
        fi
    fi

    log "another run holds the lock ($LOCK_DIR, age ${lock_age}s) -- skipping this cycle"
    return 1
}

release_lock() {
    rm -rf "$LOCK_DIR"
}

# ---------------------------------------------------------------------------
# Preflight -- launchd gives jobs a bare PATH (/usr/bin:/bin:/usr/sbin:/sbin)
# that does NOT include /opt/homebrew/bin, where tmux actually lives on this
# Mac. The plist template sets PATH explicitly to cover this, but check here
# too (belt-and-suspenders against a future plist edit dropping it, or the
# script being run some other way) -- fail loud and distinctly, rather than
# silently doing nothing indistinguishable from "no candidates this cycle."
# ---------------------------------------------------------------------------
preflight_check() {
    local missing=()
    command -v "$TMUX_BIN" >/dev/null 2>&1 || missing+=("tmux ($TMUX_BIN)")
    [[ -x "$CLAUDE_MUX_BIN" ]] || command -v "$CLAUDE_MUX_BIN" >/dev/null 2>&1 || missing+=("claude-mux ($CLAUDE_MUX_BIN)")
    # bc backs the min-context-size gate's float comparison. Ships standard on
    # macOS (not a Homebrew dependency), so this should never actually fire --
    # but that gate silently no-ops (proceeds as if context were large enough)
    # if bc is missing, and a preflight FATAL beats a quietly-skipped feature.
    command -v bc >/dev/null 2>&1 || missing+=("bc")

    if (( ${#missing[@]} > 0 )); then
        log "FATAL: required command(s) not found: ${missing[*]} -- PATH=$PATH"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

# parse_session_table <status> -- prints one session name per line from
# `claude-mux -L --status <status>` table output. Table format:
#   | # | Status | Session | Directory |
# Field 4 (1-indexed after splitting on '|') is the Session column. Strips the
# "> " marker claude-mux prepends to the calling session, if present.
#
# Logs a distinct WARN if the claude-mux call itself fails (non-zero exit),
# so an operator reading the log can tell "claude-mux is broken" apart from
# "claude-mux ran fine and found zero matching sessions" -- those look
# identical downstream (both yield an empty candidate list) unless we say so
# here.
parse_session_table() {
    local status="$1"
    local output
    if ! output=$("$CLAUDE_MUX_BIN" -L --status "$status" 2>&1); then
        log "WARN: 'claude-mux -L --status $status' exited non-zero -- treating as zero candidates this cycle. Output: $output"
        return 0
    fi
    echo "$output" | \
        grep -E '^\| [0-9]+ \|' | \
        awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $4); print $4}' | \
        sed 's/^> //'
}

# get_idle_seconds <session> -- swappable idle-duration source (deliberately
# kept as a single small function we can revise). Uses tmux's window_activity
# timestamp, NOT pane_activity -- empirically, single-window/single-pane
# claude-mux sessions never populate #{pane_activity} (tested against the real
# fleet on 2026-08-31), while #{window_activity} does, gated on claude-mux's
# own `monitor-activity on` setting (claude-mux sets this per-session by
# default -- TMUX_MONITOR_ACTIVITY=true). Verified empirically that this value
# holds steady across a 20s passive-observation window on a real stale
# session (no spinner/redraw noise bumping it while nothing is happening).
#
# The "=<session>:" target form (exact session match, empty window spec) is
# required, not cosmetic: a bare session name does unambiguous-PREFIX matching
# in tmux, so e.g. `-t demo` silently resolves to `demo-two` if `demo` doesn't
# exist as an exact session -- confirmed live against a real fleet.
# "=name" alone works for has-session but NOT for capture-pane/display
# in this tmux version (3.7b); "=name:" (trailing colon, empty window part)
# is the form that resolves to the exact session's active window/pane in both.
#
# Echoes the idle duration in seconds on stdout; returns 1 (no output) if the
# activity timestamp can't be determined, so callers must treat "unknown" as
# "not a candidate," never as "definitely idle."
get_idle_seconds() {
    local session="$1"
    local activity
    activity=$("$TMUX_BIN" display -p -t "=${session}:" '#{window_activity}' 2>/dev/null)
    [[ -z "$activity" ]] && return 1
    [[ "$activity" =~ ^[0-9]+$ ]] || return 1
    echo $(( $(date +%s) - activity ))
}

# session_has_live_tmux <session> -- defense-in-depth check (candidates are
# already drawn from claude-mux's `running` status, which implies a live tmux
# session, but this is cheap and protects against a filter bug or a session
# that died in the gap between the -L snapshot and now).
session_has_live_tmux() {
    local session="$1"
    "$TMUX_BIN" has-session -t "=${session}" 2>/dev/null
}

# extract_context_tokens_k <pane_text> -- pulls the current context size, in
# thousands of tokens, out of Claude Code's own "new task? /clear to save
# 239.9k tokens" footer hint (present in every fixture/real pane captured
# against the fleet). Echoes a bare number like "239.9" on stdout; returns 1
# (no output) if the hint isn't present in this capture.
#
# Why this exists: research into prior art for this exact problem (see
# README.md's "Cost model" section) found that compacting a session with very
# little accumulated context is close to pure downside -- it still costs a
# summarization request, but there's little to shrink and reuse-after-idle
# data suggests small-context sessions are also less likely to be resumed at
# all. This is a swappable, best-effort signal (same spirit as
# get_idle_seconds): if the hint isn't present, callers should proceed as
# before rather than block -- this is a cost-optimization gate, not a safety
# gate, so "unknown" should not mean "skip" the way it does for idle duration.
extract_context_tokens_k() {
    local text="$1"
    local match
    match=$(grep -oE '/clear to save [0-9.]+k tokens' <<< "$text" | grep -oE '[0-9.]+' | head -1)
    [[ -z "$match" ]] && return 1
    echo "$match"
}
