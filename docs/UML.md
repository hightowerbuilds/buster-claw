# Buster Claw — UML / Architecture Diagrams

Mermaid diagrams describing both the **structure** (modules, schemas, supervision) and the
**functionality** (request flows) of the codebase. Rendered automatically by GitHub and most
Markdown viewers.

> Source of truth: re-derived from `lib/` on 2026-06-14 (post pull-queue cut and the
> Delivery / Hooks / Webhooks / Scheduler / Memory retirement). Re-derive after large refactors.

---

## 1. System layers (functional overview)

How the frontends, the unified command surface, the domain contexts, and the external world
fit together. Buster Claw has no built-in LLM — the intelligence is a terminal agent
(Claude Code / Codex) running in the in-app PTY, driving the command surface over the CLI/HTTP
and pulling work from the Dispatch queue.

```mermaid
flowchart TB
    subgraph Frontends["Frontends / Entry points"]
        CLI["CLI escript<br/>(cli.ex)"]
        WebUI["LiveView UI"]
        HTTP["HTTP API<br/>(api_controller)"]
        Webhooks_in["Inbound integration webhooks<br/>(integration_webhook)"]
    end

    subgraph Surface["Unified Command Surface"]
        Commands["Commands.call/2<br/>(tier-gated)"]
        Schema["Commands.Schema"]
        Result["Commands.Result"]
    end

    subgraph Contexts["Domain Contexts"]
        Library & Browser & Search & Calendar & Finance
        Google & Integrations & Dispatch
        Orchestration & Sentinel & Settings
    end

    subgraph Infra["Infrastructure"]
        Repo["Repo (SQLite/Ecto)"]
        PubSub["Phoenix.PubSub"]
        Vault["Vault / Google.Vault<br/>(AES-256-GCM)"]
    end

    subgraph External["External services"]
        TermAgent["Terminal agent<br/>(Claude Code / Codex in the PTY)"]
        GoogleAPI["Google Workspace<br/>(Gmail / Calendar)"]
        BrowserBin["Browser sidecar<br/>(Playwright, optional)"]
        Integr["GitHub / Sentry / Umami"]
        FinanceAPI["SEC EDGAR / Finnhub"]
    end

    CLI -->|HTTP /api/run| HTTP
    WebUI --> Contexts
    HTTP --> Commands
    Webhooks_in --> Integrations
    TermAgent -->|reads fridge, dispatch CLI| Dispatch

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
    Finance --> FinanceAPI

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
    Sup --> Projector["DispatchProjector *<br/>(dispatch_projector_enabled)"]
    Sup --> TermWS["TerminalWorkspace"]
    Sup --> SentinelPending["Sentinel.Pending"]
    Sup --> Sidecar["Browser.Sidecar *<br/>(browser_sidecar_enabled)"]
    Sup --> Orchestrator["Orchestrator *<br/>(orchestrator_enabled)"]
    Sup --> Uptime["Orchestration.Uptime *<br/>(orchestrator_enabled)"]
    Sup --> Endpoint["BusterClawWeb.Endpoint"]
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
    class Shift {
        +utc started_at
        +string status
        +string job_key
        +string agent_name
        +int dispatched_count
        +int done_count
        +int failed_count
        +string stopped_reason
    }
    class ShiftAssignment {
        +string role_key
        +string agent_name
        +string status
        +utc started_at
        +utc ended_at
        +string purpose
    }
    class DispatchItem {
        +string source
        +string sender
        +bool trusted
        +string gmail_message_id
        +string gmail_rfc_message_id
        +string subject
        +string recommended_role_key
        +string status
        +string claimed_by
        +string outcome
    }

    Integration "1" --> "*" IntegrationRun : has
    Shift "1" --> "*" ShiftAssignment : has
    Shift "1" --> "*" DispatchItem : scopes
    ShiftAssignment "1" --> "*" DispatchItem : claims
```

### Standalone schemas (no foreign keys)

```mermaid
classDiagram
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
```

---

## 4. Command surface dispatch (shared by all frontends)

The single most important design property: **one** dispatcher, multiple callers. Restricted-tier
commands are refused for an untrusted caller (the scoped `:mcp` token) and recorded in
`Sentinel.Pending`.

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
    class CLI {
        +main(argv)
    }
    class SentinelPending {
        +record(name, args, caller)
    }

    ApiController ..> Commands : POST /api/run (token-derived tier)
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
    participant Caller as CLI / HTTP
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

## 6. The Dispatch pull-queue (terminal-driven work)

There is no headless dispatch. A human-run terminal agent reads the queue projected to the
workspace fridge, claims items, does the work, and writes results back through the audited
`buster-claw dispatch` CLI. The `Orchestrator` is a supervised janitor that only watches the
kill switch; all work state is durable in SQLite, so an OTP restart resumes mid-shift.

```mermaid
sequenceDiagram
    participant Poller as Gmail poll (mailman)
    participant Dispatch as Dispatch queue (SQLite)
    participant Projector as DispatchProjector
    participant Fridge as shift/Dispatch.md
    participant Agent as Terminal agent (Claude Code / Codex)
    participant Sentinel

    Poller->>Dispatch: enqueue_gmail (trusted senders only)
    Dispatch-->>Projector: {:dispatch, event, item} (PubSub)
    Projector->>Fridge: render open items, grouped by job
    Agent->>Fridge: read worklist
    Agent->>Dispatch: dispatch claim --job <key>
    Agent->>Agent: do the work (search / fetch / reply …)
    Agent->>Dispatch: dispatch reply / done / block (audited)
    Dispatch->>Sentinel: observe outbound send / mutation
    Note over Agent,Dispatch: Orchestrator janitor only watches the STOP kill switch
```

---

## 7. HTTP routing & auth tiers

From `lib/buster_claw_web/router.ex`.

```mermaid
flowchart LR
    subgraph browser["pipe :browser (session, CSRF, LiveView)"]
        R1["/ , /browse, /split, /terminal, /calendar,<br/>/gws, /integrations, /security, /settings,<br/>/appearance, /workspace, /manual, /setup"]
        R2["/google/oauth/callback"]
    end
    subgraph raw["raw scopes (loopback, no auth)"]
        W1["/ws/file"]
        W2["/browser/{chrome,home,workspace}<br/>+ POST history/bookmarks"]
        W3["/finance/api/{search,lookup}"]
    end
    subgraph api["pipe :api (unauthenticated)"]
        H1["GET /_health"]
        H2["POST /integrations/:name/webhook<br/>(secret verified)"]
        H4["GET /api/commands (catalog metadata)"]
    end
    subgraph auth["pipe :api_authenticated (Bearer token)"]
        A1["POST /api/run"]
    end
```
