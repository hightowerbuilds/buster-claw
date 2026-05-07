# Elixir Rewrite Roadmap

## Purpose

This roadmap describes the Buster Claw Phoenix/Tauri rewrite, targeting roughly the same completed functionality and feature coverage as the removed legacy desktop implementation while moving the runtime foundation to Elixir, OTP, Phoenix LiveView, and SQLite-backed state.

The goal is parity first. This is not a product expansion roadmap. New major features should wait until the rewritten app can perform the same core workflows the current app already supports.

## Current Product Surface To Preserve

The current app provides a local-first research and automation environment with these major capabilities:

- [ ] Desktop app shell
- [ ] Chat with local Ollama models
- [ ] Chat or analysis through configured remote providers
- [ ] Streaming model responses
- [ ] Slash commands
- [ ] Persistent memory
- [ ] Source configuration
- [ ] URL ingestion
- [ ] RSS ingestion
- [ ] Browser-rendered ingestion
- [ ] Raw document library
- [ ] Analysis queue
- [ ] Intentions-guided document analysis
- [ ] Markdown report generation
- [ ] Report manifest and report browsing
- [ ] Delivery destinations
- [ ] Scheduled jobs
- [ ] Local webhook server
- [ ] Reactive shell and webhook hooks
- [ ] MCP server launching
- [ ] MCP tool discovery
- [ ] Calendar events
- [ ] Home/status views

## Non-Goals Until Parity

- [ ] Do not redesign the whole product concept.
- [ ] Do not add multi-user cloud sync.
- [ ] Do not add remote hosted deployment as a primary target.
- [ ] Do not add a new agent planning layer before the existing ingestion-analysis-report pipeline works.
- [ ] Do not replace markdown artifacts with database-only storage.
- [ ] Do not build native packaging first; package after the local runtime is stable.

## Target Stack

- [ ] Elixir application runtime
- [ ] OTP supervision tree
- [ ] Phoenix web layer
- [ ] Phoenix LiveView UI
- [ ] Phoenix PubSub for streaming state and runtime events
- [ ] SQLite for structured local state
- [ ] Ecto for schemas, migrations, and queries
- [ ] Oban or an equivalent durable job layer for ingestion, analysis, delivery, hooks, and scheduler work
- [ ] Filesystem-backed markdown artifact storage for raw documents and reports
- [ ] Supervised Node Playwright sidecar for browser-rendered fetches
- [ ] Desktop shell through Tauri, Electron, or a small native webview wrapper pointed at `127.0.0.1`

## Proposed OTP Shape

The rewritten app should make the runtime model explicit.

- [ ] `BusterClaw.Application` starts the core supervision tree.
- [ ] `BusterClaw.Repo` owns SQLite persistence.
- [ ] `BusterClaw.PubSub` broadcasts chat tokens, job state, queue updates, MCP status, hook results, delivery results, and scheduler activity.
- [ ] `BusterClaw.Library` owns raw document and report artifact paths.
- [x] `BusterClaw.Chat.SessionRegistry` tracks active chat sessions.
- [ ] `BusterClaw.Chat.Session` owns chat history, active model/provider, streaming state, cancellation state, memory context, and MCP summaries.
- [ ] `BusterClaw.ProviderRegistry` resolves the active provider and exposes provider behavior modules.
- [ ] `BusterClaw.Ingest.Supervisor` supervises ingestion work.
- [ ] `BusterClaw.Analysis.Supervisor` supervises analysis workers or queues durable analysis jobs.
- [ ] `BusterClaw.MCP.Supervisor` supervises configured MCP server processes.
- [ ] `BusterClaw.Scheduler` manages scheduled local workflows.
- [ ] `BusterClaw.Webhooks` exposes local-only Phoenix routes.
- [ ] `BusterClaw.Hooks.Supervisor` runs configured hooks with timeout and audit logs.
- [ ] `BusterClaw.Delivery.Supervisor` runs delivery attempts as observable jobs.
- [ ] `BusterClaw.Memory` stores and formats persistent memory.
- [ ] `BusterClaw.Calendar` stores user-authored calendar events.

## Phase 0: Freeze Parity Scope

Deliverable: written parity contract before implementation begins.

- [x] Create `docs/rewrite/PARITY.md`.
- [x] List every legacy backend workflow.
- [x] List every legacy user-facing view.
- [x] List every current slash command.
- [x] List every persisted file and directory.
- [x] List every current background process or goroutine-style workflow.
- [x] List every current external integration.
- [x] Decide which current rough edges must be preserved for parity and which can be corrected during the rewrite.
- [x] Define explicit deferred features.
- [x] Define the minimum demo workflow for parity.

Minimum parity demo:

- [ ] Configure a source.
- [ ] Ingest content.
- [ ] View the raw document.
- [ ] Queue the document for analysis.
- [ ] Generate a report.
- [ ] View the report.
- [x] Chat with memory context.
- [ ] Run a scheduled or webhook-triggered pipeline.
- [ ] Restart the app and confirm state survives.

## Phase 1: Phoenix Skeleton

Deliverable: bootable local Phoenix/LiveView app with SQLite and a minimal status UI.

- [x] Create the Phoenix app.
- [x] Configure SQLite.
- [x] Add Ecto repo.
- [x] Add Phoenix PubSub.
- [x] Add LiveView.
- [x] Add base layout.
- [x] Add local runtime configuration.
- [x] Add application supervision tree.
- [x] Add health/status LiveView.
- [x] Add basic app navigation matching the current major views.
- [x] Add local library path configuration.
- [x] Add development start command.
- [x] Add test command.

Acceptance checks:

- [x] App boots with `mix phx.server`.
- [x] SQLite database is created locally.
- [x] Migrations run cleanly.
- [x] LiveView renders without frontend build complexity.
- [x] Runtime status view shows app, database, library path, and job system status.

## Phase 2: Data Model

Deliverable: stable schemas and migrations for structured app state.

- [x] Create `sources` table.
- [x] Create `providers` table.
- [x] Create `mcp_servers` table.
- [x] Create `webhooks` table.
- [x] Create `hooks` table.
- [x] Create `delivery_destinations` table.
- [x] Create `scheduler_jobs` table.
- [x] Create `calendar_events` table.
- [x] Create `memories` table.
- [x] Create `documents` table.
- [x] Create `reports` table.
- [x] Create `analysis_jobs` table.
- [x] Create `delivery_attempts` table.
- [x] Create `hook_runs` table.
- [x] Create `runtime_events` or `audit_events` table.
- [x] Add indexes for common UI and worker queries.
- [x] Add changesets with validation.
- [x] Add context modules around each major domain.

State ownership rules:

- [x] SQLite owns structured configuration.
- [x] SQLite owns workflow state.
- [x] SQLite owns current job status.
- [x] SQLite owns report and document metadata.
- [x] Filesystem owns raw markdown documents.
- [x] Filesystem owns generated markdown reports.
- [x] Imports may read old JSON and markdown files, but the new app should not keep split-brain state.

Acceptance checks:

- [x] `mix ecto.migrate` succeeds.
- [x] Basic CRUD tests pass for every context.
- [x] Unique constraints prevent duplicate source/provider/hook names where appropriate.
- [x] Document and report records can point to markdown artifact paths.

## Phase 3: Library And Documents

Deliverable: local artifact manager and document browsing.

- [x] Implement `BusterClaw.Library`.
- [x] Define local library root.
- [x] Create raw document directory structure.
- [x] Create report directory structure.
- [x] Implement safe path joining.
- [x] Implement path validation for reads/deletes.
- [x] Implement frontmatter builder for raw documents.
- [x] Implement frontmatter parser for raw documents.
- [x] Implement document metadata extraction.
- [x] Implement content hashing.
- [x] Implement deduplication by URL and content hash.
- [x] Implement raw document save.
- [x] Implement raw document read with frontmatter stripping.
- [x] Implement raw document delete.
- [x] Build Documents LiveView.
- [x] Build document inspector/preview.

Acceptance checks:

- [x] Markdown documents save under the configured library.
- [x] Document metadata is queryable from SQLite.
- [x] Deleting a document cannot escape the library root.
- [x] Existing markdown artifacts can be indexed without rewriting them.

## Phase 4: Ingestion

Deliverable: URL and RSS ingestion parity.

- [x] Implement source CRUD.
- [x] Build Sources/Ingestion LiveView.
- [x] Implement HTTP fetcher.
- [x] Add request timeout.
- [x] Add body size limit.
- [x] Add retry policy for transient failures.
- [x] Add user agent.
- [x] Implement HTML parsing.
- [x] Implement readability extraction.
- [x] Implement HTML-to-markdown conversion.
- [x] Implement RSS/Atom expansion.
- [x] Save fetched entries through `BusterClaw.Library`.
- [x] Persist ingestion results and errors.
- [x] Broadcast ingestion progress through PubSub.
- [x] Add tests for RSS expansion.
- [x] Add tests for failed fetch handling.

Acceptance checks:

- [x] User can add a source.
- [x] User can run ingest.
- [x] URL content saves to `Library/raw`.
- [x] RSS entries save as separate raw documents.
- [x] UI shows success and failure counts.

## Phase 5: Providers

Deliverable: provider configuration and streaming provider behavior.

- [x] Define `BusterClaw.Provider` behaviour.
- [x] Implement Ollama provider.
- [x] Implement OpenAI-compatible provider.
- [x] Implement OpenRouter defaults.
- [x] Implement Anthropic provider.
- [x] Implement custom provider configuration.
- [x] Implement provider CRUD.
- [x] Implement active provider selection.
- [x] Implement provider test request.
- [x] Store API keys locally.
- [x] Add provider timeout handling.
- [x] Add streaming callback contract.
- [x] Add provider error normalization.
- [x] Build Providers/Intelligence LiveView.

Acceptance checks:

- [x] User can configure a provider.
- [x] User can set one provider active.
- [x] Test connection reports a useful result.
- [x] Streaming works through the provider behavior.

## Phase 6: Chat

Deliverable: chat parity with streaming state and slash commands.

- [x] Implement chat session registry.
- [x] Implement chat session GenServer.
- [x] Store current session history.
- [ ] Support cancellation state.
- [x] Inject memory context.
- [x] Inject MCP tool summary context.
- [x] Stream tokens through PubSub.
- [x] Build Chat LiveView.
- [x] Implement `/help`.
- [x] Implement `/status`.
- [x] Implement `/clear`.
- [x] Implement `/remember`.
- [x] Implement `/forget`.
- [x] Implement `/memories`.
- [x] Implement `/search`.
- [x] Implement `/ingest`.
- [x] Implement `/browse` through the browser fetch boundary.
- [x] Implement `/mcp`.
- [ ] Add natural-language web search detection if preserving current behavior.

Acceptance checks:

- [x] User messages appear immediately.
- [x] Assistant tokens stream into the UI.
- [x] Finished messages persist in session state.
- [x] Slash commands return visible assistant messages.
- [x] Provider errors surface without crashing the session.

## Phase 7: Analysis Queue And Reports

Deliverable: current ingestion to analysis to report workflow.

- [x] Implement `BusterClaw.Intentions`.
- [x] Load `Intentions.md` or migrate it to structured config with markdown export.
- [x] Implement analysis job schema.
- [x] Implement queue document action.
- [x] Implement drain pending documents action.
- [x] Implement durable job state transitions: queued, analyzing, done, failed.
- [ ] Add queue concurrency setting.
- [ ] Keep local Ollama analysis single-worker by default.
- [ ] Allow configured remote providers to run with higher concurrency.
- [ ] Implement per-document timeout.
- [x] Implement report generation prompt.
- [x] Implement markdown file-block extraction.
- [x] Implement fallback report wrapping.
- [x] Implement report frontmatter builder.
- [x] Save report markdown artifact.
- [x] Store report metadata in SQLite.
- [x] Mark source document processed after successful report.
- [x] Broadcast queue status through PubSub.
- [x] Build queue UI.
- [x] Build report manifest UI.
- [x] Build report reader UI.

Acceptance checks:

- [x] User can queue a raw document.
- [x] User can run analysis.
- [x] UI shows queued, active, completed, and failed jobs.
- [x] Report file is created.
- [x] Report metadata appears in the report list.
- [x] Queue state survives restart.

## Phase 8: Web Search

Deliverable: current search command behavior.

- [x] Implement web search context.
- [x] Port or replace current DuckDuckGo HTML search approach.
- [x] Add result parser.
- [x] Add result formatter.
- [x] Add timeout and error handling.
- [x] Integrate `/search` with chat.
- [ ] Inject search results into model context.
- [ ] Show searching state in UI.

Acceptance checks:

- [x] `/search <query>` returns formatted results when no model is selected.
- [ ] `/search <query>` can stream a model summary when a model is selected.
- [x] Search failures are visible and bounded.

## Phase 9: MCP Runtime

Deliverable: supervised MCP server parity.

- [x] Implement MCP server schema.
- [x] Implement MCP config UI.
- [ ] Implement MCP stdio process module.
- [ ] Launch configured commands as supervised ports.
- [x] Pass configured args.
- [x] Pass configured env.
- [ ] Perform initialize handshake.
- [ ] Send initialized notification.
- [ ] Discover tools.
- [ ] Store discovered tools in process state.
- [ ] Serialize JSON-RPC calls per MCP process.
- [x] Normalize MCP errors.
- [ ] Detect server exit.
- [x] Mark server unavailable on crash.
- [ ] Decide restart policy.
- [x] Broadcast MCP connected/error events.
- [x] Implement tool summary for chat prompt injection.
- [x] Implement `/mcp`.

Acceptance checks:

- [ ] Configured MCP server launches.
- [ ] Tools are discovered.
- [x] MCP failures are visible.
- [x] A crashed MCP process does not crash the app.

## Phase 10: Scheduler

Deliverable: scheduled pipeline parity.

- [x] Implement scheduler job schema.
- [x] Support ingest jobs.
- [x] Support analyze jobs.
- [x] Support full pipeline jobs.
- [x] Support digest placeholder or explicitly defer digest.
- [x] Support custom slash-command jobs.
- [ ] Parse cron expressions.
- [x] Persist enabled/disabled state.
- [x] Track last run.
- [ ] Track next run.
- [x] Track last error.
- [x] Support run-now.
- [x] Build scheduler/calendar panel UI.

Acceptance checks:

- [x] User can create a scheduled job.
- [x] User can update a scheduled job.
- [x] User can disable a scheduled job.
- [x] User can run a job immediately.
- [x] Job status survives restart where durable state is expected.

## Phase 11: Webhooks

Deliverable: local webhook parity.

- [x] Add local Phoenix routes under `/hooks/:name`.
- [x] Bind only to `127.0.0.1` by default.
- [x] Implement webhook schema.
- [x] Build webhook CRUD UI.
- [x] Support enabled/disabled.
- [x] Support `X-Buster-Claw-Secret`.
- [x] Support `Authorization: Bearer ...`.
- [x] Use constant-time secret comparison.
- [x] Limit request body size.
- [ ] Trigger configured action asynchronously.
- [x] Return `202 Accepted` after trigger.
- [x] Store webhook trigger audit events.

Acceptance checks:

- [ ] Local POST can trigger ingest.
- [ ] Local POST can trigger analyze.
- [ ] Local POST can trigger full pipeline.
- [ ] Local POST can trigger custom command.
- [x] Invalid secret is rejected.

## Phase 12: Hooks

Deliverable: reactive hook parity with better observability.

- [x] Implement hook schema.
- [x] Support hook events: pre-ingest, post-ingest, pre-analysis, post-analysis, pre-report, post-report, on-error.
- [x] Support shell hooks.
- [x] Support webhook hooks.
- [x] Support sync and async hooks.
- [ ] Execute shell hooks with JSON stdin.
- [ ] Add strict timeout.
- [x] Bound stdout capture.
- [x] Bound stderr capture.
- [x] Persist hook run results.
- [x] Show recent hook runs in UI.
- [ ] Trigger hooks from ingestion.
- [ ] Trigger hooks from analysis.
- [ ] Trigger hooks from report generation.
- [ ] Trigger hooks from errors.

Acceptance checks:

- [x] Hook configuration persists.
- [ ] Shell hook receives JSON payload.
- [x] Webhook hook posts JSON payload.
- [x] Failed hooks are visible in the UI.

## Phase 13: Delivery

Deliverable: report delivery parity.

- [x] Implement delivery destination schema.
- [x] Support Slack.
- [x] Support Discord.
- [x] Support Telegram.
- [x] Preserve email as placeholder or explicitly defer.
- [x] Implement delivery behavior.
- [x] Dispatch delivery as jobs.
- [x] Persist delivery attempts.
- [ ] Add timeout handling.
- [x] Add destination test action.
- [ ] Trigger delivery after report generation.
- [x] Build delivery settings UI.

Acceptance checks:

- [x] User can add delivery destination.
- [x] User can test delivery destination.
- [ ] Generated report dispatches to enabled destinations.
- [x] Failed delivery is recorded.

## Phase 14: Browser Automation Sidecar

Deliverable: browser-rendered ingestion parity.

- [ ] Create Node Playwright sidecar.
- [x] Define sidecar HTTP or stdio protocol.
- [ ] Supervise sidecar from Elixir.
- [x] Add sidecar health check.
- [x] Add request timeout.
- [ ] Add crash restart policy.
- [x] Support URL navigation.
- [ ] Support waiting for page body.
- [ ] Support cookie input.
- [x] Return rendered HTML.
- [x] Feed rendered HTML into readability/markdown pipeline.
- [x] Implement `/browse`.
- [ ] Implement browser source ingestion.

Acceptance checks:

- [x] Browser fetch returns rendered content.
- [x] Browser fetch failures are visible.
- [x] Sidecar crash does not take down the app.

## Phase 15: Memory

Deliverable: memory parity with structured records.

- [x] Implement memory schema.
- [x] Import current `Library/Memory.md`.
- [x] Add memory CRUD.
- [x] Build memory UI.
- [x] Format memory for prompt injection.
- [x] Support `/remember`.
- [x] Support `/forget`.
- [x] Support `/memories`.
- [ ] Optional: export structured memories back to markdown.

Acceptance checks:

- [x] Memory survives restart.
- [x] Memory appears in chat context.
- [x] Slash commands operate on the same structured memory records as the UI.

## Phase 16: Calendar

Deliverable: calendar event parity.

- [x] Implement calendar event schema.
- [x] Import current `Library/calendar.json`.
- [x] Add event CRUD.
- [x] Validate `YYYY-MM-DD` dates.
- [x] Build calendar LiveView.
- [ ] Show scheduled jobs on calendar/home surfaces.
- [x] Show user-authored events.

Acceptance checks:

- [x] User can add an event.
- [x] User can update an event.
- [x] User can delete an event.
- [x] Events survive restart.

## Phase 17: Migration From Current App

Deliverable: importer that preserves current user data.

- [x] Import `sources.json`.
- [x] Import `providers.json`.
- [ ] Import `mcp.json`.
- [ ] Import `Library/hooks.json`.
- [ ] Import `Library/webhooks.json`.
- [ ] Import `Library/delivery.json`.
- [ ] Import `Library/scheduler.json`.
- [x] Import `Library/calendar.json`.
- [x] Import `Library/Memory.md`.
- [x] Index `Library/raw/**/*.md`.
- [ ] Import `Library/reports/manifest.json`.
- [x] Index report markdown files.
- [x] Preserve original files until migration is verified.
- [ ] Write migration report.
- [x] Make importer idempotent.

Acceptance checks:

- [x] Import can run twice without duplicating records.
- [x] Existing raw documents appear in the new UI.
- [x] Existing reports appear in the new UI.
- [x] Existing settings appear in the new UI.

## Phase 18: Desktop Packaging

Deliverable: installable desktop app.

- [x] Choose desktop wrapper.
- [ ] Build Elixir release.
- [ ] Bundle Erlang runtime.
- [ ] Bundle Phoenix static assets.
- [ ] Bundle Node sidecar if browser automation is enabled.
- [ ] Start Phoenix on `127.0.0.1`.
- [ ] Use random or configurable local port.
- [ ] Open local webview.
- [ ] Stop runtime cleanly on app quit.
- [ ] Store logs in accessible local path.
- [ ] Store database and library in stable local path.
- [ ] Add macOS build path.
- [ ] Add Windows build path if needed.
- [ ] Add Linux build path if needed.

Acceptance checks:

- [ ] Packaged app starts without development tools.
- [ ] UI loads from local Phoenix runtime.
- [ ] App shutdown stops the BEAM runtime and sidecars.
- [ ] Data persists between packaged app launches.

## Phase 19: Verification Matrix

Deliverable: repeatable parity test suite.

- [x] Unit tests for contexts.
- [x] Integration tests for ingestion.
- [x] Integration tests for provider routing.
- [x] Integration tests for analysis job state.
- [x] Integration tests for report artifact creation.
- [x] Integration tests for scheduler run-now.
- [x] Integration tests for webhook trigger.
- [x] Integration tests for hook execution.
- [x] Integration tests for delivery attempts.
- [x] Integration tests for migration importer.
- [x] LiveView tests for major views.
- [ ] Manual desktop smoke test.

Manual parity smoke test:

- [ ] Start app.
- [ ] Configure provider.
- [ ] Add source.
- [ ] Ingest source.
- [ ] View raw document.
- [ ] Queue document.
- [ ] Run analysis.
- [ ] View report.
- [ ] Add memory.
- [ ] Chat with model.
- [ ] Run search command.
- [ ] Add calendar event.
- [ ] Add webhook.
- [ ] Trigger webhook.
- [ ] Add scheduled job.
- [ ] Run scheduled job now.
- [ ] Add delivery destination.
- [ ] Test delivery destination.
- [ ] Add hook.
- [ ] Trigger hook.
- [ ] Restart app.
- [ ] Confirm state survives.

## Phase 20: Cutover Decision

Deliverable: explicit decision that the rewrite is ready for packaged daily use.

- [ ] Current app data imports successfully.
- [ ] Core workflows are faster or at least comparable.
- [x] Failures are more visible than in the current app.
- [x] Queue state is durable.
- [x] Scheduler state is durable.
- [x] Hook and delivery attempts are auditable.
- [x] MCP crashes are isolated.
- [x] Browser sidecar crashes are isolated.
- [ ] Desktop packaging is usable.
- [x] Known deferred features are documented.
- [x] Legacy Wails app removed from the active repo; Phoenix/Tauri is the only app path.

## Risks To Track

- [ ] Desktop packaging complexity may exceed expectations.
- [ ] Browser automation in Elixir should remain a supervised sidecar unless native options prove reliable.
- [ ] Readability extraction quality may regress if libraries differ from the current Go implementation.
- [ ] SQLite job durability must be validated under app restarts and crashes.
- [ ] LiveView must handle long-running streaming interactions without UI state confusion.
- [ ] Secrets remain local plaintext unless a separate encryption/keychain milestone is added.
- [ ] Migration must not mutate existing user files during early testing.

## Recommended Build Order

- [x] Phase 0: Freeze parity scope.
- [x] Phase 1: Phoenix skeleton.
- [x] Phase 2: Data model.
- [x] Phase 3: Library and documents.
- [x] Phase 4: Ingestion.
- [x] Phase 5: Providers.
- [x] Phase 6: Chat.
- [x] Phase 7: Analysis queue and reports.
- [x] Phase 8: Web search.
- [x] Phase 10: Scheduler.
- [x] Phase 11: Webhooks.
- [x] Phase 12: Hooks.
- [x] Phase 13: Delivery.
- [x] Phase 15: Memory.
- [x] Phase 16: Calendar.
- [x] Phase 9: MCP runtime.
- [x] Phase 14: Browser automation sidecar.
- [x] Phase 17: Migration.
- [ ] Phase 18: Desktop packaging.
- [x] Phase 19: Verification matrix.
- [x] Phase 20: Cutover decision.

## Definition Of Done

The Elixir rewrite reaches parity when a user can:

- [ ] Start the desktop app.
- [x] Configure local and remote model providers.
- [x] Chat with streaming responses.
- [x] Save and use persistent memory.
- [x] Configure sources.
- [x] Ingest URL and RSS content.
- [x] Use browser-rendered ingestion.
- [x] Browse raw documents.
- [x] Queue documents for analysis.
- [x] Generate markdown reports.
- [x] Browse reports.
- [x] Configure and run scheduled jobs.
- [x] Configure and trigger local webhooks.
- [x] Configure and observe hooks.
- [x] Configure and test delivery destinations.
- [x] Dispatch reports to enabled destinations.
- [x] Configure and inspect MCP servers.
- [x] Use MCP summaries in chat context.
- [x] Manage calendar events.
- [x] Restart the app without losing operational state.
