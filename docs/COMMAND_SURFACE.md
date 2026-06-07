# Buster Claw Command Surface

Canonical reference for `BusterClaw.Commands` — the unified command vocabulary that the internal chat agent, the external CLI escript, and the MCP server endpoint all consume.

See `daily-growth/roadmaps/05-17-26-command-surface-roadmap.md` for the build plan.

## Contracts

### Naming convention

`<noun>_<verb>`. Nouns first so the catalog groups cleanly when sorted (`source_create`, `source_delete`, `source_ingest`, `source_list` cluster). For compound nouns, use a single noun (`mcp_server_*`, `scheduler_job_*`, `delivery_destination_*`).

### Return shape

Every command returns one of:

- `{:ok, value}` — success. `value` is the resource, list, or scalar appropriate to the command.
- `{:ok, value, meta}` — success with metadata (e.g., job counts). Used sparingly.
- `{:error, %Ecto.Changeset{}}` — validation failure. The frontends translate this to 422 JSON / MCP error / CLI table of errors.
- `{:error, reason_atom}` — operational failure with a known atom: `:not_found`, `:unauthorized`, `:disabled`, `:no_active_provider`, `:bad_status`, `:empty_query`, etc.
- `{:error, term()}` — opaque transport / IO failures. Frontends translate to 500 with the term inspected.

Bang functions (`get_*!`) are **not** part of the command surface. The `Commands` wrappers convert raises to `{:error, :not_found}`.

### Argument schema notation

Args use a compact `{key: type [?] [default]}` syntax:

- `string`, `integer`, `boolean`, `map`, `datetime`, `date`, `string[]` (array of strings)
- `enum[a | b | c]` — value must be one of
- `?` after the key marks it optional
- `default: x` — applied if omitted
- `id` is always integer (the autoincrement primary key)
- `*` after a field name marks it as required even though the schema permits nil (e.g., we validate at the command boundary)

### Internal agent allowlist tiers

Two tiers control which commands the active provider's chat model can invoke as tools:

- **safe**: read commands, chat operations, low-risk triggers (test connections, poll status). The model can use these freely.
- **restricted**: mutations (create/update/delete), destructive triggers (delivery_dispatch_all, scheduler_job_run_now, hook_event_execute), and identity-changing actions (provider_set_active). The model cannot invoke these via the chat tool surface.

External callers (CLI, MCP, HTTP) bypass this allowlist — they're operating on behalf of a human or external agent that has the auth token. The allowlist only constrains the internal chat model.

### Side-effect notes

Most mutating commands broadcast on a PubSub topic and write to SQLite. Triggers may also enqueue work, write filesystem artifacts under `Library/`, or make outbound HTTP calls. Each command's side effects are listed below.

---

## Quick reference

| Domain | Commands |
|---|---|
| **Sources** | `source_list`, `source_get`, `source_create`, `source_update`, `source_delete`, `source_ingest` |
| **Providers** | `provider_list`, `provider_get`, `provider_active`, `provider_create`, `provider_update`, `provider_delete`, `provider_set_active`, `provider_test` |
| **Documents** | `document_list`, `document_get`, `document_read`, `document_save`, `document_delete` |
| **Reports** | `report_list`, `report_get` |
| **Analysis** | `analysis_job_list`, `analysis_queue`, `analysis_run_pending`, `analysis_run_job` |
| **Memory** | `memory_list`, `memory_remember`, `memory_forget` |
| **Events** | `event_list`, `event_get`, `event_create`, `event_update`, `event_delete` |
| **MCP servers** | `mcp_server_list`, `mcp_server_get`, `mcp_server_create`, `mcp_server_update`, `mcp_server_delete`, `mcp_server_connect`, `mcp_server_tools` |
| **Webhooks** | `webhook_list`, `webhook_get`, `webhook_create`, `webhook_update`, `webhook_delete`, `webhook_trigger` |
| **Hooks** | `hook_list`, `hook_get`, `hook_create`, `hook_update`, `hook_delete`, `hook_test`, `hook_event_execute` |
| **Delivery destinations** | `delivery_destination_list`, `delivery_destination_get`, `delivery_destination_create`, `delivery_destination_update`, `delivery_destination_delete`, `delivery_destination_test` |
| **Delivery** | `delivery_dispatch_all` |
| **Scheduler** | `scheduler_job_list`, `scheduler_job_get`, `scheduler_job_create`, `scheduler_job_update`, `scheduler_job_delete`, `scheduler_job_run_now` |
| **Integrations** | `integration_list`, `integration_get`, `integration_create`, `integration_update`, `integration_delete`, `integration_poll`, `integration_poll_all`, `integration_run_list`, `integration_monitoring_brief` |
| **Google Workspace** | `google_account_list`, `google_account_get`, `google_account_create`, `google_account_update`, `google_account_delete`, `gmail_label_list`, `gmail_search`, `gmail_read`, `gmail_sync`, `gmail_draft_create`, `gmail_send`, `google_calendar_sync` |
| **Chat** | `chat_send`, `chat_messages`, `chat_clear` |
| **Search** | `web_search` |
| **Browser** | `browser_fetch` |
| **Runtime** | `runtime_status` |

Total: **93 commands**.

---

## Sources

Configured ingestion targets (RSS feeds, URLs, etc.).

### `source_list`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [Source]}`
- **Delegates**: `BusterClaw.Sources.list_sources/0`

### `source_get`
- **Type**: read | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Source} | {:error, :not_found}`
- **Delegates**: `BusterClaw.Sources.get_source!/1`

### `source_create`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{url: string, type: enum[rss | url], name?: string, tags?: map, browser_engine?: string, cookies?: map, enabled?: boolean default: true}`
- **Returns**: `{:ok, Source} | {:error, Changeset}`
- **Side effects**: insert into `sources`; PubSub broadcast on `"sources"` topic
- **Delegates**: `BusterClaw.Sources.create_source/1`

### `source_update`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer, url?: string, type?: enum[rss | url], name?: string, tags?: map, browser_engine?: string, cookies?: map, enabled?: boolean}`
- **Returns**: `{:ok, Source} | {:error, Changeset | :not_found}`
- **Side effects**: update `sources`; broadcast
- **Delegates**: `BusterClaw.Sources.update_source/2`

### `source_delete`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Source} | {:error, :not_found}`
- **Side effects**: delete from `sources`; broadcast
- **Delegates**: `BusterClaw.Sources.delete_source/1`

### `source_ingest`
- **Type**: trigger | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, %{count: integer, items: [Document]}} | {:error, term()}`
- **Side effects**: outbound HTTP fetch; writes markdown files to `Library/raw/`; inserts `documents` linked to the source ID; broadcasts ingestion + runtime events
- **Delegates**: `BusterClaw.Ingest.ingest_source/1`

---

## Providers

Configured LLM endpoints (Anthropic, Gemini, Codex, OpenAI, OpenRouter, Ollama, custom).

### `provider_list`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [Provider]}` — sorted by priority
- **Delegates**: `BusterClaw.Providers.list_providers/0`

### `provider_get`
- **Type**: read | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Provider} | {:error, :not_found}`

### `provider_active`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, Provider | nil}`
- **Delegates**: `BusterClaw.Providers.active_provider/0`

### `provider_create`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{name: string, type: enum[anthropic | gemini | codex | openai | openrouter | ollama | custom], model: string, api_key?: string, base_url?: string, active?: boolean default: false, priority?: integer default: 100}`
- **Returns**: `{:ok, Provider} | {:error, Changeset}`
- **Side effects**: insert into `providers`
- **Notes**: `api_key` is required for every type except `ollama` (validated by the changeset). `base_url` is auto-filled if omitted (e.g., `https://api.anthropic.com` for `anthropic`).
- **Delegates**: `BusterClaw.Providers.create_provider/1`

### `provider_update`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer, name?: string, type?: string, model?: string, api_key?: string, base_url?: string, active?: boolean, priority?: integer}`
- **Returns**: `{:ok, Provider} | {:error, Changeset | :not_found}`

### `provider_delete`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Provider} | {:error, :not_found}`

### `provider_set_active`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Provider} | {:error, :not_found}`
- **Side effects**: deactivates all other providers in a transaction
- **Delegates**: `BusterClaw.Providers.set_active_provider/1`

### `provider_test`
- **Type**: trigger | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, string} | {:error, :not_found | term()}` — string is the model's reply to the test ping
- **Side effects**: outbound HTTP to the provider endpoint
- **Delegates**: `BusterClaw.Providers.test_provider/1`

---

## Documents

Markdown artifacts in `Library/raw/`. Created via `source_ingest` or directly via `document_save`.

### `document_list`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [Document]}` — sorted by date desc
- **Delegates**: `BusterClaw.Library.list_documents/0`

### `document_get`
- **Type**: read | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Document} | {:error, :not_found}`

### `document_read`
- **Type**: read | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, string} | {:error, :not_found | term()}` — raw markdown contents
- **Delegates**: `BusterClaw.Library.read_raw_document/1`

### `document_save`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{name: string, body: string, source_url?: string, date?: date, tags?: map, source_id?: integer}`
- **Returns**: `{:ok, Document} | {:error, term()}`
- **Side effects**: writes markdown file to `Library/raw/<filename>`; inserts `documents`
- **Delegates**: `BusterClaw.Library.save_raw_document/1`

### `document_delete`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Document} | {:error, :not_found | term()}`
- **Side effects**: deletes the markdown file from disk; updates `documents` (does not hard-delete the row — sets `status: "deleted"`)
- **Delegates**: `BusterClaw.Library.delete_raw_document/1`

---

## Reports

Analysis output artifacts. Reports are produced by `analysis_run_*`; they are not created directly via the command surface.

### `report_list`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [Report]}` — sorted by date desc

### `report_get`
- **Type**: read | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Report} | {:error, :not_found}`

---

## Analysis

Document analysis queue and execution.

### `analysis_job_list`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [AnalysisJob]}` — preloads `document`, `report`, `provider`; sorted by status then date

### `analysis_queue`
- **Type**: trigger | **Tier**: safe
- **Args**: `{document_id: integer, provider_id?: integer, intentions?: string}`
- **Returns**: `{:ok, AnalysisJob} | {:error, Changeset | :not_found}`
- **Side effects**: inserts a pending job into `analysis_jobs`; broadcasts on `"analysis"` topic
- **Delegates**: `BusterClaw.Analysis.queue_document/2`

### `analysis_run_pending`
- **Type**: trigger | **Tier**: restricted
- **Args**: `{max?: integer default: 1}`
- **Returns**: `{:ok, [{:ok, AnalysisJob} | {:error, term()}]}`
- **Side effects**: outbound HTTP to active provider; writes report markdown to `Library/reports/`; updates `analysis_jobs`, `documents`, `reports`
- **Delegates**: `BusterClaw.Analysis.run_pending/1`

### `analysis_run_job`
- **Type**: trigger | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, AnalysisJob} | {:error, :not_found | term()}`
- **Side effects**: same as `analysis_run_pending` but for a specific job
- **Delegates**: `BusterClaw.Analysis.run_job/2`

---

## Memory

Persistent facts surfaced to the chat model's system prompt.

### `memory_list`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [Memory]}` — each has `text: string, created_at: datetime`

### `memory_remember`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{text: string}`
- **Returns**: `{:ok, Memory} | {:error, Changeset}`
- **Side effects**: insert into `memories`; broadcast
- **Delegates**: `BusterClaw.Memory.create_memory/1` (auto-populates `created_at`)

### `memory_forget`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Memory} | {:error, :not_found}`
- **Side effects**: delete from `memories`; broadcast

---

## Events

Calendar entries (locally stored; Google Calendar sync is a separate concern).

### `event_list`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [Event]}`

### `event_get`
- **Type**: read | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Event} | {:error, :not_found}`

### `event_create`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{event_id: string, date: date, title: string, notes?: string}`
- **Returns**: `{:ok, Event} | {:error, Changeset}`

### `event_update`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer, event_id?: string, date?: date, title?: string, notes?: string}`
- **Returns**: `{:ok, Event} | {:error, Changeset | :not_found}`

### `event_delete`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Event} | {:error, :not_found}`

---

## MCP servers

External MCP servers Buster Claw connects to (consumes, not hosts).

### `mcp_server_list`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [MCPServer]}`

### `mcp_server_get`
- **Type**: read | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, MCPServer} | {:error, :not_found}`

### `mcp_server_create`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{name: string, command: string, args?: map, env?: map, enabled?: boolean default: true}`
- **Returns**: `{:ok, MCPServer} | {:error, Changeset}`

### `mcp_server_update`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer, name?: string, command?: string, args?: map, env?: map, enabled?: boolean}`
- **Returns**: `{:ok, MCPServer} | {:error, Changeset | :not_found}`

### `mcp_server_delete`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, MCPServer} | {:error, :not_found}`

### `mcp_server_connect`
- **Type**: trigger | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, MCPServer} | {:error, :not_found | :disabled | term()}`
- **Side effects**: launches the configured stdio command under the MCP supervisor, runs `initialize`, sends `notifications/initialized`, discovers tools with `tools/list`, and updates runtime status fields.

### `mcp_server_tools`
- **Type**: trigger | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, [map]} | {:error, :not_found | :disabled | term()}`
- **Side effects**: starts the MCP server if needed and returns the discovered tool list.

---

## Webhooks

Local HTTP webhook receivers. Exposed via `POST /hooks/:name`.

### `webhook_list`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [Webhook]}`

### `webhook_get`
- **Type**: read | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Webhook} | {:error, :not_found}`

### `webhook_create`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{name: string, action: enum[run_analysis | ingest_url | run_scheduler | shell], secret?: string, custom_cmd?: string, deliver_to?: string, enabled?: boolean default: true}`
- **Returns**: `{:ok, Webhook} | {:error, Changeset}`

### `webhook_update`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer, name?: string, action?: string, secret?: string, custom_cmd?: string, deliver_to?: string, enabled?: boolean}`
- **Returns**: `{:ok, Webhook} | {:error, Changeset | :not_found}`

### `webhook_delete`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Webhook} | {:error, :not_found}`

### `webhook_trigger`
- **Type**: trigger | **Tier**: restricted
- **Args**: `{name: string, headers?: map, body?: string}`
- **Returns**: `{:ok, map} | {:error, :not_found | :disabled | :unauthorized}`
- **Side effects**: validates secret; emits runtime audit event; performs the webhook's `action`
- **Delegates**: `BusterClaw.Webhooks.trigger/3`

---

## Hooks

Pre/post-event hooks. Fire on lifecycle events (`analysis_completed`, `delivery_failed`, etc.).

### `hook_list`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [Hook]}`

### `hook_get`
- **Type**: read | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Hook} | {:error, :not_found}`

### `hook_create`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{name: string, event: string, type: enum[shell | webhook], target: string, async?: boolean default: true, enabled?: boolean default: true}`
- **Returns**: `{:ok, Hook} | {:error, Changeset}`

### `hook_update`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer, name?: string, event?: string, type?: string, target?: string, async?: boolean, enabled?: boolean}`
- **Returns**: `{:ok, Hook} | {:error, Changeset | :not_found}`

### `hook_delete`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Hook} | {:error, :not_found}`

### `hook_test`
- **Type**: trigger | **Tier**: safe
- **Args**: `{id: integer, payload?: map}`
- **Returns**: `{:ok, HookRun} | {:error, :not_found | term()}`
- **Side effects**: runs the hook's target (shell command or webhook URL); records a `hook_runs` row
- **Delegates**: `BusterClaw.Hooks.test_hook/2`

### `hook_event_execute`
- **Type**: trigger | **Tier**: restricted
- **Args**: `{event: string, payload?: map}`
- **Returns**: `{:ok, [{:ok, HookRun} | {:error, term()}]}`
- **Side effects**: fires every enabled hook bound to `event`
- **Delegates**: `BusterClaw.Hooks.execute_event/3`

---

## Delivery destinations

Outbound delivery endpoints (Slack, Discord, Telegram, email).

### `delivery_destination_list`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [DeliveryDestination]}`

### `delivery_destination_get`
- **Type**: read | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, DeliveryDestination} | {:error, :not_found}`

### `delivery_destination_create`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{name: string, type: enum[slack | discord | telegram | email | webhook], url?: string, token?: string, chat_id?: string, enabled?: boolean default: true}`
- **Returns**: `{:ok, DeliveryDestination} | {:error, Changeset}`

### `delivery_destination_update`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer, name?: string, type?: string, url?: string, token?: string, chat_id?: string, enabled?: boolean}`
- **Returns**: `{:ok, DeliveryDestination} | {:error, Changeset | :not_found}`

### `delivery_destination_delete`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, DeliveryDestination} | {:error, :not_found}`

### `delivery_destination_test`
- **Type**: trigger | **Tier**: safe
- **Args**: `{id: integer, payload?: map}`
- **Returns**: `{:ok | :error, DeliveryAttempt}`
- **Side effects**: outbound HTTP to destination; records `delivery_attempts` row
- **Delegates**: `BusterClaw.Delivery.test_destination/2`

---

## Delivery

Top-level delivery actions (broadcast across multiple destinations).

### `delivery_dispatch_all`
- **Type**: trigger | **Tier**: restricted
- **Args**: `{payload: map}`
- **Returns**: `{:ok, [{:ok | :error, DeliveryAttempt}]}`
- **Side effects**: outbound HTTP to every enabled destination; records `delivery_attempts` rows
- **Delegates**: `BusterClaw.Delivery.dispatch_all/2`

---

## Scheduler jobs

Cron-driven recurring tasks.

### `scheduler_job_list`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [SchedulerJob]}`

### `scheduler_job_get`
- **Type**: read | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, SchedulerJob} | {:error, :not_found}`

### `scheduler_job_create`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{job_id: string, type: string, cron: string, enabled?: boolean default: true, custom_cmd?: string, deliver_to?: string}`
- **Returns**: `{:ok, SchedulerJob} | {:error, Changeset}`

### `scheduler_job_update`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer, job_id?: string, type?: string, cron?: string, enabled?: boolean, custom_cmd?: string, deliver_to?: string}`
- **Returns**: `{:ok, SchedulerJob} | {:error, Changeset | :not_found}`

### `scheduler_job_delete`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, SchedulerJob} | {:error, :not_found}`

### `scheduler_job_run_now`
- **Type**: trigger | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, map} | {:error, :not_found | term()}`
- **Side effects**: runs the job's task (could trigger ingestion, analysis, delivery, or a custom command); updates `scheduler_jobs.last_run_at` and `last_error`
- **Delegates**: `BusterClaw.Scheduler.run_now/1`

---

## Integrations

Service integrations (GitHub, Slack, Jira, etc.) that poll external systems and turn updates into Library documents.

### `integration_list`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [Integration]}`

### `integration_get`
- **Type**: read | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Integration} | {:error, :not_found}`

### `integration_create`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{name: string, service_type: string, base_url?: string, token?: string, webhook_secret?: string, config?: map, enabled?: boolean default: true, polling_interval_minutes?: integer default: 60}`
- **Returns**: `{:ok, Integration} | {:error, Changeset}`

### `integration_update`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer, name?: string, service_type?: string, base_url?: string, token?: string, webhook_secret?: string, config?: map, enabled?: boolean, polling_interval_minutes?: integer}`
- **Returns**: `{:ok, Integration} | {:error, Changeset | :not_found}`

### `integration_delete`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, Integration} | {:error, :not_found}`

### `integration_poll`
- **Type**: trigger | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, IntegrationRun} | {:error, :not_found | IntegrationRun}` — the error variant carries the failed run record
- **Side effects**: outbound HTTP to integration's service; may save documents; records `integration_runs` row; broadcasts
- **Delegates**: `BusterClaw.Integrations.poll_integration/2`

### `integration_poll_all`
- **Type**: trigger | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [{:ok | :error, IntegrationRun}]}`
- **Side effects**: polls every enabled integration sequentially

### `integration_run_list`
- **Type**: read | **Tier**: safe
- **Args**: `{integration_id?: integer}` — if omitted, returns runs across all integrations
- **Returns**: `{:ok, [IntegrationRun]}` — sorted by `started_at` desc

### `integration_monitoring_brief`
- **Type**: trigger | **Tier**: restricted
- **Args**: `{provider_id?: integer, limit?: integer default: 10, window?: string}`
- **Returns**: `{:ok, Report} | {:error, :no_integration_documents | :no_active_provider | :provider_not_found | term}`
- **Side effects**: reads latest integration Library snapshots, calls the selected provider, and writes a monitoring report artifact
- **Provider selection**: uses the active provider by default; `provider_id` overrides it for a single brief

---

## Google Workspace

Stored OAuth account shells for Gmail and Google Workspace sync. Account commands return safe summaries only; client secrets and tokens are encrypted at rest and never returned as plaintext.

### `google_account_list`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, [GoogleAccountSummary]}`
- **Delegates**: `BusterClaw.Google.list_account_summaries/0`

### `google_account_get`
- **Type**: read | **Tier**: safe
- **Args**: `{id: integer}`
- **Returns**: `{:ok, GoogleAccountSummary} | {:error, :not_found}`

### `google_account_create`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{email: string, client_id: string, client_secret?: string, refresh_token?: string, access_token?: string, access_token_expires_at?: datetime, scopes?: string, default_query?: string, enabled?: boolean default: true}`
- **Returns**: `{:ok, GoogleAccountSummary} | {:error, Changeset}`
- **Side effects**: inserts `google_accounts`; encrypts credential fields; broadcasts on `"google"` topic

### `google_account_update`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer, email?: string, client_id?: string, client_secret?: string, refresh_token?: string, access_token?: string, access_token_expires_at?: datetime, scopes?: string, default_query?: string, enabled?: boolean}`
- **Returns**: `{:ok, GoogleAccountSummary} | {:error, Changeset | :not_found}`
- **Side effects**: updates `google_accounts`; re-encrypts changed credential fields; broadcasts

### `google_account_delete`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{id: integer}`
- **Returns**: `{:ok, GoogleAccountSummary} | {:error, :not_found}`
- **Side effects**: deletes from `google_accounts`; broadcasts

### `gmail_label_list`
- **Type**: read | **Tier**: safe
- **Args**: `{account_id?: integer, email?: string}` — if omitted, uses the first enabled connected account
- **Returns**: `{:ok, [GmailLabel]} | {:error, :no_google_account | term()}`
- **Side effects**: outbound HTTP to Gmail; may refresh OAuth access token

### `gmail_search`
- **Type**: read | **Tier**: safe
- **Args**: `{account_id?: integer, email?: string, query?: string, limit?: integer default: 10}` — if `query` is omitted, uses the account default query
- **Returns**: `{:ok, %{messages: [GmailMessageSummary], result_size_estimate: integer, next_page_token?: string}} | {:error, :no_google_account | term()}`
- **Side effects**: outbound HTTP to Gmail; may refresh OAuth access token

### `gmail_read`
- **Type**: read | **Tier**: safe
- **Args**: `{account_id?: integer, email?: string, message_id: string}`
- **Returns**: `{:ok, GmailMessage} | {:error, :missing_message_id | :no_google_account | term()}`
- **Side effects**: outbound HTTP to Gmail; may refresh OAuth access token

### `gmail_sync`
- **Type**: trigger | **Tier**: safe
- **Args**: `{account_id?: integer, email?: string, query?: string, limit?: integer default: 10, incremental?: boolean default: false, start_history_id?: string}` — if `query` is omitted, uses the account default query
- **Returns**: query mode returns `{:ok, %{synced: integer, requested: integer, documents: [Document], errors: [term()], account: GoogleAccountSummary}}`; incremental mode returns `{:ok, %{mode: :incremental, synced: integer, requested: integer, documents: [Document], deleted_message_ids: [string], full_sync_required: boolean, account: GoogleAccountSummary}}`; errors include `{:error, :no_google_account | term()}`
- **Side effects**: outbound HTTP to Gmail; may refresh OAuth access token; writes stable Gmail markdown documents under `Library/raw/YYYY-MM-DD`; updates the Google account sync cursor fields. Incremental mode uses Gmail `users/me/history` from the stored `last_seen_history_id`; if the cursor is missing or too old it reports `full_sync_required: true` instead of silently falling back.

### `gmail_draft_create`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{account_id?: integer, email?: string, to?: string, recipient?: string alias for to, cc?: string, bcc?: string, subject: string, body: string}`
- **Returns**: `{:ok, %{id: string, message_id: string, thread_id: string, raw: map}} | {:error, :missing_recipient | :missing_subject | :missing_body | :no_google_account | term()}`
- **Side effects**: outbound HTTP to Gmail; may refresh OAuth access token; creates a Gmail draft only. It does not send mail.
- **Notes**: requires the connected Google account to authorize `https://www.googleapis.com/auth/gmail.compose`; reconnect older accounts if Gmail returns insufficient-scope errors.

### `gmail_send`
- **Type**: mutate | **Tier**: restricted
- **Args**: `{account_id?: integer, email?: string, to?: string, recipient?: string alias for to, cc?: string, bcc?: string, subject: string, body: string, confirm_send: true}`
- **Returns**: `{:ok, %{id: string, thread_id: string, label_ids: [string], raw: map}} | {:error, :missing_send_confirmation | :missing_recipient | :missing_subject | :missing_body | :no_google_account | term()}`
- **Side effects**: outbound HTTP to Gmail; may refresh OAuth access token; sends mail from the connected Google account.
- **Notes**: callers must pass `confirm_send: true` (or `"send"` for CLI-style string args). Requires `https://www.googleapis.com/auth/gmail.compose`.

### `google_calendar_sync`
- **Type**: trigger | **Tier**: safe
- **Args**: `{account_id?: integer, email?: string, calendar_id?: string default: "primary", days_ahead?: integer default: 90, force_full?: boolean default: false}`
- **Returns**: `{:ok, %{mode: :full | :incremental, imported: integer, created: integer, updated: integer, deleted: integer, events: [Event], account: GoogleAccountSummary, next_sync_token?: string}} | {:error, {:calendar_sync_token_invalid, map()} | :no_google_account | term()}`
- **Side effects**: outbound HTTP to Google Calendar; may refresh OAuth access token; one-way upserts imported Google events into `calendar_events`; removes stale previously imported Google events for that account/calendar during full sync while leaving local and scheduler-authored events untouched. Stores per-calendar Google `nextSyncToken` on the account and reuses it for incremental delta syncs. If Google invalidates the token, the stored token is cleared and the error payload includes `full_sync_required: true`.

---

## Chat

Live chat session with the active provider. Sessions are supervised GenServers keyed by `session_id` (default: `"default"`).

### `chat_send`
- **Type**: trigger | **Tier**: safe
- **Args**: `{prompt: string, content?: string alias for prompt, session_id?: string default: "default"}`
- **Returns**: `{:ok, :sent}`
- **Side effects**: enqueues prompt for the session GenServer; streams assistant tokens via PubSub on `"chat:<session_id>"`; returns immediately. Use `chat_messages` to read the result, or subscribe to the PubSub topic for streaming.
- **Notes**: slash commands (`/help`, `/status`, `/ingest`, etc.) work here — they execute inline and append a system message to the session.
- **Delegates**: `BusterClaw.Chat.send_message/2`

### `chat_messages`
- **Type**: read | **Tier**: safe
- **Args**: `{session_id?: string default: "default"}`
- **Returns**: `{:ok, [Message]}` — each has `role: "user" | "assistant" | "system", content: string, timestamp: datetime`

### `chat_clear`
- **Type**: mutate | **Tier**: safe
- **Args**: `{session_id?: string default: "default"}`
- **Returns**: `{:ok, :cleared}`
- **Side effects**: drops session history; broadcasts `:cleared` event

---

## Search

DuckDuckGo web search.

### `web_search`
- **Type**: trigger | **Tier**: safe
- **Args**: `{query: string, limit?: integer default: 10}`
- **Returns**: `{:ok, [SearchResult]} | {:error, :empty_query | {:bad_status, integer} | term()}` — each result has `title: string, url: string, snippet: string`
- **Side effects**: outbound HTTP to DuckDuckGo
- **Delegates**: `BusterClaw.Search.search/2`

---

## Browser

Fetch a URL and convert HTML to markdown. Uses a configured or supervised Playwright sidecar when available, then falls back to `Req` for direct HTTP fetches.

Sidecar runtime controls:

- `BUSTER_CLAW_BROWSER_SIDECAR=1` starts the bundled Node sidecar supervisor.
- `BUSTER_CLAW_BROWSER_SIDECAR_COMMAND=/path/to/node` overrides the Node executable.
- `BUSTER_CLAW_BROWSER_SIDECAR_URL=http://127.0.0.1:PORT` points at an already-running sidecar.

### `browser_fetch`
- **Type**: trigger | **Tier**: safe
- **Args**: `{url: string}`
- **Returns**: `{:ok, %{url: string, title: string, html: string, markdown: string}} | {:error, {:bad_status, integer} | {:sidecar_bad_status, integer, term()} | term()}`
- **Side effects**: outbound HTTP fetch or local sidecar navigation
- **Delegates**: `BusterClaw.Browser.fetch/2`

---

## Runtime

Process and system metadata.

### `runtime_status`
- **Type**: read | **Tier**: safe
- **Args**: none
- **Returns**: `{:ok, %{app: string, phase: string, library_root: string, library_exists?: boolean, database_path: string, database_exists?: boolean, pubsub: string, endpoint: string, views: [map], services: [string]}}`
- **Delegates**: `BusterClaw.Runtime.Status.snapshot/0`

---

## Frontend mapping

How each command appears in each frontend:

| Frontend | Invocation |
|---|---|
| **Elixir** (internal) | `BusterClaw.Commands.source_create(%{url: "...", type: "rss"})` |
| **HTTP API** | `POST /api/run` with `{"command": "source_create", "args": {"url": "...", "type": "rss"}}` and `Authorization: Bearer <token>` header |
| **MCP (SSE)** | `tools/call` with `{"name": "source_create", "arguments": {"url": "...", "type": "rss"}}` |
| **CLI** | `./buster-claw source create --url "..." --type rss` (or `./buster-claw run source_create --json '{"url":"...","type":"rss"}'` for raw form) |

The CLI converts `<noun>_<verb>` into `<noun> <verb>` for ergonomics, and exposes args as flags. The HTTP and MCP frontends pass args through verbatim.

## Open notes

- `chat_send` is async by design. A synchronous variant (`chat_chat`) that blocks until the model finishes would be useful for CLI/MCP scripting; deferred to a v2 of the command surface.
- `analysis_run_pending` and `delivery_dispatch_all` can take long enough that an HTTP request times out. Consider a `async: true` flag that returns immediately with a job ID and a subscribe topic.
- The `*_update` commands all use partial updates (any field omitted is left alone). The HTTP API should reject extra keys to catch typos.
- Schema-driven arg validation should be done at the `Commands` layer, not duplicated in each frontend. The frontends just pass the user args through; `Commands` does the cast + validate.
