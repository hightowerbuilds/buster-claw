# Buster Claw: Roadmap v2 — Agentic Capabilities

Six phases to bring Buster Claw from a local research tool to an autonomous agentic platform. Inspired by Hermes Agent's architecture, adapted for Buster Claw's Go + Wails + SolidJS stack.

---

## Phase 1: Browser Automation

**Goal:** Let ingestion handle JS-rendered pages, paywalled content, and authenticated sources via headless browser.

**Status:** Not Started

### 1.1 Headless Browser Backend
- New package `internal/browser/` wrapping Chrome DevTools Protocol (CDP).
- Launch headless Chrome/Chromium via `exec.Command`, connect over WebSocket.
- Core actions: `Navigate(url)`, `WaitForSelector(sel)`, `GetHTML()`, `Click(sel)`, `Type(sel, text)`, `Screenshot()`.
- Configurable timeout per page (default 30s).

### 1.2 Browser-Backed Ingestion
- Add `browser` source type to `internal/ingest/source.go`.
- When a source has `type: "browser"`, route through the browser backend instead of HTTP fetch.
- Extract readable content from the rendered DOM (after JS execution), then pipe through existing `parser.go` → markdown.
- Support `cookies` field on Source for authenticated sessions (JSON cookie array).

### 1.3 Interactive Browser Tool
- Expose as an MCP tool (`browser-fetch`) and a slash command (`/browse <url>`).
- Returns rendered page content as markdown, same as ingestion but ad-hoc from chat.
- Optional screenshot mode — capture PNG and save to `Library/screenshots/`.

### 1.4 Anti-Detection (Stretch)
- User-Agent rotation from a curated list.
- Randomized viewport dimensions.
- Optional proxy support via `BROWSER_PROXY` env var.

---

## Phase 2: Scheduled Pipelines

**Goal:** Fully autonomous research cycles — "every morning, ingest feeds, analyze, send digest."

**Status:** Not Started

### 2.1 Scheduler Engine
- New package `internal/scheduler/` with cron-based job execution.
- Parse cron expressions (standard 5-field) and natural language shortcuts (`"every 6h"`, `"daily at 7am"`).
- Jobs stored in `Library/scheduler.json` — persist across app restarts.
- Job lifecycle: create, pause, resume, delete, run-now.

### 2.2 Job Types
- **ingest** — Run the full ingestion pipeline (all sources or a named subset).
- **analyze** — Drain the analysis queue.
- **full** — Ingest then analyze (equivalent to `StartFullPipeline`).
- **digest** — Generate a summary report from the day's analysis and deliver it.
- **custom** — Run an arbitrary slash command string (e.g., `/search latest AI news`).

### 2.3 Frontend — Scheduler View
- New sidebar tab "Scheduler" listing all jobs with status, next run, last result.
- Add/edit/delete jobs with cron expression or natural language input.
- Manual "Run Now" button per job.
- History log showing last 10 runs per job with timestamps and outcomes.

### 2.4 Delivery Hooks
- Each job has an optional `deliver_to` field specifying output destination.
- Initially support: file (write to `Library/digests/`), webhook (POST JSON to a URL).
- Phase 5 expands this to Slack, Discord, email, etc.

---

## Phase 3: Subagent Parallelism

**Goal:** Analyze multiple documents simultaneously instead of one-at-a-time sequential processing.

**Status:** Not Started

### 3.1 Worker Pool
- Refactor `internal/orchestrator/orchestrator.go` to support configurable concurrency.
- New `WorkerCount` field in orchestrator config (default 1, max limited by available memory/model load).
- For local Ollama: keep at 1 (single model instance).
- For API providers: scale to 3-5 concurrent workers.

### 3.2 Provider-Aware Routing
- When the active provider is an API (OpenRouter, Anthropic, etc.), use it for parallel analysis.
- When only Ollama is available, fall back to sequential.
- `internal/provider/` already supports streaming — wire it into the analysis loop alongside the Ollama client.

### 3.3 Subagent Architecture
- New package `internal/agent/` defining a lightweight agent struct: isolated message history, assigned tools, model/provider config.
- `Spawn(task, tools, provider) → Agent` creates a child agent.
- Agent runs in its own goroutine, returns a result summary to the coordinator.
- Max depth: 2 (coordinator → workers, no deeper).
- Max concurrent: configurable, default 3.

### 3.4 Coordinator Pattern
- Orchestrator becomes the coordinator — distributes jobs to worker agents.
- Each worker: reads document, builds prompt, calls provider, extracts report.
- Coordinator collects results, writes reports, updates queue.
- Status updates emitted per-worker so the frontend shows parallel progress.

---

## Phase 4: Webhook Triggers

**Goal:** External events (GitHub push, Stripe payment, JIRA ticket) trigger Buster Claw pipelines automatically.

**Status:** Not Started

### 4.1 Webhook Server
- New package `internal/webhook/` — lightweight HTTP server running on a configurable port (default 9090).
- Endpoints registered per hook: `POST /hooks/{name}`.
- HMAC signature validation (optional per hook, using a shared secret).
- Rate limiting: 30 requests/min per route.

### 4.2 Hook Configuration
- Stored in `Library/webhooks.json`.
- Each hook: name, secret (optional), action (ingest URL, run pipeline, execute command), deliver_to.
- Template system for extracting fields from JSON payloads (dot-notation: `payload.repository.html_url`).

### 4.3 Built-in Hook Templates
- **github-push** — On push, ingest the repo README or changed files.
- **github-release** — On new release, ingest release notes.
- **generic** — Pass payload body as context to a chat prompt or slash command.

### 4.4 Frontend — Webhooks View
- New sidebar tab "Webhooks" listing configured hooks with URLs, status, last triggered.
- Add/edit/delete hooks.
- Copy webhook URL button.
- Activity log showing recent triggers with payload preview and outcome.

### 4.5 Security
- Webhooks only listen on localhost by default. Expose via reverse proxy (nginx, Cloudflare Tunnel) for external access.
- Optional IP allowlist per hook.
- Payload size limit: 1MB.

---

## Phase 5: Multi-Platform Delivery

**Goal:** Push research digests, reports, and alerts to Slack, Discord, Telegram, or email.

**Status:** Not Started

### 5.1 Delivery Interface
- New package `internal/delivery/` with a `Sender` interface: `Send(ctx, destination, message) error`.
- Each platform implements `Sender`.
- Messages carry: title, body (markdown), optional attachments (file paths).

### 5.2 Platform Adapters
- **Slack** — Webhook URL (no OAuth needed). Format markdown as Slack blocks.
- **Discord** — Webhook URL. Format as embeds.
- **Telegram** — Bot token + chat ID. Use Telegram Bot API.
- **Email** — SMTP config (host, port, user, pass, from). Send as HTML or plain text.
- **File** — Write to `Library/digests/{date}/` as markdown (default, already partially exists).

### 5.3 Delivery Configuration
- Stored in `Library/delivery.json`.
- Each destination: name, type, config (webhook URL / bot token / SMTP creds), default format.
- Multiple destinations per job — a single analysis run can notify Slack AND email.

### 5.4 Frontend — Delivery Settings
- New section in the existing Providers or a dedicated "Delivery" sidebar tab.
- Add/edit/delete destinations with type-specific config forms.
- Test button per destination (sends a "Buster Claw connected" message).
- Wire into Scheduler jobs and Webhook hooks via `deliver_to` field.

### 5.5 Report Formatting
- Convert analysis reports from markdown to platform-native format.
- Slack: blocks with sections, headers, and code blocks.
- Discord: embeds with title, description, fields, color.
- Telegram: HTML-formatted message with inline links.
- Email: HTML template wrapping the markdown-rendered content.

---

## Phase 6: Reactive Hooks

**Goal:** Pre/post processing hooks on pipeline events for custom automation.

**Status:** Not Started

### 6.1 Hook System
- New package `internal/hooks/` defining hook points throughout the pipeline.
- Hook points: `pre_ingest`, `post_ingest`, `pre_analysis`, `post_analysis`, `pre_report`, `post_report`, `on_error`.
- Each hook point can have multiple registered handlers.

### 6.2 Hook Types
- **Shell** — Execute a shell command. Receives event data as JSON on stdin, result on stdout.
- **Webhook** — POST event data to a URL.
- **Script** — Run a Go plugin or embedded Lua/JS script (stretch goal).

### 6.3 Hook Configuration
- Stored in `Library/hooks.json`.
- Each hook: name, event (hook point), type (shell/webhook), command/URL, enabled flag.
- Hooks execute synchronously by default. `async: true` for fire-and-forget.

### 6.4 Built-in Hook Patterns
- **post_ingest → tag enrichment** — After ingesting a document, run a classifier to auto-tag by topic.
- **post_analysis → delivery** — After generating a report, push to configured destinations.
- **on_error → alert** — On pipeline failure, notify via Slack/email.
- **pre_analysis → context injection** — Before analyzing, fetch additional context (e.g., git log, project README).

### 6.5 Frontend — Hooks View
- List configured hooks grouped by event.
- Enable/disable toggle per hook.
- Execution log showing recent hook runs with timing and output preview.

---

## Implementation Priority

| Phase | Dependencies | Effort | Impact |
|-------|-------------|--------|--------|
| 1. Browser Automation | None | Medium | High — unlocks JS/auth content |
| 2. Scheduled Pipelines | None | Medium | High — enables autonomy |
| 3. Subagent Parallelism | Provider system (done) | Medium | Medium — speeds up analysis |
| 4. Webhook Triggers | Scheduler (Phase 2) | Low | Medium — external integration |
| 5. Multi-Platform Delivery | None | Medium | High — makes output actionable |
| 6. Reactive Hooks | Phases 2, 4, 5 | Low | Medium — glues everything together |

**Recommended order:** 1 → 2 → 5 → 3 → 4 → 6

Browser automation and scheduled pipelines are independent and highest impact. Delivery (Phase 5) makes scheduling useful. Parallelism benefits from having the provider system wired into analysis. Webhooks and hooks tie everything together at the end.
