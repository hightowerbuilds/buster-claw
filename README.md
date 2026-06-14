# Buster Claw

`buster-claw` is a desktop runtime where an AI agent manages your web interactivity — browsing, Google Workspace, and third-party integrations — through one auditable command surface. It's a Phoenix/LiveView application wrapped in a Tauri desktop shell; Phoenix lives at the repository root, the desktop shell in `desktop/tauri`.

## How it's used

The way to use Buster Claw is to run **Claude Code or Codex in the built-in terminal**. Work lands in a durable **Dispatch queue** that Buster Claw projects to the workspace markdown the agent already reads (`shift/Dispatch.md`); the agent pulls items, does the work, and writes results back through the `./buster-claw` CLI. The desktop UI gives you the command surface, the Sentinel audit feed, and the results. The intelligence is remote — the agent, not the app. Buster Claw has no built-in LLM and needs no API keys.

## Features

- **Agentic command surface**: One canonical catalog (~70 commands) an AI agent drives across every frontend — CLI and HTTP API — with per-caller trust tiers and a full audit trail.
- **Web & Workspace interactivity**:
  - **Browsing & fetch**: Headless browser + HTTP fetchers (SSRF-guarded) to read and capture web pages and articles.
  - **Google Workspace**: Sync and act on Gmail and Google Calendar.
  - **Integrations**: Pull and react to GitHub, Sentry, and Umami activity (manual or webhook-triggered polls).
- **Dispatch pull-queue**: Trusted inbound requests (e.g. from Gmail triage) land in a durable SQLite queue, projected to workspace markdown; a terminal agent pulls items and writes results back through the CLI.
- **In-app terminal**: A real PTY where you run Claude Code, Codex, or any CLI; the primary surface for agents to drive Buster Claw.
- **Orchestration**: An unattended, indefinite "shift" — a supervised Elixir janitor watches the kill switch (STOP file) and a crash-loop brake while a terminal agent pulls from the Dispatch queue. All work state is durable, so an OTP restart resumes mid-shift.
- **Workspace library**: Documents and artifacts stored as markdown in the workspace, with a blog-style reading view.
- **Sentinel security layer**: Every command, outbound send, and untrusted fetch is recorded on an auditable feed; restricted actions are refused for untrusted callers.

## Quick Start

Requirements:

- Elixir/Erlang
- Rust/Cargo
- `cargo-tauri`

The single-command launcher boots Phoenix, waits for `/_health`, then opens the desktop window (and tears down on Ctrl-C):

```bash
./scripts/dev.sh
```

Manual fallback — run Phoenix and the shell in separate terminals:

```bash
mix phx.server
```

```bash
cd desktop/tauri
cargo tauri dev
```

Phoenix is available directly at `http://127.0.0.1:4000/`; the Tauri shell opens the same app in a native desktop window.

The desktop shell points at `http://127.0.0.1:4000` in dev mode. Override that endpoint when needed:

```bash
cd desktop/tauri
BUSTER_CLAW_PHOENIX_URL=http://127.0.0.1:4001 cargo tauri dev
```

## Configuration

State is managed by Phoenix/Ecto and the local workspace directory:

- `buster_claw_dev.db`: development SQLite database.
- `Library/`: workspace documents and artifacts (markdown).
- Legacy data files such as `sources.json` and `Library/*.json` are migration inputs.

## Driving Buster Claw (CLI, HTTP)

Buster Claw exposes a single canonical command surface across documents, calendar events, Google Workspace (accounts/Gmail/Calendar), integrations, finance, search, browser, runtime, the Dispatch queue, and the orchestration shift. Two frontends consume it:

### Authentication

A loopback API token lives at `~/Library/Application Support/BusterClaw/api_token` (auto-generated on first launch). Override via `BUSTER_CLAW_API_TOKEN`. The Phoenix endpoint binds to `127.0.0.1` only; the token defends against other local users on a shared machine.

### CLI escript

```bash
# Build (once)
mix escript.build

# Run
./buster-claw commands                          # list the catalog
./buster-claw document list                      # noun-verb shorthand
./buster-claw run web_search --json '{"query": "phoenix liveview"}'
./buster-claw run shift_status --json '{}'
./buster-claw terminal open --role mailman --label Mailman
./buster-claw mailman poll --interval 60
```

Token comes from `BUSTER_CLAW_API_TOKEN` env, then the file path above, then `--token <token>` flag. Base URL is `BUSTER_CLAW_URL` env or `--url <url>` flag (default `http://127.0.0.1:4000`).

### Dispatch pull-queue (for Claude Code, Codex, other terminal agents)

The primary way an agent drives Buster Claw is the pull-queue. Trusted inbound requests land in the durable Dispatch queue, which Buster Claw projects to the workspace markdown the agent reads (`shift/Dispatch.md`, grouped by job). A terminal agent works the queue through the `./buster-claw dispatch` verbs:

```bash
./buster-claw mailman poll --interval 60          # feed the queue from Gmail triage
./buster-claw dispatch list                         # see open items
./buster-claw dispatch claim --job mail-triage      # pull the next item for a job
./buster-claw dispatch reply <id> --body "…"        # write a result back
./buster-claw dispatch done <id>                    # close it out (or: block <id>)
```

Trust tiers still apply: untrusted callers may only run safe-tier commands, while restricted commands (deletes, `document_save`, `gmail_send`, …) require a trusted caller.

### HTTP API (for direct integration)

```bash
TOKEN=$(cat ~/Library/Application\ Support/BusterClaw/api_token)

# Catalog (no auth needed)
curl http://127.0.0.1:4000/api/commands

# Invoke a command
curl -X POST http://127.0.0.1:4000/api/run \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"document_list","args":{}}'
```

## Development Notes

- [Quality checks](docs/QUALITY.md) lists the Phoenix and Tauri commands to run before refactors.
- [Architecture notes](docs/ARCHITECTURE.md) documents the current runtime shape, persisted files, and generated-code boundaries.
- [UML / architecture diagrams](docs/UML.md) — Mermaid diagrams of the system layers, supervision tree, domain model, command surface, and HTTP routing.
- [Local trust model](docs/LOCAL_TRUST.md) documents shell hooks, webhooks, stored secrets, fetched markdown, and MCP boundaries.
- [Desktop packaging notes](docs/DESKTOP_PACKAGING.md) document the Phoenix/Tauri desktop path.
- Historical quality plans are archived in `daily-growth/old-maps/`.

## License

MIT
