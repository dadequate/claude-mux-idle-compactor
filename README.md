# claude-mux-idle-compactor

A small watcher for `claude-mux` sessions that auto-compacts a session's
context right before its prompt cache would go cold from inactivity — instead
of letting it sit idle for hours/days and then eating a full, expensive cache
rewrite the next time it's resumed.

**What's portable vs. specific to `claude-mux`:** this is a standalone
companion script for [`claude-mux`](https://github.com/pereljon/claude-mux)
(not part of its codebase, and not affiliated with its maintainer). The two
`claude-mux` shell-outs (`bin/lib/core.sh`'s `parse_session_table()` and the
`/compact` send in `bin/idle-compactor.sh`) are the only places this tool
depends on it, and both are a few lines each. Everything else — the
idle-detection approach, the safety-gate heuristics for not compacting into a
live dialog or over a half-typed draft, the cost-ceiling/context-floor logic,
and the tmux mechanics in general — is generic to *any* tmux-based Claude Code
session manager. Swap those two call sites for your own tooling and the rest
should carry over directly.

## Why

Claude Code caches the growing conversation prefix. A cache **write** costs
~1.25x normal input price; a cache **read** costs ~0.1x. The cache has a TTL
(this environment runs a 1-hour window). Resume a session after the TTL expires
and the *entire* accumulated context gets rewritten from scratch at write price
-- the classic "one prompt burned my whole limit" complaint.

Compacting *while the cache is still warm* is cheap (the old context reads from
cache; only the new summary is a fresh, small write). Compacting *after* the
cache has already gone cold buys nothing -- the expensive part already happened
the moment the first stale message was sent. So the fix is timing, not
avoidance: compact right before the TTL cliff, automatically, for sessions that
are genuinely idle -- never for one that's still working or waiting on a live
decision.

## Design

- **Check interval:** 15 min (launchd `StartInterval`)
- **Trigger:** a claude-mux session that is currently `running` (see the status
  note below), where tmux's `window_activity` timestamp for that session's pane
  has been stale for 50-58 min (`IDLE_THRESHOLD_SECONDS` /
  `IDLE_THRESHOLD_MAX_SECONDS`, both configurable -- see "Cost model" below for
  why there's a ceiling, not just a floor)
- **Cost gate:** skip a session with less than 100k tokens of accumulated
  context (`IDLE_COMPACTOR_MIN_CONTEXT_TOKENS_K`), read from Claude Code's own
  "/clear to save Xk tokens" footer hint -- a small session has little to
  shrink and is less likely to be resumed, so compacting it is close to pure
  downside. Best-effort: if the hint isn't present in the capture, proceeds as
  before rather than blocking (this is a cost gate, not a safety gate).
- **Safety gate:** before compacting, capture the session's tmux pane and skip
  it this cycle if it looks like a live confirmation/permission dialog ("Do you
  want to proceed?", a workspace-trust prompt, numbered "❯ 1." menu options,
  y/n prompts, etc.) **or** if there's unsent draft text sitting in the input
  box -- retry next cycle rather than compact into a blocking dialog or
  submit someone's half-typed prompt. See `bin/lib/prompt_heuristics.sh`.
- **Never touches:** `protected` sessions (cross-checked explicitly, not just
  relied on via the discovery filter -- `claude-mux -s` has no protection check
  of its own), sessions with no live tmux pane, or a `running` session whose
  pane has been active recently (i.e. actually mid-turn).
- **Dry run first:** the watcher supports `--dry-run`, which logs exactly what
  it *would* compact without sending `/compact`, so a day of output can be
  reviewed before trusting it live.

### Important: this targets claude-mux status `running`, not `idle`

This is the one deliberate deviation from a literal reading of the original
spec, and it's load-bearing enough to call out here as well as in the code
comments. `claude-mux`'s own `idle` status means **"no live tmux session at
all"** -- confirmed by reading `status_claude_sessions()` in claude-mux itself.
Within a live tmux session, claude-mux only distinguishes `protected` from
`running`; `running` just means a `claude` process exists under the pane, not
that it's actively generating. So the session this tool actually wants to act
on -- one that finished its turn and has been sitting quietly -- reports as
`running`, and `claude-mux -L --status idle` would always return zero
candidates that also have a live pane to compact.

Confirmed against a real fleet of ~100 claude-mux projects: 72 reported
`idle`, and **zero** of them had a live tmux session (some had been tmux-dead
for weeks). Meanwhile several `running` sessions were sitting stale for
hours — the exact target population. This tool deliberately redefines the
candidate rule to `running` (never `protected`) + pane staleness, since
staleness is what actually detects "finished its turn" here.

### Idle-duration signal: `window_activity`, not `pane_activity`

`tmux`'s `#{pane_activity}` never populates for these (single-window,
single-pane) claude-mux sessions. `#{window_activity}` does, gated on
claude-mux's own `monitor-activity on` tmux option (set per-session by default).
Spot-checked against a real stale session: the timestamp held steady across a
20s passive-observation window, i.e. it isn't bumped by redraw noise (spinners,
clocks) when nothing is actually happening. This is the swappable
`get_idle_seconds()` function in `bin/idle-compactor.sh` — revise it there if
that assumption ever proves wrong in practice (dry-run logs the raw epoch per
candidate for exactly this reason).

One more tmux quirk worth knowing if you touch this code: a bare session name
in a `tmux -t` target does **unambiguous-prefix matching** — `-t demo` will
silently resolve to `demo-two` if `demo` doesn't exist as an exact session.
Use `"=name"` (exact match) for `has-session`, and `"=name:"`
(trailing colon, empty window part) for `capture-pane`/`display` — the bare
`"=name"` form doesn't work for those two on this tmux version (3.7b).

### Cost model — why there's a ceiling and a context-size floor, not just a floor

Researched this after the tool went live (this is exactly the same problem
raised in [`anthropics/claude-code#66115`](https://github.com/anthropics/claude-code/issues/66115),
open since June 2026 — no one's built this for tmux/claude-mux before, but a
VS Code-extension analog, [`dthinkr/claude-code-auto-compactor`](https://github.com/dthinkr/claude-code-auto-compactor),
independently converged on the same shape of fix from real backtest data).
The cost of resuming a session, per that research (C = the cost of the
context accumulated before compacting; C′ = the smaller cost of the
context that remains after compacting):

| scenario | cost to resume |
|---|---|
| do nothing | 2C |
| compact while cache still warm | 0.1C + 2C′ |
| compact after cache already went cold | 2C + 2C′ |

Compacting a cache that's already cold is **worse than doing nothing** — you
pay the full rebuild *and* the compaction. Two consequences, both implemented:

1. **A ceiling, not just a floor** (`IDLE_THRESHOLD_MAX_SECONDS`, 58 min
   default). The check only runs every 15 min against a 50-min floor, so it
   can land on a session idle 60-65 min -- past this environment's cache TTL.
   Once a session crosses the ceiling, it's skipped every cycle (not
   compacted) until real activity resets its idle clock -- that's correct,
   not a bug: the cache is already cold, so there's nothing left to save for
   *that* idle stretch, and the tool picks the session back up cleanly once
   it's actually touched again.
2. **A minimum context-size floor** (`IDLE_COMPACTOR_MIN_CONTEXT_TOKENS_K`,
   100k default). A session with little accumulated context has little to
   shrink and (per the backtest data above) is also less likely to be resumed
   at all -- compacting it is a wasted summarization request for no payoff.

**One assumption worth knowing, not treating as settled:** the 1-hour TTL this
tool assumes only applies to subscription-within-plan usage — it drops to 5
minutes under usage credits or API-key auth (per Anthropic's own prompt-caching
docs). This is worth actually checking against real usage rather than assuming
it holds — a lifetime aggregate of local cache-creation tokens by TTL tier
(no timestamps, no per-session breakdown, nothing identifying — just a count)
is enough to check it:
```
grep -ho '"ephemeral_[0-9]*[hm]_input_tokens":[0-9]*' ~/.claude/projects/*/*.jsonl \
  | awk -F'[:"]' '{t[$2]+=$NF} END{for(k in t) print k, t[k]}'
→ ephemeral_5m_input_tokens     22,531,149  (~1%)
→ ephemeral_1h_input_tokens  2,237,229,403  (~99%)
```
On my own account, the 1-hour tier accounted for ~99% of lifetime
cache-creation tokens — so the assumption holds in practice, but on a day a
fleet spills into usage credits, some concurrent sessions silently get the
5-minute tier, and for those the 50-min floor is already moot (the compact
just fires into an already-cold cache — harmless, per the table above, just
not the cheap win). Not worth building tier-detection for a small-percentage
case; just don't be surprised by an occasional "compacted, but it turned out
to already be cold anyway" outcome. Worth running this same check against
your own account before trusting the default thresholds.

## Files

```
bin/idle-compactor.sh                    Thin CLI entrypoint -- config, arg parsing, main loop
bin/lib/core.sh                          Discovery, locking, logging, preflight (testable in isolation)
bin/lib/prompt_heuristics.sh             Shared confirmation-dialog / unsent-draft detector
tests/test_core.sh                       Unit tests for core.sh (fake tmux/claude-mux stubs)
tests/test_prompt_heuristics.sh          Fixture-based unit tests (no live tmux needed)
tests/fixtures/                          Real captured pane text + synthetic edge cases
tests/stubs/                             fake-tmux / fake-claude-mux test doubles
setup/com.example.claude-mux-idle-compactor.plist.template   launchd job template
setup/install.sh                         Installs/uninstalls the launchd job
```

## Usage

```bash
# Dry run against your real fleet -- logs only, sends nothing
bin/idle-compactor.sh --dry-run

# Run the full test suite (35 tests: discovery/locking/logging + safety gate)
tests/test_core.sh
tests/test_prompt_heuristics.sh

# Install as a launchd job (run this by hand -- not automatic)
setup/install.sh --dry-run   # validate for a day first
setup/install.sh --live      # go live once the dry-run log looks right
setup/install.sh --uninstall
```

## Failure modes and what happens

- **`claude-mux` or `tmux` not found** (e.g. a PATH problem) -- `preflight_check`
  logs a distinct `FATAL:` line naming exactly what's missing and the script
  exits 1, rather than silently doing nothing indistinguishable from "0
  candidates this cycle." This is a real, previously-shipped bug: launchd
  gives jobs a bare `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) that does **not**
  include `/opt/homebrew/bin`, where `tmux` (installed via Homebrew) actually
  lives on macOS. The plist template sets `PATH` explicitly to cover this, and
  `preflight_check` is a second, independent line of defense against the same
  class of problem.
- **`claude-mux -L --status <x>` itself fails** (non-zero exit) --
  `parse_session_table` logs a distinct `WARN:` with the command's output,
  rather than silently treating it the same as "ran fine, found nothing."
- **A prior run got SIGKILLed or the machine rebooted mid-run** -- the mkdir
  lock would otherwise deadlock the watcher forever (nothing to release it).
  `acquire_lock` breaks any lock older than `LOCK_STALE_SECONDS` (20 min,
  configurable) rather than waiting on it indefinitely.
- **Two runs somehow overlap** (a hung prior run + the next launchd tick, or a
  manual test run colliding with the timer) -- the second run's `acquire_lock`
  fails cleanly and it exits 0 without touching anything, logging that another
  run holds the lock.
- **Log directory not writable / disk full** -- `rotate_log_if_needed` checks
  `mktemp`'s and `tail`'s exit status before ever calling `mv`; on failure it
  logs a `WARN` and leaves the existing log alone rather than risking data
  loss from a failed rotation.
- **`claude-mux -s` "succeeds" (exit 0) but the send may have queued behind
  other input** rather than run immediately if the session started a new turn
  in the gap between the safety-gate check and the send -- documented, not
  "fixed": the log records `sent` (exit 0) vs `send rejected` (non-zero),
  never an unverifiable claim of "compacted successfully." See the code
  comment above the send call in `bin/idle-compactor.sh`.

Logs to `~/Library/Logs/claude-mux-idle-compactor.log`, one line per action or
skip-with-reason, timestamped, auto-truncated to the last 2000 lines.

## Status

Built and validated against a real fleet: dry-run for a full day (35 runs, no
errors, correct behavior against real trust dialogs and real unsent drafts),
then live for several cycles with every send landing cleanly (no interrupted
work, no blocking dialogs compacted into). Currently running live against my
own fleet.

## License

MIT (see `LICENSE`). Note that `claude-mux` itself is a separate project
([github.com/pereljon/claude-mux](https://github.com/pereljon/claude-mux),
also MIT-licensed) and is not included here -- only the two call sites
described above reference it.
