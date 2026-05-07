# Elixir Rewrite Review

## Context

This note reviews Buster Claw through the eyes of someone who believes Elixir is the right long-term architecture for agentic desktop software. The purpose is not to claim that the current Go/Wails implementation is wrong. The purpose is to ask what the app wants to become if its most important problems are orchestration, supervision, streaming state, background jobs, process isolation, and fault containment.

Buster Claw is already shaped like a distributed local system. It ingests external sources, talks to Ollama and remote LLM providers, streams chat responses, runs background analysis, manages a queue, serves local webhooks, executes hooks, launches MCP subprocesses, sends delivery notifications, persists local memory, renders generated reports, and exposes a desktop UI. Those are not primarily CPU-bound problems. They are coordination problems. They are about many independent activities happening at once, failing independently, recovering independently, and reporting state to the user in real time.

That is exactly the territory where Elixir and OTP are strongest.

## Current Architecture In Go Terms

The current app is a Wails desktop application. `main.go` starts Wails, embeds `frontend/dist`, creates `App`, and binds that object to the frontend. `app.go` is the dominant facade. It owns the Ollama client, selected model, orchestrator, memory store, MCP manager, provider manager, scheduler, webhook server, delivery manager, hooks manager, calendar manager, chat messages, and mutex-protected shared state.

The frontend is SolidJS. It uses Wails-generated bindings and runtime events. `useAppController.ts` coordinates almost all frontend interaction: queries, mutations, active view state, chat events, queue invalidation, provider forms, webhook forms, memory forms, and document/report selection. It is a practical architecture, but it is still built around imperative frontend calls into a single backend binding object.

The backend package split is sensible: `internal/ingest`, `internal/orchestrator`, `internal/provider`, `internal/ollama`, `internal/mcp`, `internal/webhook`, `internal/hooks`, `internal/scheduler`, `internal/delivery`, `internal/calendar`, `internal/memory`, and `internal/websearch`. The code is trying to become modular. The problem is that the runtime model remains mostly manual. Long-running tasks are goroutines. Coordination state is protected with mutexes. Status updates are callbacks. Persistence is a collection of JSON and markdown files. Failure policy is encoded ad hoc inside each manager.

That is where an Elixir rewrite changes the shape of the system.

## The Elixir Thesis

The Elixir argument is not that Elixir syntax is nicer than Go syntax. The argument is that Buster Claw's runtime concerns are native OTP concerns.

The app needs supervised workers. It needs durable jobs. It needs process registries. It needs event pub/sub. It needs streaming updates. It needs external process supervision. It needs clear failure boundaries. It needs long-running local services. It needs to coordinate queues, webhooks, MCP servers, provider calls, browser automation, delivery attempts, and user-facing state.

In Go, all of this can be built, and much of it already is. But each capability has to be assembled manually. In Elixir, the runtime expects this style of application. A document analysis job can be a process. A chat session can be a process. An MCP server connection can be a process. A scheduler can enqueue durable jobs. A LiveView can subscribe to PubSub topics. A crashed worker can be restarted or marked failed by a supervisor. This gives the architecture more explicit boundaries.

The app would stop being "a desktop app with background goroutines" and become "a supervised local research runtime with a desktop control panel."

## Desktop Strategy

The biggest practical question is desktop packaging. Go has Wails. Elixir does not have an exact equivalent with the same maturity and mainstream adoption. An Elixir desktop rewrite would likely choose one of two paths.

The most Elixir-native path is Phoenix LiveView wrapped in a desktop shell. The Elixir app starts a Phoenix endpoint bound to `127.0.0.1`, and a desktop wrapper opens a local webview pointed at that endpoint. The wrapper could be Tauri, Electron, or another platform webview launcher. The UI is then a LiveView application, not a separate Solid app.

The second path is an Elixir backend with the existing Solid frontend moved to Tauri or another shell. In that model, Solid calls a local Elixir HTTP/WebSocket API instead of Wails bindings. This keeps more frontend investment, but it also preserves the split-brain state model: frontend queries and invalidates data while the backend runs jobs and emits events.

If the goal is to pursue the Elixir idea seriously, Phoenix LiveView is the more coherent choice. Buster Claw's UI is state-heavy and event-driven: chat streaming, queue status, job status, source lists, report lists, document previews, scheduler state, provider tests, webhook toggles, calendar events, and delivery settings. LiveView handles this kind of app well. It removes the need for generated Wails bindings, manual runtime event listeners, and much of the frontend cache invalidation logic.

The tradeoff is packaging. Shipping an Erlang VM plus Phoenix is heavier than shipping a Go binary. Startup can be heavier. Native OS integration needs deliberate design. But the product fit is strong if the app is intended to be a durable local automation environment rather than a lightweight utility.

## Proposed OTP Shape

The Elixir version should be organized as a supervised application. A conceptual supervision tree might look like this:

```elixir
BusterClaw.Application
BusterClaw.Repo
BusterClaw.PubSub
BusterClaw.Chat.SessionRegistry
BusterClaw.Orchestrator
BusterClaw.Ingest.Supervisor
BusterClaw.Analysis.Supervisor
BusterClaw.ProviderRegistry
BusterClaw.MCP.Supervisor
BusterClaw.Scheduler
BusterClaw.WebhookEndpoint
BusterClaw.Delivery.Supervisor
BusterClaw.Memory.Server
BusterClaw.Calendar.Server
```

`BusterClaw.Application` would start the core runtime. `BusterClaw.PubSub` would broadcast status changes and streaming events. `BusterClaw.Repo` would manage SQLite persistence through Ecto. The orchestrator would no longer own arbitrary slices guarded by mutexes. It would coordinate job creation, status updates, and event publication.

Chat sessions could be represented by GenServers. Each session would hold history, active model/provider, memory context, MCP tool summaries, stream state, and cancellation state. When a user sends a message, the session starts a supervised streaming task. Tokens are published to the LiveView topic. If the provider request crashes, the session reports an error without taking down the app.

Ingestion could use `Task.Supervisor.async_stream` at first. If the pipeline grows, Broadway becomes attractive. RSS expansion, HTTP fetching, browser fetching, markdown extraction, and document persistence are separate stages. Each stage can fail independently and produce structured errors.

Analysis should become a supervised job system. Oban with SQLite or Postgres would be a natural choice if durability matters. Each raw document analysis is a job with a retry policy, timeout, status, model/provider metadata, and output report. The current queue limit and worker count become queue concurrency settings rather than manual slice accounting.

MCP servers are an especially good OTP fit. Each configured MCP server can be supervised as a Port-backed process. The process owns stdin/stdout, performs initialization, discovers tools, serializes tool calls, and restarts or marks itself unavailable on crash. The current Go MCP client uses a mutex around JSON-RPC request/response flow. In Elixir, a GenServer owning the port is a direct expression of that protocol.

## Persistence Model

The current app persists many local files: `sources.json`, `providers.json`, `mcp.json`, `hooks.json`, `delivery.json`, `webhooks.json`, `scheduler.json`, `calendar.json`, `Library/queue.json`, `Library/Memory.md`, `Library/raw`, and `Library/reports`.

That file-first model is useful during early development, but it becomes awkward as coordination grows. An Elixir rewrite should probably use SQLite through Ecto for structured app state, while keeping markdown artifacts on disk.

SQLite should own sources, providers, active provider selection, MCP server definitions, hooks, webhook definitions, delivery destinations, scheduler jobs, calendar events, memories, document metadata, report metadata, job runs, queue state, errors, and audit logs. The filesystem should own large raw markdown documents and generated report markdown. This preserves local-first ownership while making state transitions transactional and queryable.

This matters because Buster Claw is not only storing settings. It is storing workflow state. A document can be fetched, queued, analyzing, failed, retried, completed, delivered, or deleted. Reports can have delivery attempts. Hooks can have execution logs. Scheduler jobs have last-run and next-run state. These are relational concepts. SQLite is a better foundation than many disconnected JSON files.

The current checkout also has a concrete compile issue: several packages import `internal/library`, but that package is absent. In an Elixir rewrite, `BusterClaw.Library` should be a first-class context. It should own raw document paths, report paths, frontmatter, deduplication, metadata, and artifact lifecycle.

## Subsystem Mapping

Ollama and remote providers would become provider behaviours. `BusterClaw.Provider` would define a streaming callback contract, and modules like `Provider.Ollama`, `Provider.OpenAI`, `Provider.OpenRouter`, `Provider.Anthropic`, and `Provider.Custom` would implement it. HTTP streaming can be implemented with Req, Finch, Mint, or another streaming-capable client.

Web search would become a small context using an HTTP client plus HTML parsing. The current DuckDuckGo HTML approach can be ported, though it remains brittle because scraping search result markup is always brittle.

Scheduler work would move to Quantum or Oban. If jobs must survive app restarts, Oban is the better fit. It gives visibility, retries, uniqueness constraints, and durable state. If the app only needs cron-style local triggers, Quantum is simpler.

Webhooks would be Phoenix routes. A local endpoint like `/hooks/:name` would validate `X-Buster-Claw-Secret` or `Authorization: Bearer ...`, limit request body size, enqueue the configured action, and return `202 Accepted`. The security posture should remain local-only by default.

Hooks should be treated carefully. Shell hooks are powerful and dangerous. In Elixir, a dedicated `HookRunner` should execute shell commands through ports or `System.cmd`, with strict timeout, bounded stdout/stderr, JSON stdin, audit logs, and no silent background failures. Webhook hooks are simpler HTTP jobs.

Delivery should become jobs, not fire-and-forget tasks. Slack, Discord, Telegram, and future email delivery can each be modules behind a delivery behaviour. Report generation should enqueue delivery attempts. Delivery failures should be visible and retryable.

Calendar and memory are straightforward LiveView/Ecto contexts. Memories can still be exported to markdown, but the source of truth should probably be structured records so the app can search, filter, edit, and inject them into prompts reliably.

## Hard Parts

Browser automation is one of the hardest parts. Go has `chromedp`, which gives direct Chrome DevTools control. Elixir has options, but the ecosystem is not as direct. A rewrite should probably use a supervised Node Playwright sidecar or a browser automation service controlled by ports or HTTP. Elixir is excellent at supervising that sidecar. It may not be the best language for implementing the browser protocol itself.

Readability extraction and HTML-to-Markdown are another risk. The Go code uses mature libraries for readability extraction and markdown conversion. Elixir alternatives exist, but quality must be tested. If extraction quality regresses, the whole research pipeline suffers. A pragmatic Elixir rewrite might keep extraction in a helper executable or NIF-free sidecar until the Elixir implementation is proven.

Desktop packaging is the final hard part. Wails gives the current app a direct desktop story. Phoenix plus Tauri or Electron is feasible, but packaging an Elixir release inside a desktop app requires more custom work. That work may be justified if the runtime architecture is the long-term priority.

## Verdict

Through Elixir eyes, Buster Claw is an OTP app waiting to happen. Its hard problems are supervision, queues, streaming, local process management, retries, scheduled work, external integrations, and realtime user-visible state. Elixir would make those concerns explicit instead of incidental.

The rewrite would be substantial. It would mean replacing Wails with a Phoenix-based local runtime, likely LiveView for the UI, SQLite/Ecto for structured state, OTP supervisors for long-running services, and durable jobs for ingestion, analysis, delivery, and scheduled automation. It would also require careful planning around browser automation, readability extraction, and desktop packaging.

The payoff is architectural coherence. Buster Claw wants to be a local autonomous research system, not just a desktop CRUD app. Elixir is a strong fit for that future because it treats concurrent, failure-prone, event-driven systems as the default case rather than an edge case.
