# Architecture

Buster Claw is now a Phoenix/LiveView application wrapped by a Tauri desktop shell.

## Runtime

- The repository root contains the Elixir application.
- `BusterClawWeb.Endpoint` serves the local UI on `127.0.0.1`.
- Phoenix LiveView owns UI state, streaming updates, forms, and routed surfaces.
- Ecto/SQLite owns structured local state.
- Markdown artifacts remain local files under the configured Library root.
- `desktop/tauri` contains the desktop shell used for development and future packaging.

Buster Claw has no built-in LLM and needs no API keys: the intelligence is a terminal agent (Claude Code / Codex) running in the in-app PTY, driving the app through its command surface (`BusterClaw.Commands`) and the workspace files.

## Core Contexts

- `BusterClaw.Commands`: the single canonical command surface dispatched by every frontend (HTTP API, CLI escript, MCP server), with per-caller trust tiers.
- `BusterClaw.Library`: workspace documents and artifact metadata (markdown files under the Library root).
- `BusterClaw.Browser` (+ `BusterClaw.Ingest.Content`): SSRF-guarded fetch and HTML→markdown rendering; optional Playwright sidecar.
- `BusterClaw.Search`: web search.
- `BusterClaw.Google`: Google OAuth, Gmail, and Calendar sync (tokens in `BusterClaw.Google.Vault`).
- `BusterClaw.Calendar`: durable calendar events.
- `BusterClaw.Integrations`: GitHub / Sentry / Umami polling.
- `BusterClaw.Delivery`: outbound delivery to Slack / Discord / Telegram-compatible webhooks.
- `BusterClaw.Automation`: MCP host/client, scheduler, webhooks, and hooks.
- `BusterClaw.Orchestration`: the unattended "shift" — `Orchestrator` (deterministic GenServer brain), `AgentRunner` (headless `claude -p` / `codex exec`), `Pipeline`, `Reporter`, `Uptime`, and the `orchestrator_tasks` / `agent_runs` / `shifts` schemas.
- `BusterClaw.Sentinel`: the security/audit spine — every command, outbound send, and untrusted fetch is recorded; restricted actions from untrusted callers are refused and queued.
- `BusterClaw.Memory`: persistent agent memory.
- `BusterClaw.Settings`: app settings.

## Desktop Shell

The Tauri shell is intentionally thin in development: it opens the Phoenix app at `http://127.0.0.1:4000` and hosts the PTY that backs the in-app terminal (`desktop/tauri/src/terminal.rs`). For day-to-day dev use `scripts/dev.sh`, which boots Phoenix, waits for `/_health`, then opens the window. The release path is self-contained: `scripts/build_desktop.sh` bundles the Mix release + BEAM into a `.app`/`.dmg`; the packaged shell spawns Phoenix on a private port and shows the window once the endpoint is healthy.
