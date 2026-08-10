# Architecture

Buster Claw is now a Phoenix/LiveView application wrapped by a Tauri desktop shell.

## Runtime

- The repository root contains the Elixir application.
- `BusterClawWeb.Endpoint` serves the local UI on `127.0.0.1`.
- Phoenix LiveView owns UI state, streaming updates, forms, and routed surfaces.
- Ecto/SQLite owns structured local state.
- Markdown artifacts remain local files under the configured Library root.
- `desktop/tauri` contains the desktop shell used for development and future packaging.

Buster Claw has no built-in LLM and needs no API keys: the intelligence is an agent CLI the operator installed and signed in to — `claude`, `codex`, or `opencode` (`BusterClaw.ModelPolicy` picks the harness and model per surface). It runs either in the in-app PTY or headlessly via `BusterClaw.AgentRunner`, driving the app through its command surface (`BusterClaw.Commands`) and the workspace files.

## Core Contexts

- `BusterClaw.Commands`: the single canonical command surface dispatched by every frontend (HTTP API, CLI escript), with per-caller trust tiers.
- `BusterClaw.Library`: workspace documents and artifact metadata (markdown files under the Library root).
- `BusterClaw.Browser` (+ `BusterClaw.Ingest.Content`): SSRF-guarded fetch and HTML→markdown rendering, with a native-webview live-render upgrade for JS-thin pages.
- `BusterClaw.Search`: web search.
- `BusterClaw.Google`: Google OAuth, Gmail, and Calendar sync (tokens in `BusterClaw.Google.Vault`).
- `BusterClaw.Calendar`: durable calendar events.
- `BusterClaw.Integrations`: GitHub / Sentry / Umami polling (manual or webhook-triggered via `POST /integrations/:name/webhook`).
- `BusterClaw.Finance`: read-only SEC EDGAR + Finnhub research (backs the Financial Informant page).
- `BusterClaw.Dispatch` (+ `BusterClaw.DispatchProjector`): the durable SQLite pull-queue and its projection to workspace markdown (`Dispatch.md`) that a terminal agent works.
- `BusterClaw.Orchestration`: the unattended, indefinite "shift" — `Orchestrator` (a supervised kill-switch janitor), `Uptime`, and the `shifts` / `shift_assignments` schemas.
- `BusterClaw.Sentinel`: the security/audit spine — every command, outbound send, and untrusted fetch is recorded; restricted actions from untrusted callers are refused and queued.
- `BusterClaw.Telephony` (+ `BusterClawWeb.PhoneLive`): BusterPhone — inbound voicemail and SMS drained from a signed relay, transcripts, the local message archive, and the trusted-caller/PIN gates that decide what becomes queue work.
- `BusterClaw.Notes`: the operator's Markdown vault under `notes/` — the Home Notes tab, `note_*` commands, `[[wiki links]]` and backlinks. Distinct from `BusterClaw.Journal` (the Activity record) and from the Library.
- `BusterClaw.BrowserControl` (+ `BusterClaw.AgentRuns`): co-presence verbs against the live tab, plus Agent Mode — a separate Chromium with a frozen scope and a payment gate.
- `BusterClaw.Clinch`: the credential store — one chokepoint for encrypted values, with use (in-BEAM) split from management (Tauri IPC → loopback `/api/clinch`). See `daily-growth/roadmaps/integrations/CLINCH_ROADMAP.md`.
- `BusterClaw.Notifications`: timers, alarms, reminders, and the SoundBoard chime routing.
- `BusterClaw.Appearance` (+ `BusterClaw.Shaders`): one background catalog — built-in WGSL shaders, workspace `shaders/*.wgsl`, and uploaded images — shared by the homepage and the terminal.
- `BusterClaw.Memory`: `Memory.RunSummary` rows capturing each headless run, full-text searched by `memory_search`.
- `BusterClaw.Settings`: app settings.

> The Trading, Portfolio, MarketData, Watchlist and Chart Build contexts were **deleted whole on 08-08** (`293f47f`, ~22k lines). `BusterClaw.Finance` above is what survived — it never held broker credentials.

## Desktop Shell

The Tauri shell is intentionally thin in development: it opens the Phoenix app at `http://127.0.0.1:4000` and hosts the PTY that backs the in-app terminal (`desktop/tauri/src/terminal.rs`). For day-to-day dev use `scripts/dev.sh`, which boots Phoenix, waits for `/_health`, then opens the window. The release path is self-contained: `scripts/build_desktop.sh` bundles the Mix release + BEAM into a `.app`/`.dmg`; the packaged shell spawns Phoenix on a private port and shows the window once the endpoint is healthy.
