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

## Next

- Add tests for the new packages (mcp, orchestrator, intentions).
- Real-world testing: launch the desktop app, run full pipeline against live sources, verify report quality.
- Expand `Intentions.md` with more specific research goals.
- Add more source URLs and RSS feeds to `sources.json`.
- Polish the frontend: report viewer, source editor, memory management panel.
