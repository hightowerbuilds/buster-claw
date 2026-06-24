# 06-23-2026 Summary

Continued yesterday's command consolidation by **removing Autopilot** — the
space-themed "watch it work once" TUI. With `on-duty` now the single front door
for the autonomous mail loop, the autopilot path no longer served a purpose:
it was a second, weaker way to do the same thing (sync mail → run headless
Claude once), without the shift's run cap / kill-switch / no-sleep governance.
Full feature removal, suite green at **657** (was 665 — the 8 autopilot-TUI
tests went with the module).

## What came out

- **`lib/buster_claw/autopilot/tui.ex`** (258 lines) — the whole TUI module:
  ignition/orbit/scanning/transmission starfield scenes driven by classifying
  Claude's `stream-json` events. Deleted.
- **`test/buster_claw/autopilot_tui_test.exs`** — its test. Deleted.
- **CLI** (`cli.ex`): dropped the `["autopilot"] -> autopilot(opts)` route and
  the `autopilot/1` handler.
- **Terminal menu** (`terminal_commands.ex`): removed the `autopilot-once`
  ("Autopilot — Work It Once") and `autopilot-loop` ("Autopilot — Every Minute")
  commands from the Shift role; relabeled the role "Shift & Autopilot" → "Shift"
  and dropped the now-misleading `autopilot` / `auto` / `hands-off` aliases
  (kept `on-shift` / `duty`).

## What stayed (and why)

- **`Agent.StreamEvent`** is shared — `agent/chat.ex` (the in-app LiveView chat)
  is its real consumer, and its parser/classifier tests stand on their own. Left
  it intact; only updated its moduledoc, which had listed `Autopilot.Tui` as a
  consumer. Its `activity_state/2` / `activity_label/1` helpers remain (tested),
  available if a future surface wants coarse activity classification.
- `AgentRunner` (the headless-Claude launch primitive) is untouched — it's the
  Dispatcher's engine for the unattended shift, which is the path we kept.

## Verification

- `mix compile --warnings-as-errors` clean (catches any dangling reference to
  the deleted module — none).
- `mix escript.build` clean; no `autopilot` references remain in `lib/` (only the
  test assertions that verify it's gone).
- Updated `terminal_commands_test.exs` (the old "consolidates Autopilot into the
  Shift role" test now asserts autopilot is absent — no commands, no aliases).
- Full suite **657/657**.

## Code-quality pass — dead code + redundancy

Ran a focused audit (deterministic tooling + three read-only scout agents) for
orphaned/dead/suppressed code and redundancy. Headline: **the codebase is
clean** — the scouts' aggressive "unused public function" list was mostly false
positives (they ignored test call-sites; e.g. `Introduction.markdown/read/
install!`, `TrustedSenders.trusted?/1` are all exercised by tests). Five focused
commits:

- **Retired the deprecated `mailman poll` / `shift run` CLI verbs** (`c746f33`)
  — routes + `mailman_poll_deprecated/1` + `shift_run/1` + the now-orphaned
  `format_shift_started/1`. `on-duty` is the only path. `mailman_poll/poll_gmail`
  stay (on-duty uses them).
- **Removed the dead `agent_chat_enabled` config** (`f6df797`) — defined in
  config.exs + test.exs, read nowhere (chat gates on `_persist`/`_audit`/
  `_timeout_ms`). The test-config comment claiming it disabled chat was stale.
- **`Artifact.workspace_path/1`** (`464af2f`) — collapsed ~16 repetitions of
  `Path.join(Artifact.workspace_root(), …)` into one helper that takes a string
  or a list of segments. Applied via a scoped, reviewed regex across 12 modules.
- **`google_args/1` in the catalog** (`97ab0b5`) — the `account_id`/`email`
  account-selector pair was hand-written on 48 Google command entries; now
  defined once as `@google_account` and merged in. Guarded with a before/after
  snapshot: the resolved args for all 119 catalog entries are **byte-identical**.

Deliberately **kept** (judged not-dead, with reasons): `Dispatch.heartbeat/1`
(a designed liveness API the projector handles — caller side just not wired;
removing it would cascade), the symmetric `topic/0` getters, and the legacy
migration shims (`MANUAL.html` cleanup, encrypted-plaintext backfill).

**Declined two proposed refactors** on judgment: a macro to wrap the ~26
`with_google_account/2` call sites (resolution is already centralized — a macro
would obscure clean delegation), and consolidating the `value/2` accessor into
`Commands.Helpers` (it's command-layer + context-agnostic by its own docs;
importing it into two *contexts* to dedupe a 5-line private helper is a worse
smell than the duplication).

Verification across the pass: `mix compile --warnings-as-errors` clean, credo
shows no new issues, full suite **657/657** after each commit.

## Notes

- Continues the `on-duty` consolidation from the 06-22 summary. The operator now
  has exactly one way to go hands-off: `./buster-claw on-duty` (governed shift +
  Gmail poll + in-thread replies), not a second ungoverned autopilot loop.

## Terminal command-menu cleanup (continued)

Tightened the terminal cmd-list dropdown further:

- **Folded the Shift role into On Duty** (`ac97d99`) — the Shift and On Duty
  groups both carried `on-duty`/`off-duty`, so the menu showed two Go On Duty and
  two Off Duty entries. Merged into one On Duty role (Go On Duty / Every Minute /
  Off Duty / Shift Status), carried the `shift`/`on-shift`/`duty` aliases over so
  old references still resolve, and dropped the unused `shift` startup profile.
- **Hid the Install Claude Code role from the menu** (`751ba94`) — added a
  `hidden: true` flag + `menu_roles/0` so the dropdown skips it, while `roles/0`
  keeps it resolvable. The first-run Setup wizard's install button and the
  Home-screen install card still work (`startup_command("agent-setup")` →
  `brew install --cask claude-code`); only the power-user terminal menu drops it.

The menu is now: **On Duty · Dispatch Queue · Commands · Prompts**. Tests updated
for both; full suite **657/657**.
