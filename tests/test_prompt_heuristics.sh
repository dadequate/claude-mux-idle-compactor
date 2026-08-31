#!/usr/bin/env bash
# test_prompt_heuristics.sh -- fixture-based unit tests for the shared
# confirmation-prompt / draft-in-box detector in bin/lib/prompt_heuristics.sh.
# No live tmux session required -- fixtures under tests/fixtures/ are real
# captured pane text (workspace-trust dialog, unsent drafts) pulled from
# a real fleet on 2026-08-31, plus a couple of synthetic edge cases.
#
# Usage: tests/test_prompt_heuristics.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../bin/lib/prompt_heuristics.sh
source "$SCRIPT_DIR/../bin/lib/prompt_heuristics.sh"

FIXTURES_DIR="$SCRIPT_DIR/fixtures"
PASS=0
FAIL=0

# assert_blocked <fixture-file> <description>
assert_blocked() {
    local fixture="$1" desc="$2"
    local text reason
    text="$(cat "$FIXTURES_DIR/$fixture")"
    if reason=$(pane_has_blocking_condition "$text"); then
        echo "PASS: $desc (matched: $reason)"
        (( PASS++ ))
    else
        echo "FAIL: $desc -- expected a block, got clear"
        (( FAIL++ ))
    fi
}

# assert_clear <fixture-file> <description>
assert_clear() {
    local fixture="$1" desc="$2"
    local text reason
    text="$(cat "$FIXTURES_DIR/$fixture")"
    if reason=$(pane_has_blocking_condition "$text"); then
        echo "FAIL: $desc -- expected clear, got block: $reason"
        (( FAIL++ ))
    else
        echo "PASS: $desc"
        (( PASS++ ))
    fi
}

echo "=== prompt_heuristics fixture tests ==="

assert_blocked "trust-dialog.txt" "real workspace-trust dialog is detected"
assert_blocked "permission-dialog.txt" "bash command permission dialog is detected"
assert_blocked "yn-prompt.txt" "(y/n) style prompt is detected"
assert_blocked "draft-in-box.txt" "unsent draft text in the input box is detected"

assert_clear "clean-idle.txt" "clean idle prompt (empty input box) is not blocked"
assert_clear "unrelated-numbered-prose.txt" "numbered prose without a cursor glyph is not a false positive"

echo ""
echo "=== inline edge cases ==="

# Empty pane text (e.g. capture-pane failed) must never be treated as blocked
# by these checks -- the CALLER is responsible for skipping on empty/unknown
# input; this function should just report "clear" for empty text so callers
# have one place (idle-compactor.sh's own logic) that decides how to handle
# missing data, not two.
if pane_has_blocking_condition ""; then
    echo "FAIL: empty pane text should not match any heuristic"
    (( FAIL++ ))
else
    echo "PASS: empty pane text is not blocked"
    (( PASS++ ))
fi

# A draft line with only whitespace after the cursor glyph must NOT count as
# a draft (it's really an empty input box, just with trailing spaces from the
# terminal's fixed-width rendering).
whitespace_only_input="some output above
❯
below the box"
if pane_has_blocking_condition "$whitespace_only_input"; then
    echo "FAIL: whitespace-only input line should not count as a draft"
    (( FAIL++ ))
else
    echo "PASS: whitespace-only input line is not treated as a draft"
    (( PASS++ ))
fi

# Regression test for a real bug found on 2026-08-31: under a bare `C` locale
# (launchd's default -- it does NOT set LANG/LC_ALL the way an interactive
# shell does), bash/grep bracket-expression matching on the box-drawing
# characters degraded to per-byte matching and misidentified completely
# ordinary Unicode (a status glyph) as a dialog box border. Simulate a hostile
# caller that has LC_ALL=C set BEFORE sourcing the library, to prove the
# library's own `export LC_ALL=C.UTF-8` (not just idle-compactor.sh's) fixes
# it regardless of the caller's environment.
clean_text_with_unicode="✻ Cogitated for 1m 9s
                                        new task? /clear to save 239.9k tokens
───────────────────────────────────────────────────────────── some-session ─────
❯
────────────────────────────────────────────────────────────────────────────────
  [EXAMPLE]  Sonnet 5  ctx:24%  some-session                                  /rc
  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent"

locale_test_result=$(
    LC_ALL=C LANG=C bash -c '
        source "$1"
        text="$2"
        if reason=$(pane_has_blocking_condition "$text"); then
            echo "BLOCKED: $reason"
        else
            echo "clear"
        fi
    ' _ "$SCRIPT_DIR/../bin/lib/prompt_heuristics.sh" "$clean_text_with_unicode"
)
if [[ "$locale_test_result" == "clear" ]]; then
    echo "PASS: a clean Unicode-containing pane is not blocked under a caller with LC_ALL=C set"
    (( PASS++ ))
else
    echo "FAIL: a clean Unicode-containing pane is not blocked under a caller with LC_ALL=C set (got: $locale_test_result)"
    (( FAIL++ ))
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
