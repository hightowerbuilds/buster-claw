# 04-20-2026 Summary

## Today

- Onboarded a new AI agent (Claude) to the Buster Claw codebase.
- Performed a full codebase review and produced a working summary of architecture, completed phases, and next steps.
- Replaced the three old phase roadmaps with a single unified `roadmap.md` covering 4 phases: Ingestion Pipeline, Intentions-Driven Analysis, MCP Layer, and Orchestration Layer.
- **Phase 1 hardening complete:**
  - `internal/ingest/fetcher.go`: Added retry logic with exponential backoff (3 retries, 500ms base delay), 10MB body cap, better error messages with source URLs, proper error recording for cancelled jobs.
  - `internal/ingest/source.go`: Added `rss` source type, `Name` field on Source, and validation on load (URL format, known types).
  - `internal/ingest/rss.go`: New file — RSS/Atom feed parser using `gofeed`. Expands a feed into individual article Sources with inherited tags.
  - `internal/ingest/parser.go`: Added `sanitizeMarkdown()` post-processor — strips ad fragments, junk whitespace lines, duplicate headings, excessive newlines. RSS type routes through feed expansion instead of direct parsing.
  - `internal/library/manager.go`: Added cross-date deduplication (scans all `raw/` date dirs before writing), `Name` field in frontmatter.
  - `internal/tui/model.go`: `/start-ingest` now expands RSS sources into individual articles before concurrent fetch. Timeout bumped to 60s.
- All tests passing, clean build.
- **Phase 2 complete — Intentions-Driven Analysis & Reporting:**
  - `internal/intentions/parser.go`: Rewrote to parse `Intentions.md` into structured sections (Context, Goals, Output Format). Added `AnalysisPrompt()` for document analysis and `MCPGuidance()` for MCP data retrieval focus.
  - `internal/tui/model.go`: `/start-analysis` now extracts source metadata (URL, tags) from document frontmatter, injects it into the user prompt, uses structured `AnalysisPrompt()`, bumped timeout to 3min.
  - `internal/library/reports.go`: New file — `ReportManager` handles report directory creation, `BuildReportFrontmatter()` for report metadata (source file, URL, model, tags, generation date), `AppendManifest()` writes to `Library/reports/manifest.json`.
  - Reports now get full YAML frontmatter tracking lineage from source to report.
- **Phase 3 complete — MCP Layer:**
  - `internal/mcp/server.go`: New file — stdio-based MCP server implementing JSON-RPC 2.0. Handles `initialize`, `tools/list`, `tools/call`. Tool registration via `RegisterTool()`.
  - `internal/mcp/tools.go`: New file — three MCP tools: `fetch-url` (single URL fetch+save), `fetch-rss` (feed expansion+fetch+save), `check-updates` (full source check guided by Intentions).
  - `cmd/mcp-server/main.go`: Standalone MCP server binary entry point. Builds as `buster-claw-mcp`.
- **Phase 4 complete — Orchestration Layer:**
  - `internal/orchestrator/orchestrator.go`: New file — central coordinator. `RunIngest()` fetches all sources concurrently and queues results. `RunAnalysis()` processes the queue sequentially — one document at a time through Gemma4. `RunFull()` chains ingest→analyze. `DrainQueue()` picks up unprocessed files. Status exposed via `GetStatus()` with `OnStatusChange` callback.
  - `internal/tui/model.go`: Added `/start-full` (runs full pipeline via orchestrator), `/status` (shows orchestrator state: phase, queue depth, active job, completed/failed counts). Updated help bar.
- All 4 roadmap phases marked Done. Clean build, all tests pass.

## Notes

- `gofeed` library added as a dependency for RSS parsing.
- Deduplication is filename-based (SHA256 of URL) — same URL won't be saved twice across any date folder.
- Orchestrator enforces sequential model access — ingestion is concurrent, but Gemma4 processes one document at a time to prevent context contamination.
- MCP server can be run standalone (`buster-claw-mcp`) or integrated into other MCP clients.
- YouTube transcript parsing remains stubbed.
- **Migrated from TUI to Wails desktop app with SolidJS frontend:**
  - `main.go`: Rewrote for Wails — embeds `frontend/dist`, launches native webview window (1200x800).
  - `app.go`: Wails binding struct exposing all Go functionality to the frontend: `GetModels`, `SetModel`, `SendMessage` (streaming via events), `StartIngest`, `StartAnalysis`, `StartFullPipeline`, `GetOrchestratorStatus`, `GetSources`, `GetIntentions`, `GetReportManifest`, `GetPendingCount`.
  - `helpers.go`: Manifest reader helper.
  - `wails.json`: Wails build configuration.
  - `frontend/`: SolidJS + Vite + TypeScript.
    - Dark-themed UI with sidebar (pipeline controls, orchestrator status) and main chat area with streaming response display.
    - Model selector dropdown, pipeline buttons (Run Full, Ingest, Analyze), live status cards.
    - Wails runtime events for real-time streaming (`chat:token`, `chat:done`, `chat:error`, `orchestrator:status`).
  - Builds as native macOS `.app` bundle via `wails build`.
  - Generated `BusterClaw.dmg` installer on Desktop via `hdiutil`.

- **Frontend expanded to full 6-view UI:**
  - `frontend/src/App.tsx`: Rewrote from single chat view to tabbed layout with 6 views: Chat, Ingestion, Documents, Orchestration, Analysis, Models.
  - **Ingestion view**: Source list with add/delete, per-source ingest button, source type selector (rss, article, documentation, youtube_transcript), tag input.
  - **Documents view**: Browse all ingested files grouped by date, shows source URL and name from frontmatter.
  - **Orchestration view**: Live queue monitor with per-entry status (queued/analyzing/done/failed), pending files list with "queue for analysis" action.
  - **Analysis view**: Report browser with manifest list, click-to-read full report content rendered as markdown.
  - **Models view**: List available Ollama models, switch active model.
  - Added `marked` dependency for markdown rendering in reports.
  - `frontend/src/styles.css`: Major expansion — full styling for all 6 views, sidebar nav, status badges, cards, tables, buttons, form inputs.
- **New backend endpoints for the expanded UI:**
  - `app.go`: Added `IngestSource()` (single-source ingestion), `AddSource()` / `DeleteSource()` (source CRUD), `GetDocuments()` (browse raw library with frontmatter extraction), `GetPendingFiles()`, `QueueDocument()`, `GetAnalysisQueue()` (tracked queue with status), `GetReportContent()` (read + strip frontmatter).
  - `internal/ingest/source.go`: Added `SaveSources()` for writing sources back to disk.
  - `internal/orchestrator/orchestrator.go`: Added `IngestSingle()` for single-source ingestion, `QueueDocument()` / `GetAnalysisQueue()` / `ClearCompletedQueue()` for tracked queue with per-entry status, `setTrackedStatus()` wiring into analysis loop.
  - `internal/ingest/parser.go`: Added nil-check on `article.Node` to guard against readability returning empty content.
  - `internal/config/config.go`: Added default model fallback (`gemma4:e2b`) when `LOCALLLM_MODEL` is unset.
- **Wails bindings regenerated** (`frontend/wailsjs/`) to expose all new Go methods and types (`DocumentInfo`, `PendingFile`, `QueueEntry`).
- **Vite HMR config**: Added explicit `hmr` block in `vite.config.ts` for stable hot-reload during dev.
- **Wails dev config**: Added `debounceMS` and `watcher:ignore` in `wails.json` to avoid frontend rebuild loops.
- **Sources expanded**: Replaced placeholder CNN/Go docs with 11 real RSS feeds — Hacker News, Lobsters, Ars Technica, TLDR, Go Blog, Simon Willison, Julia Evans, Pragmatic Engineer, Hugging Face, Anthropic, Latent Space.
- **Deleted `daily-growth/road-maps/roadmap.md`** — all 4 phases are complete, roadmap no longer needed.

- **Web search in chat:**
  - `internal/websearch/search.go`: New package — queries DuckDuckGo HTML endpoint (no API key), parses results via goquery, returns titles/URLs/snippets. `DetectQuery()` scans for search trigger phrases anywhere in the message (not just prefix). `FormatResults()` formats for LLM context injection.
  - `internal/websearch/detect_test.go`: Tests for search intent detection across conversational phrasing.
  - `app.go`: `SendMessage` now detects search intent (natural language or `/search`), runs DuckDuckGo search, injects results as a system message, and streams the model's summary. Added `searchAndStream()` helper.
  - Frontend emits `chat:searching` event — shows "Searching the web for..." indicator while results load.
- **Slash commands in chat:**
  - `app.go`: Added `handleSlashCommand()` router and `emitSystemMessage()` helper. Commands:
    - `/search <query>` — web search with AI summary
    - `/ingest <url>` — ingest a URL into the library from chat
    - `/status` — show pipeline status inline
    - `/clear` — clear chat history (emits `chat:cleared` event)
    - `/help` — list available commands
  - Frontend listens for `chat:cleared` to reset UI state.
- **Document deletion:**
  - `app.go`: Added `DeleteDocument(path)` — removes raw file from `Library/raw/`, cleans up empty date dirs, path-validated to prevent arbitrary deletion. Reports and queue entries are preserved.
  - Frontend: Delete button on each document in the Documents view.
- **Docs view:**
  - Added 7th sidebar view ("Docs") with a quick-reference panel listing all slash commands and descriptions.
- **Minor cleanup:** Removed "Buster Claw v1.0" version label from status bar, removed "Refresh Models" from sidebar actions.
- **Fix `/ingest` command:** Was looking up URL in `sources.json` and failing for unknown URLs. Now fetches any arbitrary URL directly via `orchestrator.IngestSingle()` with an ad-hoc article source.
- **Added `gemma4:latest` model to local `models/` directory:**
  - Copied 8.9GB model weights blob from `Desktop/LocalLLM/models/` into `buster-claw/models/blobs/` (gitignored).
  - Created manifest at `models/manifests/registry.ollama.ai/library/gemma4/latest`.
  - Set `OLLAMA_MODELS` env var to point at `buster-claw/models/` so Ollama reads all three models (`gemma3:4b`, `gemma4:e2b`, `gemma4:latest`) from one location.
  - Still need to add `export OLLAMA_MODELS=...` to `.zshrc` for persistence across restarts.
- **Persistent memory system:**
  - `internal/memory/memory.go`: New package — `Store` backed by `Library/Memory.md`. Timestamped entries, load/save/add/remove. `SystemPrompt()` formats for LLM injection.
  - `app.go`: Memory loaded on startup, injected as system prompt in every chat message. New endpoints: `GetMemories()`, `AddMemory()`, `RemoveMemory()`.
  - Slash commands: `/remember`, `/forget`, `/memories`.
  - Frontend: Memory sidebar tab with add input, list of saved memories, Forget button per entry.
- **MCP client system:**
  - `internal/mcp/client.go`: Stdio-based JSON-RPC 2.0 client — connects to external MCP servers, handshake, tool discovery, tool calling.
  - `internal/mcp/manager.go`: Multi-server manager with namespaced tools (`server.tool`). Config from `mcp.json`. Auto-connects on startup, shuts down on exit.
  - MCP tool summaries injected into chat system prompt. `/mcp` command lists connected servers and tools.
- **Provider system for API-backed models:**
  - `internal/provider/provider.go`: Unified streaming interface for OpenRouter, OpenAI, Anthropic, and custom OpenAI-compatible endpoints. SSE parsing for both OpenAI and Anthropic formats. Config persisted to `providers.json`. `TestConnection()` for verification.
  - `app.go`: Full CRUD — `GetProviders()` (API keys masked), `AddProvider()`, `RemoveProvider()`, `SetActiveProvider()`, `TestProvider()`.
  - Frontend: Providers sidebar tab — list with activate/test/remove, add form with type dropdown, API key (password field), model, base URL.
- **TanStack Query integration:**
  - Replaced all manual fetch-on-switch with `createQuery` (models, sources, documents, pending, queue, reports, memories, providers).
  - Replaced manual refetch-after-mutation with `createMutation` + `invalidateQueries` (add/delete source, delete document, queue/remove document, add/remove memory, add/remove/activate provider).
  - `QueryClientProvider` wraps app in `index.tsx` with 30s stale time.
- **Unified dark input styling:** Global CSS for all `input`, `select`, `textarea` — consistent dark background, accent focus glow, custom select arrow. Removed duplicate per-component input styles.
- **Analysis queue management:** Added `RemoveFromQueue()` on orchestrator and frontend — Remove button on failed/queued entries.
- **Status bar activity indicator:** Footer shows Searching/Chatting/pipeline phase/Working/Idle in accent color.
- **Thinking animation:** Three bouncing dots in a Gemma bubble while waiting for first token.
- **Chat timeout:** Bumped from 3 to 10 minutes for slower hardware.
- **Roadmap v2:** Six-phase plan for agentic capabilities — Browser Automation, Scheduled Pipelines, Subagent Parallelism, Webhook Triggers, Multi-Platform Delivery, Reactive Hooks. Saved to `daily-growth/old-maps/roadmap-v2.md`.

## Notes

- Researched Hermes Agent (Nous Research) in depth — self-improving skills, 3-layer memory, 47 tools, subagent delegation, MCP client, 17+ messaging platforms, browser automation (Camofox), cron scheduling, webhooks, Home Assistant, voice. Cross-referenced against Buster Claw to identify the six capability gaps driving roadmap v2.
- OpenRouter identified as the best single API gateway for cloud model access — one key, 200+ models, OpenAI-compatible.

## Next

- Begin roadmap v2 implementation (recommended order: Browser Automation → Scheduled Pipelines → Multi-Platform Delivery → Subagent Parallelism → Webhook Triggers → Reactive Hooks).
- Add tests for new packages (memory, provider, websearch, mcp client).
- Wire provider system into analysis pipeline so API models can run analysis in parallel.
- Real-world testing with OpenRouter provider configured.
- Add `export OLLAMA_MODELS=...` to `.zshrc`.
