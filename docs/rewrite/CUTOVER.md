# Cutover Decision

Current decision: not ready for packaged daily use.

What is ready:

- Phoenix/LiveView rewrite skeleton.
- SQLite data model and contexts.
- Sources, documents, providers, chat, analysis, search, scheduler, webhooks, hooks, delivery, memory, calendar, MCP configuration, browser fetch boundary, and migration importer.
- Automated test suite for the implemented parity slices.

What blocks cutover:

- Desktop release packaging is still a plan, not an installer.
- MCP stdio supervision and JSON-RPC handshakes are not implemented.
- Browser automation uses the fetch boundary and HTTP fallback, not a supervised Playwright sidecar.
- Scheduler cron parsing and autonomous ticking are not implemented.
- Legacy imports do not yet cover every automation JSON file.
- Real-world provider, source, and report workflows need manual smoke testing against existing user data.

Cutover rule:

- Treat the Phoenix/Tauri rewrite as the only application path. Do not declare it daily-use ready until the packaged release imports real data and completes the manual parity smoke test.
