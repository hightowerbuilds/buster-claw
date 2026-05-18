# Cutover Decision

Current decision: not ready for packaged daily use.

What is ready:

- Phoenix/LiveView rewrite skeleton.
- SQLite data model and contexts.
- Sources, documents, providers, chat, analysis, search, scheduler, webhooks, hooks, delivery, memory, calendar, MCP configuration, browser fetch boundary, and migration importer.
- Automated test suite for the implemented parity slices.

What blocks cutover:

- MCP stdio supervision and JSON-RPC handshakes are not implemented.
- Browser automation uses the fetch boundary and HTTP fallback, not a supervised Playwright sidecar.
- Scheduler cron parsing and autonomous ticking are not implemented.
- Legacy imports do not yet cover every automation JSON file.
- Real-world provider, source, and report workflows need manual smoke testing against existing user data.

What is now ready (was previously blocking):

- macOS desktop packaging via `scripts/build_desktop.sh` — produces `.app` and `.dmg` that bundle the Mix release, BEAM runtime, and Phoenix app. Spawns the release as a child process on launch; data lives in `~/Library/Application Support/BusterClaw/`. See `docs/rewrite/DESKTOP_PACKAGING.md`.
- Unified command surface (`BusterClaw.Commands`) exposed through three frontends: HTTP API at `/api/run`, CLI escript at `./buster-claw`, and an MCP server at `/mcp` for external TUI agents (Claude Code, Codex). See `docs/rewrite/COMMAND_SURFACE.md` and `scripts/smoke_command_surface.sh`.
- Internal-agent tool wiring: Anthropic providers run an agentic loop with safe-tier commands exposed as tools. OpenAI/Gemini/Codex still use plain chat (provider-specific tool adapters are planned).

Cutover rule:

- Treat the Phoenix/Tauri rewrite as the only application path. Do not declare it daily-use ready until the packaged release imports real data and completes the manual parity smoke test.
