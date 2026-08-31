#!/usr/bin/env bash
# test_core.sh -- unit tests for bin/lib/core.sh (discovery, locking,
# logging, preflight) using fake tmux/claude-mux stubs under tests/stubs/ and
# fixtures under tests/fixtures/. No live tmux session or real claude-mux
# install required, and nothing here touches the real ~/Library/Logs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
STUBS_DIR="$SCRIPT_DIR/stubs"

# shellcheck source=../bin/lib/core.sh
source "$SCRIPT_DIR/../bin/lib/core.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; (( PASS++ )); }
fail() { echo "FAIL: $1"; (( FAIL++ )); }

# Fresh scratch dir per test run
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# parse_session_table
# ---------------------------------------------------------------------------
test_parse_session_table() {
    export CLAUDE_MUX_BIN="$STUBS_DIR/fake-claude-mux"
    export FAKE_CLAUDE_MUX_FIXTURES_DIR="$FIXTURES_DIR"
    export LOG_FILE="$WORKDIR/test.log"
    unset FAKE_CLAUDE_MUX_EXIT

    local result
    result="$(parse_session_table running)"

    if [[ "$result" == *"> idle-compactor"* ]]; then
        fail "parse_session_table strips the '> ' current-session marker"
    else
        pass "parse_session_table strips the '> ' current-session marker (name preserved without prefix)"
    fi

    if grep -qxF "idle-compactor" <<< "$result"; then
        pass "current session name survives prefix-stripping intact"
    else
        fail "current session name survives prefix-stripping intact"
    fi

    if grep -qxF "demo-two" <<< "$result"; then
        pass "adjacent similarly-named session (demo-two) parsed correctly, not truncated"
    else
        fail "adjacent similarly-named session (demo-two) parsed correctly, not truncated"
    fi

    local count
    count=$(grep -c . <<< "$result")
    if [[ "$count" -eq 5 ]]; then
        pass "parse_session_table returns exactly 5 rows from the running fixture (no header/separator leakage)"
    else
        fail "parse_session_table returns exactly 5 rows from the running fixture (got $count)"
    fi

    result="$(parse_session_table protected)"
    if [[ "$result" == "home" ]]; then
        pass "parse_session_table parses the protected fixture correctly"
    else
        fail "parse_session_table parses the protected fixture correctly (got: $result)"
    fi
}

test_parse_session_table_failure() {
    export CLAUDE_MUX_BIN="$STUBS_DIR/fake-claude-mux"
    export FAKE_CLAUDE_MUX_FIXTURES_DIR="$FIXTURES_DIR"
    export FAKE_CLAUDE_MUX_EXIT=1
    export LOG_FILE="$WORKDIR/failure.log"
    : > "$LOG_FILE"

    local result
    result="$(parse_session_table running)"
    unset FAKE_CLAUDE_MUX_EXIT

    if [[ -z "$result" ]]; then
        pass "parse_session_table returns empty (not garbage) when claude-mux fails"
    else
        fail "parse_session_table returns empty (not garbage) when claude-mux fails"
    fi

    if grep -qi "WARN.*claude-mux -L --status running.*exited non-zero" "$LOG_FILE"; then
        pass "a failed claude-mux call is logged as a distinct WARN, not silent zero-candidates"
    else
        fail "a failed claude-mux call is logged as a distinct WARN, not silent zero-candidates"
    fi
}

# ---------------------------------------------------------------------------
# get_idle_seconds / session_has_live_tmux
# ---------------------------------------------------------------------------
test_get_idle_seconds() {
    export TMUX_BIN="$STUBS_DIR/fake-tmux"
    local now epoch_1h_ago
    now=$(date +%s)
    epoch_1h_ago=$(( now - 3600 ))

    printf 'example-session=%s\nempty-value-session=\nnon-numeric-session=garbage\n' "$epoch_1h_ago" > "$WORKDIR/activity_map"
    export FAKE_TMUX_ACTIVITY_MAP="$WORKDIR/activity_map"

    local idle
    if idle=$(get_idle_seconds "example-session"); then
        if (( idle >= 3590 && idle <= 3610 )); then
            pass "get_idle_seconds computes ~3600s idle from a 1h-old window_activity epoch"
        else
            fail "get_idle_seconds computes ~3600s idle from a 1h-old window_activity epoch (got $idle)"
        fi
    else
        fail "get_idle_seconds computes ~3600s idle from a 1h-old window_activity epoch (returned failure)"
    fi

    if get_idle_seconds "unknown-session" >/dev/null 2>&1; then
        fail "get_idle_seconds returns failure for a session with no activity data"
    else
        pass "get_idle_seconds returns failure for a session with no activity data"
    fi

    if get_idle_seconds "non-numeric-session" >/dev/null 2>&1; then
        fail "get_idle_seconds returns failure on a non-numeric activity value"
    else
        pass "get_idle_seconds returns failure on a non-numeric activity value"
    fi
}

test_session_has_live_tmux() {
    export TMUX_BIN="$STUBS_DIR/fake-tmux"
    printf 'example-session\ndemo-two\n' > "$WORKDIR/sessions"
    export FAKE_TMUX_SESSIONS="$WORKDIR/sessions"

    if session_has_live_tmux "example-session"; then
        pass "session_has_live_tmux is true for a known live session"
    else
        fail "session_has_live_tmux is true for a known live session"
    fi

    # This is the exact prefix-collision scenario found against a real
    # fleet: "demo" must NOT match "demo-two".
    if session_has_live_tmux "demo"; then
        fail "session_has_live_tmux does not prefix-match 'demo' onto 'demo-two'"
    else
        pass "session_has_live_tmux does not prefix-match 'demo' onto 'demo-two'"
    fi
}

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------
test_locking() {
    export LOCK_DIR="$WORKDIR/lock-$$"
    export LOG_FILE="$WORKDIR/lock.log"
    export LOCK_STALE_SECONDS=1200
    rm -rf "$LOCK_DIR"

    if acquire_lock; then
        pass "acquire_lock succeeds when no lock is held"
    else
        fail "acquire_lock succeeds when no lock is held"
    fi

    if acquire_lock; then
        fail "a second acquire_lock fails while the first lock is still fresh"
        release_lock
    else
        pass "a second acquire_lock fails while the first lock is still fresh"
    fi

    # Simulate a stale lock: back-date the lock dir well past the threshold.
    local stale_ts
    stale_ts=$(date -v-30M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-30 minutes' +%Y%m%d%H%M.%S)
    touch -t "$stale_ts" "$LOCK_DIR" 2>/dev/null

    if acquire_lock; then
        pass "acquire_lock breaks a stale (30min old) lock and re-acquires"
        release_lock
    else
        fail "acquire_lock breaks a stale (30min old) lock and re-acquires"
    fi

    if [[ -d "$LOCK_DIR" ]]; then
        fail "release_lock removes the lock directory"
    else
        pass "release_lock removes the lock directory"
    fi
}

# ---------------------------------------------------------------------------
# Log rotation
# ---------------------------------------------------------------------------
test_log_rotation() {
    export LOG_FILE="$WORKDIR/rotate.log"
    export LOG_MAX_LINES=100
    seq 1 250 | sed 's/^/line /' > "$LOG_FILE"

    rotate_log_if_needed

    local final_count
    final_count=$(wc -l < "$LOG_FILE" | tr -d '[:space:]')
    # 100 kept + 1 marker line appended by log() inside rotate_log_if_needed
    if [[ "$final_count" -eq 101 ]]; then
        pass "rotate_log_if_needed truncates an oversized log to LOG_MAX_LINES (+1 marker line)"
    else
        fail "rotate_log_if_needed truncates an oversized log to LOG_MAX_LINES (+1 marker line) (got $final_count)"
    fi

    if grep -q "log rotated, 150 line(s) dropped" "$LOG_FILE"; then
        pass "rotate_log_if_needed writes a marker line stating how many lines were dropped"
    else
        fail "rotate_log_if_needed writes a marker line stating how many lines were dropped"
    fi

    if head -1 "$LOG_FILE" | grep -q "^line 151$"; then
        pass "rotate_log_if_needed keeps the most recent lines, not the oldest"
    else
        fail "rotate_log_if_needed keeps the most recent lines, not the oldest"
    fi

    # A log under the threshold must be left alone.
    export LOG_FILE="$WORKDIR/small.log"
    printf 'one\ntwo\n' > "$LOG_FILE"
    rotate_log_if_needed
    if [[ "$(wc -l < "$LOG_FILE" | tr -d '[:space:]')" -eq 2 ]]; then
        pass "rotate_log_if_needed leaves a log under LOG_MAX_LINES untouched"
    else
        fail "rotate_log_if_needed leaves a log under LOG_MAX_LINES untouched"
    fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
test_preflight_check() {
    export LOG_FILE="$WORKDIR/preflight.log"
    : > "$LOG_FILE"

    export TMUX_BIN="/nonexistent/tmux-binary-for-test"
    export CLAUDE_MUX_BIN="/nonexistent/claude-mux-binary-for-test"
    if preflight_check; then
        fail "preflight_check fails when required binaries are missing"
    else
        pass "preflight_check fails when required binaries are missing"
    fi
    if grep -q "FATAL: required command(s) not found" "$LOG_FILE"; then
        pass "preflight_check logs a distinct FATAL line naming what's missing"
    else
        fail "preflight_check logs a distinct FATAL line naming what's missing"
    fi

    export TMUX_BIN="$STUBS_DIR/fake-tmux"
    export CLAUDE_MUX_BIN="$STUBS_DIR/fake-claude-mux"
    if preflight_check; then
        pass "preflight_check passes when both binaries are present and executable"
    else
        fail "preflight_check passes when both binaries are present and executable"
    fi
}

# ---------------------------------------------------------------------------
# extract_context_tokens_k
# ---------------------------------------------------------------------------
test_extract_context_tokens_k() {
    local text result

    text="$(cat "$FIXTURES_DIR/clean-idle.txt")"
    result=$(extract_context_tokens_k "$text")
    if [[ "$result" == "239.9" ]]; then
        pass "extract_context_tokens_k parses '239.9k tokens' from a real fixture"
    else
        fail "extract_context_tokens_k parses '239.9k tokens' from a real fixture (got: $result)"
    fi

    text="$(cat "$FIXTURES_DIR/unrelated-numbered-prose.txt")"
    result=$(extract_context_tokens_k "$text")
    if [[ "$result" == "190.2" ]]; then
        pass "extract_context_tokens_k parses '190.2k tokens' from a second fixture"
    else
        fail "extract_context_tokens_k parses '190.2k tokens' from a second fixture (got: $result)"
    fi

    # No hint present at all (a live confirmation dialog, not an idle prompt)
    text="$(cat "$FIXTURES_DIR/permission-dialog.txt")"
    if extract_context_tokens_k "$text" >/dev/null 2>&1; then
        fail "extract_context_tokens_k returns failure when no hint is present"
    else
        pass "extract_context_tokens_k returns failure when no hint is present"
    fi
}

echo "=== core.sh unit tests ==="
test_parse_session_table
test_parse_session_table_failure
test_get_idle_seconds
test_session_has_live_tmux
test_locking
test_log_rotation
test_preflight_check
test_extract_context_tokens_k

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
