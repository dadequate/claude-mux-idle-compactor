#!/usr/bin/env bash
# idle-compactor.sh -- auto-compacts claude-mux sessions right before their
# Claude Code prompt cache goes cold, so a session that's been sitting idle
# doesn't eat a full cache-rewrite the next time it's resumed. See README.md
# for the full rationale.
#
# IMPORTANT CANDIDATE-RULE NOTE (read before touching the discovery logic):
# claude-mux's `idle` status literally means "no live tmux session at all" --
# confirmed by reading claude-mux's own status_claude_sessions() function.
# Within a live tmux session, claude-mux only distinguishes `protected` vs
# `running`; `running` just means a claude process exists under the pane, NOT
# that it's mid-turn. So the actual target population for this tool -- a
# session that finished its turn and has been sitting quietly -- reports as
# `running`, not `idle`. This is a deliberate design choice, not an oversight:
# candidates are drawn from `running` (never `protected`), and pane staleness
# (get_idle_seconds) is what actually detects "finished its turn" -- it is
# the load-bearing signal here, not a secondary refinement. Do not "fix" this
# back to `--status idle`; that selects nothing, by construction, forever.
#
# Also: a successful compact bumps the pane's activity, so the idle clock
# resets after every compact. That's intentional -- it prevents a re-compact
# loop every cycle, not a bug to "fix" with an extra cooldown flag.
#
# Actual logic (discovery, locking, logging, the safety gate) lives in
# bin/lib/core.sh and bin/lib/prompt_heuristics.sh, split out so
# tests/test_core.sh and tests/test_prompt_heuristics.sh can exercise it
# directly (with stubbed tmux/claude-mux) without any of this file's
# side effects.

set -uo pipefail

# launchd runs jobs in a bare/POSIX locale (no LANG/LC_ALL set), unlike an
# interactive terminal. This is NOT cosmetic: bash/grep bracket expressions
# on multi-byte UTF-8 characters (the box-drawing chars in
# prompt_heuristics.sh's structural dialog-box check) degrade to per-BYTE
# matching under a non-UTF-8 locale, since the shared leading bytes of many
# UTF-8 sequences (e.g. 0xE2 0x95 for the whole U+2500-25FF box-drawing block)
# then match as individual "characters" in the class. Confirmed live: under
# `LC_ALL=C`, a completely normal, clean idle pane (no dialog, no draft --
# just ordinary Unicode like the ✻ status glyph or an em dash) was
# misidentified as "dialog box border present" by that check, because those
# glyphs happen to share lead bytes with the box-drawing range. Force UTF-8
# here so the script behaves the same regardless of the caller's environment
# (launchd, cron, an interactive shell, ssh) rather than depending on every
# invocation site remembering to set it.
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# ---------------------------------------------------------------------------
# Config (small enough to keep here rather than a separate config file)
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # consumed by the functions sourced from lib/core.sh below
IDLE_THRESHOLD_SECONDS="${IDLE_COMPACTOR_THRESHOLD_SECONDS:-3000}"   # 50 min

# Ceiling on top of the floor above. Research into prior art (README.md's
# "Cost model" section) found this environment's cache TTL is 1 hour for
# subscription-within-plan usage (verified: ~99% of this account's historical
# cache-creation tokens used the 1h tier, per a grep against real session
# logs) -- but a check that fires only every 15 min against a 50-min floor can
# land on a session idle 60-65 min, i.e. already past a 1h TTL. Compacting a
# cold cache is WORSE than doing nothing for that resume (you pay the full
# cold rebuild AND the compaction) -- so skip, don't compact, past this
# ceiling. 58 min leaves a safety margin under the 60-min TTL even accounting
# for the up-to-15-min gap between checks.
IDLE_THRESHOLD_MAX_SECONDS="${IDLE_COMPACTOR_THRESHOLD_MAX_SECONDS:-3480}"   # 58 min

# Skip compacting a session with less than this much accumulated context.
# Same research: a session with little history has both low reuse-after-idle
# probability and little to shrink, so compacting it is close to pure
# downside (a wasted summarization request). Read from Claude Code's own
# "/clear to save Xk tokens" footer hint (extract_context_tokens_k in
# lib/core.sh) -- if the hint isn't present in the capture, proceed anyway
# rather than block: this is a cost-optimization gate, not a safety gate, so
# "unknown" should not mean "skip" the way it does for idle duration.
MIN_CONTEXT_TOKENS_K="${IDLE_COMPACTOR_MIN_CONTEXT_TOKENS_K:-100}"   # 100k tokens

CLAUDE_MUX_BIN="${CLAUDE_MUX_BIN:-$HOME/bin/claude-mux}"
LOG_DIR="${IDLE_COMPACTOR_LOG_DIR:-$HOME/Library/Logs}"
# shellcheck disable=SC2034
LOG_FILE="${IDLE_COMPACTOR_LOG_FILE:-$LOG_DIR/claude-mux-idle-compactor.log}"
# shellcheck disable=SC2034
LOG_MAX_LINES="${IDLE_COMPACTOR_LOG_MAX_LINES:-2000}"
# shellcheck disable=SC2034
LOCK_DIR="${IDLE_COMPACTOR_LOCK_DIR:-/tmp/claude-mux-idle-compactor.lock}"
# shellcheck disable=SC2034
LOCK_STALE_SECONDS="${IDLE_COMPACTOR_LOCK_STALE_SECONDS:-1200}"   # 20 min
TMUX_BIN="${TMUX_BIN:-tmux}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/core.sh
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck source=lib/prompt_heuristics.sh
source "$SCRIPT_DIR/lib/prompt_heuristics.sh"

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *)
            echo "unknown argument: $arg" >&2
            echo "usage: $0 [--dry-run]" >&2
            exit 2
            ;;
    esac
done

mkdir -p "$LOG_DIR"

main() {
    rotate_log_if_needed

    if ! preflight_check; then
        exit 1
    fi

    if ! acquire_lock; then
        exit 0
    fi
    trap release_lock EXIT

    log "=== run starting (dry-run=$DRY_RUN, threshold=${IDLE_THRESHOLD_SECONDS}s) ==="

    # Explicit deny-set: claude-mux's `-s` command has NO protection check of
    # its own (only checks is-managed + has-session) -- this script's filter
    # is the only thing stopping it from sending into a protected session like
    # `home`. Cross-check every candidate against a freshly-fetched protected
    # list, even though `--status running` shouldn't include protected ones --
    # defense in depth for exactly the kind of tool where a filter bug means
    # sending a live command into someone's protected session.
    local protected_sessions
    protected_sessions=$'\n'"$(parse_session_table protected)"$'\n'

    local candidates
    candidates=$(parse_session_table running)

    if [[ -z "$candidates" ]]; then
        log "no running sessions found this cycle"
        exit 0
    fi

    local session
    while IFS= read -r session; do
        [[ -z "$session" ]] && continue

        if [[ "$protected_sessions" == *$'\n'"$session"$'\n'* ]]; then
            # Not even worth a log line -- protected is a hard, silent no.
            continue
        fi

        if ! session_has_live_tmux "$session"; then
            log "skip: $session - status was running but tmux session vanished"
            continue
        fi

        local idle_seconds
        if ! idle_seconds=$(get_idle_seconds "$session"); then
            log "skip: $session - could not determine idle duration (window_activity unavailable)"
            continue
        fi

        # Raw epoch logged too (not just derived minutes) since the
        # no-passive-redraw-noise assumption, while spot-checked, is still
        # worth a data trail if it's ever wrong in practice.
        local activity_epoch=$(( $(date +%s) - idle_seconds ))

        if (( idle_seconds < IDLE_THRESHOLD_SECONDS )); then
            continue   # not stale enough yet -- no log, would be 70+ lines of noise
        fi

        local idle_minutes=$(( idle_seconds / 60 ))

        if (( idle_seconds >= IDLE_THRESHOLD_MAX_SECONDS )); then
            log "skip: $session (idle ${idle_minutes}m, activity_epoch=$activity_epoch) - past the ${IDLE_THRESHOLD_MAX_SECONDS}s ceiling, cache is likely already cold; compacting now would cost more than it saves"
            continue
        fi

        local pane_text
        pane_text=$("$TMUX_BIN" capture-pane -p -t "=${session}:" 2>/dev/null)

        local block_reason
        if block_reason=$(pane_has_blocking_condition "$pane_text"); then
            log "skip: $session (idle ${idle_minutes}m, activity_epoch=$activity_epoch) - $block_reason"
            continue
        fi

        local context_tokens_k
        if context_tokens_k=$(extract_context_tokens_k "$pane_text"); then
            if (( $(echo "$context_tokens_k < $MIN_CONTEXT_TOKENS_K" | bc -l 2>/dev/null || echo 0) )); then
                log "skip: $session (idle ${idle_minutes}m, activity_epoch=$activity_epoch) - context only ${context_tokens_k}k tokens, below the ${MIN_CONTEXT_TOKENS_K}k floor (not worth the compaction cost)"
                continue
            fi
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            log "would compact $session (idle ${idle_minutes}m, activity_epoch=$activity_epoch)"
            continue
        fi

        # `claude-mux -s` runs send-keys then an UNCONDITIONAL exit 0 -- a
        # non-zero exit here only means pre-send validation failed (not
        # managed / no tmux session / bad format). It does NOT prove /compact
        # was delivered as a fresh command rather than queued behind other
        # input. Log what we actually know: "sent" (exit 0) or
        # "send rejected" (non-zero) -- never "compacted successfully" either
        # way, since we can't observe that from here without a second
        # capture-pane re-check, which both review passes agreed isn't worth
        # the added race window at a 15-min cadence.
        if "$CLAUDE_MUX_BIN" -s "$session" '/compact' >/dev/null 2>&1; then
            log "sent /compact to $session (idle ${idle_minutes}m, activity_epoch=$activity_epoch)"
        else
            log "skip: $session (idle ${idle_minutes}m) - claude-mux -s rejected the send"
        fi
    done <<< "$candidates"

    log "=== run complete ==="
}

main "$@"
