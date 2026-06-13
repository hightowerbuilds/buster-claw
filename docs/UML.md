# Buster Claw — UML / Architecture Diagrams

Mermaid diagrams describing both the **structure** (modules, schemas, supervision) and the
**functionality** (request flows) of the codebase. Rendered automatically by GitHub and most
Markdown viewers.

> Source of truth: generated from `lib/` on 2026-06-05 (post terminal-driven-CLAW cut).
> Re-derive after large refactors.

---

## 1. System layers (functional overview)

How the three frontends, the unified command surface, the domain contexts, and the
external world fit together. Buster Claw has no built-in LLM — the intelligence is a
terminal agent (Claude Code / Codex) driving the command surface over MCP.

```mermaid
flowchart TB
    subgraph Frontends["Frontends / Entry points"]
        CLI["CLI escript<br/>(cli.ex)"]
        WebUI["LiveView UI<br/>(~20 LiveViews)"]
        HTTP["HTTP API<br/>(api_controller)"]
        MCP["MCP server<br/>(mcp_controller)"]
        Webhooks_in["Inbound webhooks<br/>(webhook / integration_webhook)"]
    end

    subgraph Surface["Unified Command Surface"]
        Commands["Commands.call/2<br/>(~70 commands, tier-gated)"]
        Schema["Commands.Schema"]
        Result["Commands.Result"]
    end

    subgraph Contexts["Domain Contexts"]
        Library & Browser & Search & Memory & Calendar
        Google & Integrations & Delivery
        Automation & Orchestration & Sentinel & Settings
    end

    subgraph Infra["Infrastructure"]
        Repo["Repo (SQLite/Ecto)"]
        PubSub["Phoenix.PubSub"]
        Vault["Vault / Google.Vault<br/>(AES-256-GCM)"]
    end

    subgraph External["External services"]
        Agents["Headless agents<br/>(claude -p / codex exec)"]
        GoogleAPI["Google Workspace<br/>(Gmail / Calendar)"]
        BrowserBin["Browser sidecar<br/>(Playwright)"]
        Integr["GitHub / Sentry / Umami"]
        DeliverOut["Slack / Discord / Telegram"]
    end

    CLI -->|HTTP /api/run| HTTP
    WebUI --> Contexts
    HTTP --> Commands
    MCP -->|safe-tier only| Commands
    Webhooks_in --> Automation & Integrations

    Commands --> Schema
    Commands --> Result
    Commands --> Contexts
    Commands -.audited by.-> Sentinel

    Contexts --> Repo
    Contexts --> PubSub
    Google --> Vault
    Google --> GoogleAPI
    Browser --> BrowserBin
    Integrations --> Integr
    Delivery --> DeliverOut
    Orchestration --> Agents

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
    Sup --> SentinelPending["Sentinel.Pending"]
    Sup --> Sidecar["Browser.Sidecar *<br/>(browser_sidecar_enabled)"]
    Sup --> McpReg["Registry: MCP.Registry"]
    Sup --> McpSup["MCP.Supervisor<br/>(DynamicSupervisor)"]
    Sup --> McpBoot["MCP.Bootstrap"]
    Sup --> Sched["Scheduler.Runner *<br/>(scheduler_enabled)"]
    Sup --> RunnerSup["Orchestration.RunnerSupervisor<br/>(Task.Supervisor)"]
    Sup --> Orchestrator["Orchestrator *<br/>(orchestrator_enabled)"]
    Sup --> Reporter["Orchestration.Reporter *"]
    Sup --> Uptime["Orchestration.Uptime *"]
    Sup --> Endpoint["BusterClawWeb.Endpoint"]

    McpSup -.spawns.-> McpClient["MCP.Client<br/>(one per server)"]
    RunnerSup -.spawns.-> AgentRunner["AgentRunner<br/>(one per dispatched task)"]
```

---

## 3. Domain model (Ecto schemas & relationships)

All persisted schemas. Standalone schemas (no FKs) are grouped at the bottom.

```mermaid
classDiagram
    class Document {
        +string filename
        +string artifact_path
        +date date
        +string source_url
        +string content_hash
        +string status
        +string excerpt
    }
    class DeliveryDestination {
        +string name
        +string type
        +string url
        +string token
        +bool enabled
    }
    class DeliveryAttempt {
        +string title
        +string status
        +string error
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
    class OrchestratorTask {
        +string name
        +string type
        +string engine
        +string command
        +string prompt
        +string cron
        +utc due_at
        +string state
        +string lease_owner
        +utc lease_expires_at
        +int attempts
    }
    class AgentRun {
        +string engine
        +int os_pid
        +string status
        +utc started_at
        +utc last_heartbeat_at
        +int exit_code
        +string output_path
    }

    DeliveryDestination "1" --> "*" DeliveryAttempt : target of
    Integration "1" --> "*" IntegrationRun : has
    Hook "1" --> "*" HookRun : has
    OrchestratorTask "1" --> "*" AgentRun : dispatched as
```

### Standalone schemas (no foreign keys)

```mermaid
classDiagram
    class Shift {
        +utc started_at
        +string status
        +int dispatched_count
        +int done_count
        +int failed_count
        +string stopped_reason
    }
    class SecurityEvent {
        +string kind
        +string command
        +string caller
        +string tier
        +string outcome
        +map metadata
    }
    class AppSetting {
        +string key
        +string value
    }
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
    }
    class SchedulerJob {
        +string job_id
        +string type
        +string cron
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

The single most important design property: **one** dispatcher, three callers. Restricted-tier
commands are refused for the untrusted (MCP) caller and recorded in `Sentinel.Pending`.

```mermaid
classDiagram
    class Commands {
        +call(name, args, opts)
        +list_commands()
        -authorize(name, caller)
        -dispatch(name, args)
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
    class CLI {
        +main(argv)
    }
    class SentinelPending {
        +record(name, args, caller)
    }

    ApiController ..> Commands : POST /api/run (trusted)
    McpController ..> Commands : tools/call (mcp tier)
    CLI ..> ApiController : HTTP /api/run
    Commands ..> CommandsSchema : validates args
    Commands ..> CommandsResult : serializes output
    Commands ..> SentinelPending : queues refused restricted calls
```

---

## 5. Command call & tier gate

How a single command request is authorized, dispatched, and audited.

```mermaid
sequenceDiagram
    participant Caller as CLI / HTTP / MCP
    participant Commands as Commands.call/2
    participant Sentinel
    participant Context as Domain context
    participant Repo

    Caller->>Commands: call(name, args, caller: tier)
    Commands->>Commands: authorize(name, caller)
    alt restricted command, untrusted caller
        Commands->>Sentinel: Pending.record(name, args, caller)
        Commands-->>Caller: {:error, :requires_confirmation}
    else allowed
        Commands->>Context: dispatch(name, args)
        Context->>Repo: read / write
        Repo-->>Context: data
        Context-->>Commands: {:ok, value}
        Commands->>Sentinel: observe(command, caller, tier, outcome)
        Commands-->>Caller: {:ok, value}
    end
```

---

## 6. Orchestration shift (unattended dispatch)

The deterministic brain (not an LLM) reads due tasks, leases them, and dispatches disposable
headless agents — surviving crashes by resuming from SQLite.

```mermaid
sequenceDiagram
    participant Terminal as Terminal agent (shift_start)
    participant Orchestrator as Orchestrator (GenServer tick)
    participant DB as orchestrator_tasks / shifts
    participant Runner as AgentRunner (Port)
    participant Agent as claude -p / codex exec
    participant Reporter
    participant Sentinel

    Terminal->>Orchestrator: shift_start (clears kill switch)
    Orchestrator->>DB: create Shift (active, runs until stopped)
    loop every ~30s tick
        Orchestrator->>DB: select due tasks, lease (pending → claimed)
        alt :agent task
            Orchestrator->>Runner: spawn(engine, prompt, workspace)
            Runner->>Agent: run, wired to BusterClaw MCP
            Agent-->>Runner: heartbeat / output
            Runner->>DB: AgentRun status + result_path
        else :pipeline task
            Orchestrator->>Orchestrator: run deterministic command (GWS / noop)
        end
        Orchestrator->>Sentinel: observe dispatch
        Note over Orchestrator: crash-loop brake, concurrency + rate caps
    end
    Orchestrator->>Reporter: shift end / failures
    Reporter-->>Terminal: Delivery alert + morning report
```

---

## 7. HTTP routing & auth tiers

From `lib/buster_claw_web/router.ex`.

```mermaid
flowchart LR
    subgraph browser["pipe :browser (session, CSRF, LiveView)"]
        R1["/ , /orchestration, /browse, /split, /terminal,<br/>/calendar, /gws, /memory, /integrations, /mcp,<br/>/scheduler, /webhooks, /hooks, /delivery, /advanced,<br/>/security, /settings, /appearance, /workspace, /setup"]
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
