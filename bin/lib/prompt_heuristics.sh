#!/usr/bin/env bash
# prompt_heuristics.sh -- shared blocking-condition detector for
# claude-mux-idle-compactor. Sourced by both bin/idle-compactor.sh (the real
# watcher) and tests/test_prompt_heuristics.sh (the fixture harness), so the
# tests exercise the exact same logic the watcher uses -- not a copy that can
# drift.
#
# Ground truth: these patterns were built against REAL captured panes from
# a real fleet on 2026-08-31 (workspace-trust dialog, half-typed input
# drafts), not guessed from memory. See tests/fixtures/ for the exact text.
#
# pane_has_blocking_condition <pane_text>
#   Prints a short human-readable reason to stdout and returns 0 if the pane
#   text shows a live confirmation/permission dialog OR unsent draft text in
#   the input box -- either way, the caller must NOT send /compact this cycle.
#   Returns 1 (no output) if the pane looks clear to compact.
#
# The guiding rule: err on the side of over-matching and skipping rather than
# compacting into a blocking dialog. Every check here is deliberately loose.
#
# Locale matters here, not just cosmetically: bash/grep bracket-expression
# matching on multi-byte UTF-8 characters (the box-drawing chars below)
# degrades to per-BYTE matching under a non-UTF-8 locale, since many Unicode
# symbols share leading bytes with the box-drawing block (U+2500-25FF all
# start 0xE2 0x94/0x95 in UTF-8). Confirmed live: under `LC_ALL=C` (launchd's
# default -- it does not set LANG/LC_ALL the way an interactive shell does), a
# completely clean idle pane containing nothing but an ordinary status glyph
# was misidentified as "dialog box border present." idle-compactor.sh already
# exports LC_ALL=C.UTF-8/LANG=C.UTF-8 before sourcing this file, but set it
# here too so this file defends itself regardless of what sources it.
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

pane_has_blocking_condition() {
    local text="$1"

    # --- 1. Known confirmation/permission dialog phrases (case-insensitive) ---
    # Substring match, not full regex -- these are copy fragments Claude Code
    # itself prints, not something we need to anchor precisely.
    local -a blocking_phrases=(
        "do you want to proceed"
        "would you like to proceed"
        "do you trust the files"
        "is this a project you created or one you trust"
        "pre-approves"
        "allow this"
        "don't ask again"
        "enter to confirm"
        "esc to cancel"
        "this mcp server"
        "wants to connect"
        "trust this folder"
        "security guide"
    )
    local phrase
    for phrase in "${blocking_phrases[@]}"; do
        if grep -qiF -- "$phrase" <<<"$text"; then
            echo "confirmation dialog detected (matched: \"$phrase\")"
            return 0
        fi
    done

    # --- 2. y/n style prompts ---
    if grep -qE '\((y/n)\)|\[[Yy]/[Nn]\]' <<<"$text"; then
        echo "confirmation dialog detected (y/n prompt)"
        return 0
    fi

    # --- 3. Structural: a numbered menu option under the input cursor, e.g.
    #        "❯ 1. Yes, I trust this folder"
    #    This is the strongest signal and deliberately phrase-agnostic, so it
    #    still catches dialog copy we haven't enumerated above (over-match on
    #    purpose, per the guiding rule above).
    if grep -qE '^[[:space:]]*(❯|>)[[:space:]]*[0-9]+\.' <<<"$text"; then
        echo "confirmation dialog detected (numbered menu under cursor)"
        return 0
    fi

    # --- 4. Bordered-dialog box-drawing characters (heavier box style some
    #    permission dialogs use). Coarse fallback for prompt copy we've never
    #    seen -- if a real dialog box is on screen, this catches it even if
    #    none of the phrases above match.
    if grep -qE '[╭╮╰╯]' <<<"$text"; then
        echo "confirmation dialog detected (dialog box border present)"
        return 0
    fi

    # --- 5. Unsent draft text sitting in the input box. Claude Code's input
    #    box renders as a line starting with the cursor glyph "❯ " followed by
    #    free text, e.g. "❯ check on the review status". If someone left a
    #    half-typed prompt there, sending /compact would append to it and
    #    submit it -- confirmed live against a real fleet (two independent
    #    sessions had genuine unsent drafts sitting idle). A numbered-menu
    #    line already matched check 3 above, so anything reaching here that
    #    starts with the cursor glyph is genuine free-text, not a menu option.
    local draft_line
    draft_line=$(grep -E '^❯[[:space:]]*.+$' <<<"$text" | tail -1)
    if [[ -n "$draft_line" ]]; then
        local draft_content="${draft_line#❯}"
        # Trim whitespace
        draft_content="$(echo -n "$draft_content" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        if [[ -n "$draft_content" ]]; then
            echo "unsent draft text in input box (\"$draft_content\")"
            return 0
        fi
    fi

    return 1
}
