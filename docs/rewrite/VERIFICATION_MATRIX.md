# Verification Matrix

Automated coverage currently exists for:

- Context CRUD and validation.
- Library artifact indexing and safe filesystem operations.
- URL/RSS ingestion and parser behavior.
- Provider routing and streaming callbacks.
- Chat sessions, slash commands, memory, search, and browser fetch.
- Analysis queue state transitions and report artifact creation.
- Post-report hook events and delivery dispatch after analysis completion.
- Scheduler run-now behavior, `analyze`/`full`/`digest` orchestration, cron parsing, due-job execution, and supervised ticking.
- Webhook trigger authentication and audit persistence.
- Hook execution and persisted hook runs.
- Delivery dispatch attempts.
- MCP stdio startup handshake, supervised failure visibility, and tool discovery.
- Migration importer idempotency.
- LiveView smoke coverage for major routed surfaces.

Manual smoke completed:

- Local loopback parity smoke on 2026-05-26 covered command API/CLI/MCP, provider configuration, source ingestion, raw document reads, queued analysis, report generation, memory/chat, search/browser fetch, calendar, scheduler, webhook, delivery, hook, and restart persistence.

Manual smoke remains before cutover:

- Build a production release.
- Launch through a desktop shell.
- Import a real legacy Library.
- Configure a local Ollama provider or loopback OpenAI-compatible provider.
- Run source ingestion, analysis, report generation, delivery, hooks, scheduler, and webhook flows against real data.
- Restart the app and confirm durable SQLite and Library state survives.
