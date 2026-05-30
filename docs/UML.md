# Buster Claw — UML / Architecture Diagrams

Mermaid diagrams describing both the **structure** (modules, schemas, supervision) and the
**functionality** (request flows and pipelines) of the codebase. Rendered automatically by
GitHub and most Markdown viewers.

> Source of truth: generated from `lib/` on 2026-05-28. Re-derive after large refactors.

---

## 1. System layers (functional overview)

How the four frontends, the unified command surface, the domain contexts, and the
external world fit together.

```mermaid
flowchart TB
    subgraph Frontends["Frontends / Entry points"]
        CLI["CLI escript<br/>(cli.ex)"]
        WebUI["LiveView UI<br/>(15 LiveViews)"]
        HTTP["HTTP API<br/>(api_controller)"]
        MCP["MCP server<br/>(mcp_controller)"]
        AgentLoop["Internal agent loop<br/>(agent_mode / agent_tools)"]
        Webhooks_in["Inbound webhooks<br/>(webhook / integration_webhook)"]
    end

    subgraph Surface["Unified Command Surface"]
        Commands["Commands.call/2<br/>(76 commands, tier-gated)"]
        Schema["Commands.Schema"]
        Result["Commands.Result"]
    end

    subgraph Contexts["Domain Contexts"]
        Sources & Library & Ingest & Analysis & Workflow
        Chat & Providers & Memory & Calendar
        Automation & Integrations & Google & Scheduler & Webhooks & Hooks & Delivery
    end

    subgraph Infra["Infrastructure"]
        Repo["Repo (SQLite/Ecto)"]
        PubSub["Phoenix.PubSub"]
        Vault["Google.Vault (AES-256-GCM)"]
    end

    subgraph External["External services"]
        LLM["LLM providers<br/>(Anthropic/OpenAI/Gemini/Ollama/Codex)"]
        GoogleAPI["Google Workspace<br/>(Gmail / Calendar)"]
        Browser["Browser sidecar<br/>(Playwright)"]
        Integr["GitHub / Sentry / Umami"]
        DeliverOut["Slack / Discord / Telegram / Email"]
    end

    CLI -->|HTTP /api/run| HTTP
    WebUI --> Contexts
    HTTP --> Commands
    MCP -->|safe-tier only| Commands
    AgentLoop -->|safe-tier only| Commands
    Webhooks_in --> Webhooks & Integrations

    Commands --> Schema
    Commands --> Result
    Commands --> Contexts

    Contexts --> Repo
    Contexts --> PubSub
    Google --> Vault
    Providers --> LLM
    Google --> GoogleAPI
    Ingest --> Browser
    Integrations --> Integr
    Delivery --> DeliverOut

    PubSub -.live updates.-> WebUI
```

---

## 2. Supervision tree (runtime processes)

From `lib/buster_claw/application.ex`. `one_for_one` strategy; `*` entries are env-gated.

```mermaid
flowchart TD
    Sup["BusterClaw.Supervisor<br/>(one_for_one)"]

    Sup --> Telemetry["BusterClawWeb.Telemetry"]
    Sup --> Repo["BusterClaw.Repo"]
    Sup --> Migrator["Ecto.Migrator"]
    Sup --> DNS["DNSCluster"]
    Sup --> PubSub["Phoenix.PubSub"]
    Sup --> AgentMode["AgentMode (Agent)"]
    Sup --> Sidecar["Browser.Sidecar *<br/>(browser_sidecar_enabled)"]
    Sup --> McpReg["Registry: MCP.Registry"]
    Sup --> McpSup["MCP.Supervisor<br/>(DynamicSupervisor)"]
    Sup --> McpBoot["MCP.Bootstrap"]
    Sup --> Sched["Scheduler.Runner *<br/>(scheduler_enabled)"]
    Sup --> ChatReg["Registry: Chat.Registry"]
    Sup --> ChatSup["Chat.SessionSupervisor<br/>(DynamicSupervisor)"]
    Sup --> Endpoint["BusterClawWeb.Endpoint"]

    McpSup -.spawns.-> McpClient["MCP.Client<br/>(one per server)"]
    ChatSup -.spawns.-> ChatSession["Chat.Session<br/>(one per chat)"]
```

---

## 3. Domain model (Ecto schemas & relationships)

All persisted schemas and their associations. Standalone schemas (no FKs) are grouped at
the bottom.

```mermaid
classDiagram
    class Source {
        +string url
        +string type
        +string name
        +map tags
        +string browser_engine
        +bool enabled
    }
    class Document {
        +string filename
        +string artifact_path
        +date date
        +string source_url
        +string content_hash
        +string status
        +string excerpt
    }
    class Report {
        +string filename
        +string artifact_path
        +string model
        +map tags
        +utc generated_at
    }
    class Provider {
        +string name
        +string type
        +string base_url
        +string api_key
        +string model
        +bool active
        +int priority
    }
    class AnalysisJob {
        +string status
        +int progress
        +string model
        +string error
    }
    class DeliveryAttempt {
        +string title
        +string status
        +string error
    }
    class DeliveryDestination {
        +string name
        +string type
        +string url
        +string token
        +bool enabled
    }
    class Integration {
        +string name
        +string service_type
        +string base_url
        +string token
        +string webhook_secret
        +int polling_interval_minutes
        +string last_status
    }
    class IntegrationRun {
        +string trigger
        +string status
        +int records_fetched
    }
    class Hook {
        +string name
        +string event
        +string type
        +string target
        +bool async
    }
    class HookRun {
        +string event
        +int duration_ms
        +bool success
        +string stdout
        +string stderr
    }

    Source "1" --> "*" Document : has
    Document "1" --> "*" Report : produces
    Document "1" --> "*" AnalysisJob : queued for
    Document "1" --> "*" IntegrationRun : created by
    Provider "1" --> "*" Report : generated by
    Provider "1" --> "*" AnalysisJob : runs on
    Report "1" --> "*" AnalysisJob : output of
    Report "1" --> "*" DeliveryAttempt : delivered via
    DeliveryDestination "1" --> "*" DeliveryAttempt : target of
    Integration "1" --> "*" IntegrationRun : has
    Hook "1" --> "*" HookRun : has
```

### Standalone schemas (no foreign keys)

```mermaid
classDiagram
    class GoogleAccount {
        +string email
        +binary client_secret_enc
        +binary refresh_token_enc
        +binary access_token_enc
        +string scopes
        +map calendar_sync_tokens
    }
    class CalendarEvent {
        +string event_id
        +date date
        +time start_time
        +time end_time
        +string title
        +string frequency
        +date recur_until
    }
    class Memory {
        +utc created_at
        +string text
    }
    class McpServer {
        +string name
        +string command
        +map args
        +map env
        +string last_status
    }
    class Webhook {
        +string name
        +string secret
        +string action
        +string custom_cmd
    }
    class SchedulerJob {
        +string job_id
        +string type
        +string cron
        +string custom_cmd
        +utc next_run_at
    }
    class RuntimeEvent {
        +string kind
        +string message
        +map metadata
    }
```

---

## 4. Command surface dispatch (shared by all frontends)

The single most important design property: **one** dispatcher, four callers. Restricted-tier
commands are filtered out for the model-facing frontends (MCP, agent loop).

```mermaid
classDiagram
    class Commands {
        +call(name, args)
        +commands_catalog()
        -safe_get(...)
    }
    class CommandsSchema {
        +validate(name, args)
    }
    class CommandsResult {
        +to_json(struct)
    }
    class ApiController {
        +run(conn, params)
        +commands(conn, _)
    }
    class McpController {
        +handle(conn, params)
    }
    class AgentTools {
        +tool_definitions()
        +execute(name, args)
    }
    class AgentMode {
        +enabled?()
    }
    class CLI {
        +main(argv)
    }

    ApiController ..> Commands : POST /api/run
    McpController ..> Commands : tools/call (safe tier)
    AgentTools ..> Commands : LLM tool calls (safe tier)
    AgentMode ..> Commands
    CLI ..> ApiController : HTTP /api/run
    Commands ..> CommandsSchema : validates args
    Commands ..> CommandsResult : serializes output
```

---

## 5. LLM provider abstraction

`Backend` behaviour with per-provider implementations, dispatched by `module_for/1`. Only
Anthropic implements the agentic tool loop today (others fall back to plain chat).

```mermaid
classDiagram
    class Backend {
        <<behaviour>>
        +chat(config, messages, on_chunk) ok
        +test_connection(config) result
    }
    class Providers {
        +chat(provider, messages, on_chunk)
        +agentic_chat(provider, messages, on_chunk)
        -module_for(provider)
    }
    class Anthropic {
        +chat(...)
        +chat_agentic(...) max 6 iters
        +test_connection(...)
    }
    class OpenAICompatible
    class Gemini
    class Ollama
    class Codex
    class ProviderHTTP {
        +request(...)
    }

    Backend <|.. Anthropic
    Backend <|.. OpenAICompatible
    Backend <|.. Gemini
    Backend <|.. Ollama
    Backend <|.. Codex
    Providers ..> Backend : dispatches via module_for
    Anthropic ..> ProviderHTTP
    OpenAICompatible ..> ProviderHTTP
    Gemini ..> ProviderHTTP
    Codex ..> ProviderHTTP
    Ollama ..> ProviderHTTP
```

---

## 6. Knowledge pipeline (ingest → analyze → deliver)

The core functional loop, including the queue-based async analysis and PubSub-driven
live updates.

```mermaid
sequenceDiagram
    actor User
    participant UI as LiveView / CLI / Scheduler
    participant Ingest
    participant Fetcher as Ingest.Fetcher / Browser
    participant Library
    participant Analysis as Analysis (queue)
    participant Provider as Providers + LLM
    participant Delivery
    participant Dest as Slack/Discord/Telegram/Email
    participant PubSub

    User->>UI: ingest <url>
    UI->>Ingest: source_ingest
    Ingest->>Fetcher: fetch(url)
    Fetcher-->>Ingest: html/markdown
    Ingest->>Library: store Document (status: fetched)
    Library-->>PubSub: broadcast document

    UI->>Analysis: analysis_queue(document_id)
    Analysis->>Analysis: create AnalysisJob (queued)
    Analysis->>Provider: chat(prompt + document)
    Provider->>Provider: call LLM, accumulate chunks
    Provider-->>Analysis: report markdown
    Analysis->>Library: store Report (document_id, provider_id)
    Analysis->>Analysis: Document.status = analyzed
    Analysis-->>PubSub: broadcast report

    UI->>Delivery: delivery_dispatch(report)
    Delivery->>Dest: POST report
    Delivery->>Delivery: record DeliveryAttempt
    PubSub-->>UI: live refresh
```

---

## 7. Agentic chat loop (Anthropic tool-calling)

How a chat turn becomes tool calls against the command surface, with the safe-tier gate
and the 6-iteration cap.

```mermaid
sequenceDiagram
    participant UI as ChatLive
    participant Session as Chat.Session
    participant Providers
    participant Anthropic
    participant LLM as Anthropic API
    participant Tools as AgentTools
    participant Commands

    UI->>Session: user message
    Session->>Providers: agentic_chat(provider, msgs)
    Providers->>Anthropic: chat_agentic (type == anthropic)
    loop up to 6 iterations
        Anthropic->>LLM: messages + safe-tier tool defs
        LLM-->>Anthropic: text or tool_use
        alt tool_use requested
            Anthropic->>Tools: execute(name, args)
            Tools->>Commands: call (reject if restricted)
            Commands-->>Tools: result JSON
            Tools-->>Anthropic: tool_result
        else final text
            Anthropic-->>Providers: assistant reply
        end
    end
    Providers-->>Session: reply (or {:error, :max_tool_iterations})
    Session-->>UI: broadcast :token / :done
```

---

## 8. HTTP routing & auth tiers

From `lib/buster_claw_web/router.ex`.

```mermaid
flowchart LR
    subgraph browser["pipe :browser (session, CSRF, LiveView)"]
        R1["/ , /chat, /sources, /documents, /analysis,<br/>/calendar, /gws, /memory, /integrations,<br/>/mcp, /scheduler, /webhooks, /hooks, /delivery"]
        R2["/google/oauth/callback"]
    end
    subgraph api["pipe :api (unauthenticated)"]
        H1["GET /_health"]
        H2["POST /integrations/:name/webhook<br/>(HMAC verified)"]
        H3["POST /hooks/:name<br/>(secret verified)"]
        H4["GET /api/commands (catalog metadata)"]
    end
    subgraph auth["pipe :api_authenticated (Bearer token)"]
        A1["POST /api/run"]
        A2["POST /mcp"]
    end
```
