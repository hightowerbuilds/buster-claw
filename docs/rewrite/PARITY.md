# Elixir Rewrite Parity Contract

## Purpose

The Elixir rewrite is a parity rewrite first. The new system should reach the current Buster Claw product surface before adding major new product capabilities.

The architectural target is Elixir, OTP, Phoenix LiveView, SQLite/Ecto, supervised workers, PubSub streaming, durable job state, and a Tauri desktop shell around a local endpoint.

## Current User-Facing Views

- [ ] Home: shows scheduled jobs, calendar events, recent reports, documents, queue state, and pending files.
- [ ] Chat: supports model chat, streaming responses, search state, waiting state, and slash commands.
- [ ] Sources: manages ingestion sources and starts full or single-source ingestion.
- [ ] Documents: lists raw ingested documents, pending files, queue entries, document preview, queue actions, delete actions, and run-queue action.
- [ ] Analysis: lists generated reports and opens report content.
- [ ] Calendar: manages user calendar events and scheduled jobs.
- [ ] Intelligence: manages local models and remote providers.
- [ ] Webhooks / Hooks: manages local webhook triggers and reactive pipeline hooks.
- [ ] Advanced: manages delivery destinations and persistent memory.

## Current Core Workflows

- [ ] Select a local Ollama model.
- [ ] Configure a remote provider.
- [ ] Set one remote provider active.
- [ ] Test provider connectivity.
- [ ] Send a chat message.
- [ ] Stream assistant tokens into the chat UI.
- [ ] Clear chat history.
- [ ] Save persistent memory.
- [ ] List persistent memories.
- [ ] Remove persistent memory.
- [ ] Add an ingestion source.
- [ ] Delete an ingestion source.
- [ ] Run full ingestion across configured sources.
- [ ] Run ingestion for a single source.
- [ ] Expand RSS feeds into entries.
- [ ] Fetch normal URL content.
- [ ] Fetch browser-rendered content.
- [ ] Save raw documents as markdown artifacts.
- [ ] List raw documents.
- [ ] Preview raw document content.
- [ ] Delete raw documents with library path validation.
- [ ] List pending unprocessed documents.
- [ ] Queue a raw document for analysis.
- [ ] Remove a non-running document from the queue.
- [ ] Run analysis on explicitly queued documents.
- [ ] Drain pending raw documents into the analysis queue.
- [ ] Generate an intentions-guided markdown report.
- [ ] Save report markdown artifacts.
- [ ] List report manifest entries.
- [ ] Open report content.
- [ ] Add delivery destination.
- [ ] Test delivery destination.
- [ ] Delete delivery destination.
- [ ] Dispatch reports to enabled delivery destinations after report generation.
- [ ] Add scheduled job.
- [ ] Update scheduled job.
- [ ] Delete scheduled job.
- [ ] Run scheduled job immediately.
- [ ] Add local webhook.
- [ ] Enable or disable local webhook.
- [ ] Delete local webhook.
- [ ] Trigger ingest, analyze, full, or custom command from a local webhook.
- [ ] Add reactive hook.
- [ ] Delete reactive hook.
- [ ] Run shell hooks with JSON stdin.
- [ ] Run webhook hooks with JSON payload.
- [ ] Track recent hook execution results.
- [x] Load and connect configured MCP servers.
- [x] Discover MCP tools.
- [x] Show MCP server/tool status.
- [x] Inject MCP tool summaries into chat context.
- [ ] Add calendar event.
- [ ] Update calendar event.
- [ ] Delete calendar event.

## Current Slash Commands

- [ ] `/search <query>`: search the web and either show raw results or stream a model summary.
- [ ] `/ingest <url>`: ingest a URL as an article source.
- [ ] `/browse <url>`: fetch and render a URL through the browser engine and display parsed content.
- [ ] `/status`: show pipeline phase, queue depth, active job, completed jobs, and failed jobs.
- [ ] `/clear`: clear chat history and streaming state.
- [ ] `/remember <text>`: save a persistent memory entry.
- [ ] `/forget <number>`: remove a persistent memory entry by 1-based index.
- [ ] `/memories`: list saved memories.
- [x] `/mcp`: list connected MCP servers and discovered tools.
- [ ] `/help`: list available commands.

## External Integrations To Preserve

- [ ] Ollama model listing and streaming chat.
- [ ] OpenAI-compatible chat completions streaming.
- [ ] OpenRouter defaults.
- [ ] Anthropic streaming.
- [ ] Custom OpenAI-compatible provider endpoint.
- [ ] DuckDuckGo HTML-style web search or a deliberate equivalent.
- [ ] RSS/Atom fetching.
- [ ] HTTP article fetching.
- [ ] Browser-rendered fetching.
- [x] MCP stdio server launching and startup JSON-RPC handshakes.
- [ ] Slack webhook delivery.
- [ ] Discord webhook delivery.
- [ ] Telegram bot delivery.
- [ ] Local shell hook execution.
- [ ] Outbound webhook hook execution.
- [ ] Local inbound webhook server on `127.0.0.1`.

## Runtime Behavior To Preserve

- [ ] Local-first state and artifacts.
- [ ] No required remote hosted backend.
- [x] Desktop app runs through a Tauri shell around a local Phoenix endpoint.
- [ ] Webhooks bind to localhost by default.
- [ ] Webhook secrets are optional but enforced when configured.
- [ ] Provider secrets remain local.
- [ ] Markdown artifacts remain inspectable on disk.
- [ ] Model streaming is visible in real time.
- [ ] Orchestrator and queue status is visible in real time.
- [ ] Individual integration failures should be visible without taking down the app.

## Rough Edges To Correct During Rewrite

These are current implementation issues that should not be preserved as-is:

- [x] Removed the legacy Go desktop app path from the active repo.
- [ ] Queue state is split between in-memory queue entries and `Library/queue.json`.
- [ ] Reports rely on both filesystem scanning and manifest reads.
- [ ] Many app services persist separate JSON files without transactional boundaries.
- [ ] Scheduler runtime state is transient while job definitions are persisted.
- [ ] Delivery attempts are fire-and-forget and not durable.
- [ ] Hook results are bounded in memory but not durable.
- [ ] MCP process failure is logged/emitted but not modeled as supervised state.
- [ ] Browser automation needs a more explicit sidecar boundary.

## Deferred Until After Parity

- [ ] Cloud sync.
- [ ] Multi-user accounts.
- [ ] Hosted server mode as a primary deployment.
- [ ] Major agent planning redesign.
- [ ] Native mobile app.
- [ ] Full secrets encryption/keychain integration.
- [ ] Advanced report collaboration.
- [ ] Database-only artifact storage.

## Minimum Parity Demo

The rewrite is not at useful parity until this flow works end to end:

- [ ] Start the desktop app.
- [ ] Configure a provider or select a local Ollama model.
- [ ] Add a source.
- [ ] Ingest content.
- [ ] View the raw document.
- [ ] Queue the raw document.
- [ ] Run analysis.
- [ ] Generate and save a report.
- [ ] View the report.
- [ ] Add a memory.
- [ ] Chat with memory context.
- [ ] Add a scheduled or webhook-triggered pipeline action.
- [ ] Trigger that action.
- [ ] Restart the app.
- [ ] Confirm sources, documents, queue/report state, memory, calendar, providers, webhooks, hooks, delivery destinations, and scheduler definitions survive.
