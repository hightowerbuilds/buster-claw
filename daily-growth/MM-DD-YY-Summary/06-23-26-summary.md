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

## Notes

- Continues the `on-duty` consolidation from the 06-22 summary. The operator now
  has exactly one way to go hands-off: `./buster-claw on-duty` (governed shift +
  Gmail poll + in-thread replies), not a second ungoverned autopilot loop.
