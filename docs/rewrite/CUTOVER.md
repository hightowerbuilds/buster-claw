# Cutover Decision

Current decision: ready for packaged local daily-use trial.

What is ready:

- Phoenix/LiveView rewrite skeleton.
- SQLite data model and contexts.
- Sources, documents, providers, chat, analysis, search, scheduler, webhooks, hooks, delivery, memory, calendar, MCP configuration, browser fetch boundary, and migration importer.
- Automated test suite for the implemented parity slices.
- Local manual parity smoke with a loopback OpenAI-compatible provider completed on 2026-05-26, including ingestion, raw documents, analysis, reports, memory/chat, search/browser fetch, calendar, scheduler, webhook, delivery, hook, and restart persistence checks.
- Packaged release smoke completed on 2026-05-26 against an isolated temp data
  directory using the bundled release from the macOS `.app`, the repo-local
  legacy `sources.json`, and a loopback OpenAI-compatible provider.

Packaged smoke notes:

- Built `desktop/tauri/target/release/bundle/macos/Buster Claw.app`.
- Built `desktop/tauri/target/release/bundle/dmg/Buster Claw_0.1.0_x64.dmg`.
- Started the bundled release binary with isolated `DATABASE_PATH`,
  `BUSTER_CLAW_LIBRARY_ROOT`, `HOME`, and `SECRET_KEY_BASE`.
- Ran the release migrator and `BusterClaw.Migration.import_all/1`.
- Imported 11 sources from the repo-local legacy `sources.json`.
- Verified command catalog, authenticated HTTP API, CLI, and MCP command-surface
  calls against the packaged release.
- Created and tested a loopback provider, then ran chat and analysis.
- Saved one raw document, generated one analysis report, and ingested the
  imported Hacker News RSS source, writing 20 additional raw documents.
- Created and verified memory, calendar, scheduler, hook, delivery, and webhook
  records.
- Restarted the bundled release against the same database and confirmed migrated
  and generated state persisted.

Remaining caveats:

- No full legacy `Library/` corpus was present in this checkout or the common
  searched local user-data/project locations. The packaged import smoke therefore
  used the available real legacy input, `sources.json`, plus generated smoke data.
- Real external provider credential smoke testing remains deferred.
- Playwright/browser-rendered ingestion is available as an opt-in supervised
  sidecar path; browser binary installation and release bundling remain
  deferred.

What is now ready (was previously blocking):

- macOS desktop packaging via `scripts/build_desktop.sh` — produces `.app` and `.dmg` that bundle the Mix release, BEAM runtime, and Phoenix app. Spawns the release as a child process on launch; data lives in `~/Library/Application Support/BusterClaw/`. See `docs/rewrite/DESKTOP_PACKAGING.md`.
- Unified command surface (`BusterClaw.Commands`) exposed through three frontends: HTTP API at `/api/run`, CLI escript at `./buster-claw`, and an MCP server at `/mcp` for external TUI agents (Claude Code, Codex). See `docs/rewrite/COMMAND_SURFACE.md` and `scripts/smoke_command_surface.sh`.
- Internal-agent tool wiring: Anthropic providers run an agentic loop with safe-tier commands exposed as tools. OpenAI/Gemini/Codex still use plain chat (provider-specific tool adapters are planned).
- Legacy migration coverage for automation configuration: `mcp.json`, `Library/delivery.json`, `Library/hooks.json`, `Library/webhooks.json`, `Library/scheduler.json`, and `Library/reports/manifest.json`.
- Autonomous scheduler ticking with five-field cron parsing, common aliases, due-job selection, and `next_run_at` advancement.
- Scheduler workflow orchestration for `analyze`, `full`, and `digest` jobs. Custom scheduler commands remain recorded-only by design.
- Browser-rendered ingestion sidecar: opt-in supervised Node Playwright sidecar
  boundary is implemented, and browser source ingestion now routes through the
  browser boundary. HTTP fallback remains available for RSS and
  static/server-rendered sources.
- MCP stdio supervision and startup JSON-RPC handshakes: configured local servers launch as supervised Port-backed clients and run `initialize` plus `tools/list` discovery.
- Real external provider credential smoke testing: deferred.
- Packaged release import and smoke testing with available real legacy source
  data: complete.

Cutover rule:

- Treat the Phoenix/Tauri rewrite as the only application path for local daily-use
  trial. Keep external credential testing, Playwright binary bundling, and
  distribution hardening tracked as follow-up work rather than cutover blockers.
