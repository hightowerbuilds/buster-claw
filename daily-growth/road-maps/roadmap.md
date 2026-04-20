# Buster Claw: Roadmap

## Phase 1: Ingestion Pipeline (Review & Harden)

**Status:** Done
**Goal:** Review the existing fetch-and-sanitize pipeline and make it production-grade.

### 1.1 Review Existing Pipeline
- Audit `internal/ingest/fetcher.go` — error handling, retries, timeouts.
- Audit `internal/ingest/parser.go` — readability extraction quality, edge cases (paywalls, JS-rendered pages, malformed HTML).
- Audit `internal/library/manager.go` — file naming, frontmatter consistency, deduplication.

### 1.2 RSS Feed Support
- Add an `rss` source type alongside the existing `article` and `documentation` types.
- Implement an RSS/Atom parser that discovers new entries from a feed URL.
- Each new entry becomes a fetch target, retrieved and sanitized like any other source.
- Track seen entries to avoid re-fetching on subsequent runs.

### 1.3 Improved Sanitization
- Strip ads, cookie banners, sidebar junk that readability may miss.
- Normalize heading levels, fix broken links, clean up artifacts.
- Ensure consistent markdown output across different source types.

### 1.4 Source Configuration Enhancements
- Support per-source options in `sources.json` (e.g., fetch interval, custom selectors, RSS vs HTTP).
- Validate sources on load and surface clear errors for bad config.

---

## Phase 2: Intentions-Driven Analysis & Reporting

**Status:** Done
**Goal:** Gemma4 reads ingested documents, analyzes them against `Intentions.md`, and produces structured reports saved to a dedicated section of the Library.

### 2.1 Intentions System
- Review and expand `Intentions.md` to serve as the central directive for both MCPs and the model.
- `Intentions.md` defines: what data to look for, what questions to answer, what output format to use.
- Parser feeds intentions into both the analysis prompt and (later) MCP guidance.

### 2.2 Analysis Pipeline
- Review existing `/start-analysis` implementation.
- Gemma4 receives: system prompt (Intentions) + document content → produces a structured report.
- Improve prompt engineering for consistent, high-quality report output.
- Handle multi-document analysis (cross-referencing across ingested files).

### 2.3 Report Library
- Dedicated `Library/reports/<date>/` directory for model-generated reports.
- Reports include frontmatter: source documents used, intentions applied, generation date.
- Index or manifest file to track all generated reports.

---

## Phase 3: MCP Layer (Autonomous Data Retrieval)

**Status:** Done
**Goal:** Build MCP server(s) that autonomously monitor websites, retrieve updated data, and feed it into the ingestion pipeline — guided by `Intentions.md`.

### 3.1 MCP Architecture
- Design MCP server(s) that expose tools for: fetching a URL, fetching an RSS feed, checking for updates.
- MCPs are guided by `Intentions.md` — they know what to look for and what matters.
- MCPs feed new data into the existing Library pipeline.

### 3.2 HTTP Monitor MCP
- Periodically check configured URLs for changes.
- Detect new or updated content and trigger ingestion.
- Respect rate limits and site-specific fetch intervals from `sources.json`.

### 3.3 RSS Monitor MCP
- Subscribe to RSS/Atom feeds from `sources.json`.
- Detect new entries and trigger fetch + sanitize + save for each.
- Track feed state to avoid duplicate processing.

### 3.4 Persistence & Logging
- All MCP activity logged and saved.
- Track what was fetched, when, and what intentions guided the retrieval.
- Surface MCP status in the TUI.

---

## Phase 4: Orchestration Layer

**Status:** Done
**Goal:** A Go-native concurrency layer that coordinates all moving parts — ingestion, MCPs, and model analysis — so Gemma4 focuses on one project at a time in a controlled sequence.

### 4.1 Job Queue & Scheduler
- Central job queue that receives work from MCPs and manual commands.
- Each job represents one unit of work: a single source to ingest, or a single document to analyze.
- Jobs are prioritized and deduplicated before being dispatched.

### 4.2 Sequential Analysis Gate
- While ingestion and MCP fetching run concurrently (Go's strength), the model gets fed one analysis at a time.
- A gated channel ensures Gemma4 finishes its current report before receiving the next document.
- Prevents context contamination — the model works on one project, produces its report, then moves on.

### 4.3 Pipeline Coordination
- Orchestrator manages the full lifecycle: source check → fetch → sanitize → queue → analyze → report → done.
- Tracks state across the pipeline so nothing gets lost between stages.
- If a fetch completes while the model is busy, the result waits in the queue — no data is dropped.

### 4.4 Status & Observability
- Orchestrator exposes its state to the TUI: what's fetching, what's queued, what the model is currently analyzing.
- Enables future dashboard views (live queue depth, active job, completed reports).
- Structured logging of orchestrator decisions (why a job was scheduled, reordered, or skipped).
