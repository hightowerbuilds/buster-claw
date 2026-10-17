# Buster Claw Command Surface

`BusterClaw.Commands` is the single command dispatcher used by the HTTP API and
CLI escript.

The live catalog is the source of truth:

```sh
./buster-claw commands
```

or:

```sh
curl -H "Authorization: Bearer $BUSTER_CLAW_API_TOKEN" \
  http://127.0.0.1:4000/api/commands
```

Commands accept one JSON object and return either `{:ok, value}` or
`{:error, reason}` internally. The HTTP and CLI frontends serialize the same
result shape into their transport-specific response format.

## Active Domains

183 commands (`gmail_attachment_download` joined on 10-14; the ten `phone_*` verbs left on 10-15). The three app-tab
layout commands remain included. `./buster-claw commands` is authoritative; the Explained tab's
Command List renders the same counts from a contract test:

- Runtime status, orchestration shifts, and in-shift role sessions
- Visible in-app terminal tabs
- App tab layouts: `app_tabs_list`, `app_tabs_join`, `app_tabs_separate`
- Workspace document library
- The operator's Notes vault (`note_*`) and the Activity record (`journal_*`)
- Calendar events (the app's own, distinct from Google's)
- Finance (SEC EDGAR + Finnhub read surface)
- Google Workspace accounts, Gmail, Calendar, Drive, Docs, Sheets, Slides,
  Tasks, and Contacts
- Web search, guarded browser fetch, co-presence `browser_*`, Agent Mode
  (`agent_run_*`), flows and saved site checks, bookmarks and history
- Notifications (timers, alarms, reminders)
- Sound (`sound_*`): the clip editor and arranger, recording and input levels,
  chime routing
- The Dispatch pull-queue (list/claim/done/block/reply)
- Memory (`memory_search`), skill suggestions, jobs and backgrounds, and the
  model-policy / runtime-status probes

## Trust Tiers

The tier follows the **token presented**, not the route:

- `:trusted` — the operator's CLI and `/api/run`. Runs anything.
- `:terminal` — the in-app PTY. Trusted-equivalent *for the command surface*,
  deliberately and explicitly (`PolicyEngine`), because a shell has to be able to
  work. It is separated at the router instead: `RequireTrusted` refuses it on
  `/api/clinch`, so credential **management** is unreachable from a prompt.
- `:agent_untrusted` — an autonomous run that has touched untrusted-origin
  content. Runs anything **except** the `gated` set (outbound sends, deletes,
  shares). `:restricted` alone does not stop it; `gated` does.
- `:agent` / `:mcp` — may run only `:safe`-tier commands.

`:safe` commands are reads and low-risk probes. `:restricted` commands mutate
state, trigger outbound effects, or send messages. A refusal returns
`{:error, :requires_confirmation}`, is recorded via `Sentinel.Pending`, and is
**not** executed.

Restricted refusals and consequential command invocations are recorded through
`BusterClaw.Sentinel`.

## App Tab Layouts

To join the Browser with the current chat, use
`./buster-claw run app_tabs_join --json '{"tab":"browser"}'`.
`app_tabs_list` reports open app tabs and exact paths; `app_tabs_separate`
returns a joined view to two tabs. Existing browser sessions are reused, and
ambiguous names require an exact path. Layout commands are safe-tier UI
operations and require a connected app window to acknowledge the result.

## In-App Terminal Tabs

Agents can request a new visible Buster Claw terminal without spawning a system
terminal:

```sh
./buster-claw terminal open --role mailman --label Mailman
```

or through the generic command runner:

```sh
./buster-claw run terminal_tab_open --json '{"role_key":"mailman","label":"Mailman","startup_profile":"mailman"}'
```

This queues a browser event for the open Buster Claw UI. The shell is opened by
the app's `/terminal?session=...&label=...` route and remains inside the Tauri
window. It does not call the operating system's default terminal.

The `mailman`, `mail-triage`, and `gmail-poller` roles map to the fixed
`mailman` startup profile. A fresh terminal for that profile runs:

```sh
./buster-claw on-duty
```

That visible loop starts an unattended shift and calls `gmail_sync` through the
local command API on an interval; `off-duty` stands down. Ctrl-C stops only the
polling loop — SIGINT is reserved by the BEAM's break handler and cannot be
trapped, so the shift survives it. Agents
cannot pass arbitrary shell text through this safe command.

## Current Cuts

These older command-surface areas were removed or retired:

- Source/provider/analysis/report/chat commands from the former built-in LLM
  pipeline.
- Legacy source migration commands and importer inputs.
- The MCP server/client surface (`mcp_*`) and the inbound `POST /mcp` endpoint.
- The original headless dispatch **pipeline** (`Pipeline` / `Reporter`); work is
  pulled through the Dispatch queue instead. **`AgentRunner` came back** and is
  load-bearing today — it spawns the harness for unattended runs and backs
  `ModelPolicy.backend_for/1`'s detection. Do not read this line as saying
  headless runs don't exist; they do.
- Delivery destinations, Webhooks, Hooks, and Scheduler jobs — retired as unused.
  Integrations, their one live consumer, outlived them until 10-17, when it was
  deleted whole (GitHub polling and its webhook).
- The *old DB-backed Memory* was retired, but **`BusterClaw.Memory` is live
  again** in a different shape: `Memory.RunSummary` rows written per headless
  run, full-text searched by the catalogued `memory_search`.
- Trading, Portfolio, MarketData, Watchlist and Chart Build — deleted whole on
  08-08 (`293f47f`). `finance_*` (SEC EDGAR + Finnhub) is unrelated and survives.
- Settings → Cmd List and both `terminal_command_*` verbs, deleted 09-05. The
  terminal's command flyout is still there and still shipped; what went is the
  ability to EDIT it — from the page or from an agent. Skills are how new
  capability gets added now, and a composition skill appears in the terminal's
  prompts role on its own.
- The Sketch Pad — six `sketch_*` verbs, its whole context and both its hosts,
  deleted 09-05. **The model's ability to draw is unaffected**: that has always
  been `BusterClaw.SvgViewer`, the chat's SVG channel, which shares nothing with
  the Pad. It reads a fenced ```` ```svg ```` block out of a reply, sanitizes it,
  and renders it as a real SVG.
- Telephony — BusterPhone was removed whole on 10-15 (outbound had gone 08-18;
  the ten intake `phone_*` verbs followed). See
  `daily-growth/roadmaps/integrations/PHONE_REMOVAL_ROADMAP.md`.
