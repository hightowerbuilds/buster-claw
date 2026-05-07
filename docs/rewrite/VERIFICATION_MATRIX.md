# Verification Matrix

Automated coverage currently exists for:

- Context CRUD and validation.
- Library artifact indexing and safe filesystem operations.
- URL/RSS ingestion and parser behavior.
- Provider routing and streaming callbacks.
- Chat sessions, slash commands, memory, search, and browser fetch.
- Analysis queue state transitions and report artifact creation.
- Scheduler run-now behavior.
- Webhook trigger authentication and audit persistence.
- Hook execution and persisted hook runs.
- Delivery dispatch attempts.
- Migration importer idempotency.
- LiveView smoke coverage for major routed surfaces.

Manual smoke remains before cutover:

- Build a production release.
- Launch through a desktop shell.
- Import a real legacy Library.
- Configure a real local Ollama provider.
- Run source ingestion, analysis, report generation, delivery, hooks, scheduler, and webhook flows against real data.
- Restart the app and confirm durable SQLite and Library state survives.
