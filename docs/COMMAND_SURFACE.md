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

203 commands as of 08-09 (`./buster-claw commands` is authoritative; the Explained
tab's Command List renders the same counts from a contract test):

- Runtime status, orchestration shifts, and in-shift role sessions
- Visible in-app terminal tabs, and the editable terminal Cmd List
- Workspace document library
- The operator's Notes vault (`note_*`) and the Activity record (`journal_*`)
- Calendar events (the app's own, distinct from Google's)
- Third-party integrations and integration runs
- Finance (SEC EDGAR + Finnhub read surface)
- Google Workspace accounts, Gmail, Calendar, Drive, Docs, Sheets, Slides,
  Tasks, and Contacts
- Web search, guarded browser fetch, co-presence `browser_*`, Agent Mode
  (`agent_run_*`), flows and saved site checks, bookmarks and history
- BusterPhone: voicemail, SMS, trusted callers and PINs
- Notifications (timers, alarms, reminders) and sound
- The Dispatch pull-queue (list/claim/done/block/reply)
- Memory (`memory_search`) and skill suggestions

## Trust Tiers

The tier follows the **token presented**, not the route:

- `:trusted` — the operator's CLI and `/api/run`. Runs anything.
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
  Integrations (their one live consumer) is kept and now polls manually or via
  `POST /integrations/:name/webhook`.
- The *old DB-backed Memory* was retired, but **`BusterClaw.Memory` is live
  again** in a different shape: `Memory.RunSummary` rows written per headless
  run, full-text searched by the catalogued `memory_search`.
- Trading, Portfolio, MarketData, Watchlist and Chart Build — deleted whole on
  08-08 (`293f47f`). `finance_*` (SEC EDGAR + Finnhub) is unrelated and survives.
