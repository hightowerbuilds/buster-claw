# Buster Claw Command Surface

`BusterClaw.Commands` is the single command dispatcher used by the HTTP API,
MCP endpoint, and CLI escript.

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
`{:error, reason}` internally. HTTP and MCP frontends serialize the same result
shape into their transport-specific response format.

## Active Domains

- Runtime status
- Workspace document library
- Memory
- Calendar events
- MCP server configuration and tool discovery
- Webhooks
- Hooks
- Delivery destinations and dispatch
- Scheduler jobs
- Third-party integrations and integration runs
- Google Workspace accounts, Gmail, and Calendar sync
- Web search and guarded browser fetch
- Orchestration shifts and in-shift role sessions
- Visible in-app terminal tabs for role sessions

## Trust Tiers

- `:safe` commands are reads and low-risk probes exposed to untrusted MCP
  callers.
- `:restricted` commands mutate state, trigger outbound effects, run scheduler
  jobs, test operator-defined hooks, or send messages. Untrusted callers receive
  `{:error, :requires_confirmation}` for these commands.

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
./buster-claw mailman poll
```

That visible loop calls `gmail_sync` through the local command API on an
interval. Agents cannot pass arbitrary shell text through this safe command.

## Current Cuts

These older command-surface areas were removed or retired:

- Source/provider/analysis/report/chat commands from the former built-in LLM
  pipeline.
- Legacy source migration commands and importer inputs.
- Custom scheduler command placeholders.
- Webhook `custom_cmd` / `deliver_to` placeholder fields.
- Bulk hook event execution; hooks remain individually testable.
- Swoosh-backed email delivery; delivery now uses outbound HTTP destinations.
