# Integration Plan: Sentry, GitHub, and Umami

## Status

Implementation-ready planning draft.

This document describes how Buster Claw should add Sentry, GitHub, and Umami oversight without changing the current model provider architecture. These services are operational data sources. They are not model providers. They feed the existing Library and Analysis pipeline, and the active model provider remains responsible for interpretation, consultation, and report generation.

## Product Intent

Buster Claw is becoming a local-first operations analyst for the user's projects. It should collect signals from production monitoring, repository activity, and website analytics, then ask the configured model provider to produce concise consultation reports.

The core value is not showing every metric. The core value is correlation:

- Did a deploy or merged pull request line up with a new Sentry issue?
- Did traffic change after a release?
- Did errors increase while GitHub activity suggests a specific area changed?
- What should the user do first today?

## Existing Architecture To Preserve

Buster Claw already has the right spine:

- `BusterClaw.Providers` owns LLM provider configuration and active-provider selection.
- `BusterClaw.Provider` defines the chat behavior used by chat and analysis.
- `BusterClaw.Library` owns markdown artifacts and document/report metadata.
- `BusterClaw.Analysis` queues Library documents and turns them into reports through the active provider.
- `BusterClaw.Scheduler` can manually trigger workflow work today and can later gain autonomous cron ticking.
- `BusterClaw.Webhooks` accepts local push events and records audit events.
- `BusterClaw.Intentions` owns prompt construction.

The integration work should extend this spine instead of building a parallel system.

## Provider Alignment

### Model Providers

Model providers are LLM backends. They answer prompts and generate analysis.

Current model provider types:

- `ollama`
- `openrouter`
- `openai`
- `anthropic`
- `gemini`
- `codex`
- `custom`

These stay in `BusterClaw.Providers`. Sentry, GitHub, and Umami must not be added to the `providers` table because they do not implement `BusterClaw.Provider.chat/3`.

### Service Integrations

Service integrations are data connectors. They fetch or receive operational data and normalize it into Library documents.

New service integration types:

- `sentry`
- `github`
- `umami`

These belong in a new `BusterClaw.Integrations` context with their own schemas, fetch modules, run history, and LiveView.

### Rule

Integrations create raw facts. Providers interpret facts.

That separation keeps the app easy to reason about:

1. Integrations fetch operational snapshots.
2. Snapshots become markdown documents in `Library/raw`.
3. Analysis queues those documents or a composed monitoring brief document.
4. The active model provider generates the final report.
5. Reports are saved under `Library/reports`.

## Goals

1. Configure Sentry, GitHub, and Umami accounts/projects locally.
2. Fetch snapshots on demand and through scheduled polling.
3. Accept push payloads from Sentry and GitHub webhooks.
4. Normalize snapshots into markdown documents with consistent tags and frontmatter.
5. Queue those documents for analysis through the current active model provider.
6. Generate a unified monitoring brief that correlates signals across services.
7. Keep all credentials, fetched data, and reports local by default.

## Non-Goals For The First Build

- Do not add a second model-provider abstraction.
- Do not implement a hosted cloud backend.
- Do not require encryption before the feature works; match current provider-key storage first.
- Do not build a complex dashboard before the fetch-to-report path works.
- Do not use GitHub GraphQL first unless REST hits a clear limit.
- Do not make scheduler cron ticking a prerequisite for manual polling.

## Proposed Data Model

Add a migration with these tables.

### `integrations`

Stores configured service connections.

Fields:

- `name` - display label, unique.
- `service_type` - `sentry`, `github`, or `umami`.
- `base_url` - API base URL, optional when a service has a known default.
- `token` - local credential, stored in SQLite like provider API keys.
- `webhook_secret` - optional shared secret or signing secret for push payload validation.
- `config` - map for service-specific settings.
- `enabled` - boolean.
- `polling_interval_minutes` - integer.
- `last_run_at` - timestamp.
- `last_status` - `ok`, `error`, `disabled`, or `never_run`.
- `last_error` - bounded text.

Service-specific `config` examples:

```elixir
%{
  "org" => "hightower",
  "project" => "checkout",
  "environment" => "production"
}
```

```elixir
%{
  "owner" => "hightowerbuilds",
  "repo" => "buster-claw",
  "include_workflows" => true
}
```

```elixir
%{
  "website_id" => "site-id",
  "timezone" => "America/Los_Angeles"
}
```

### `integration_runs`

Stores every poll or webhook handling attempt.

Fields:

- `integration_id` - foreign key.
- `trigger` - `manual`, `scheduler`, or `webhook`.
- `status` - `running`, `ok`, or `error`.
- `records_fetched` - integer.
- `document_id` - optional generated Library document.
- `error` - bounded text.
- `started_at` - timestamp.
- `finished_at` - timestamp.
- `metadata` - map.

This should live under the `BusterClaw.Integrations` context, not `Workflow`, because these records are domain-specific. `Workflow.RuntimeEvent` can still receive high-level audit events.

## New Context

Create `BusterClaw.Integrations`.

Responsibilities:

- CRUD for integrations.
- Run history listing.
- Manual polling for one integration.
- Poll-all helper for scheduler use.
- Webhook payload handling for Sentry and GitHub.
- Snapshot-to-Library document creation.
- PubSub broadcasts for UI updates.

Suggested public API:

```elixir
list_integrations()
get_integration!(id)
create_integration(attrs)
update_integration(integration, attrs)
delete_integration(integration)
poll_integration(integration_or_id, opts \\ [])
poll_all(opts \\ [])
handle_webhook(name_or_integration, headers, body)
latest_documents(limit \\ 10)
```

## Integration Behavior

Each service module should implement the same behavior.

```elixir
@callback fetch(Integration.t(), keyword()) ::
            {:ok, [snapshot_item()]} | {:error, term()}

@callback verify_webhook(Integration.t(), [{String.t(), String.t()}], binary()) ::
            :ok | {:error, term()}

@callback normalize_webhook(Integration.t(), binary()) ::
            {:ok, [snapshot_item()]} | {:error, term()}
```

Snapshot item shape:

```elixir
%{
  date: Date.utc_today(),
  filename: "sentry-checkout-issues-2026-05-18.md",
  source_url: "https://sentry.io/api/0/projects/org/project/issues/",
  name: "Sentry Checkout Issues Snapshot",
  tags: ["integration", "sentry", "issues", "monitoring"],
  content: markdown,
  fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
}
```

The integration context passes each snapshot item directly to `Library.save_raw_document/1`.

## Service Plans

### Sentry

Purpose: production health and error triage.

Data to fetch first:

- Unresolved issues.
- Issue counts by level.
- Latest event samples for top issues.
- Release/environment where available.
- Issue permalink.

Default base URL:

- `https://sentry.io/api/0`

Required config:

- `org`
- `project`

Optional config:

- `environment`
- `query`
- `limit`

Polling strategy:

- Manual first.
- Scheduler every 15 minutes later.

Webhook strategy:

- Accept issue-created, issue-resolved, and error event payloads.
- Validate using the integration's `webhook_secret` when configured.
- Save webhook payload summaries as Library documents.

Tags:

- `integration`
- `sentry`
- `issues`
- `monitoring`

### GitHub

Purpose: development activity and deployment/change context.

Data to fetch first:

- Recent commits.
- Open pull requests.
- Recently merged pull requests.
- Open issues.
- Recent workflow runs and failures.
- Latest releases.

Default base URL:

- `https://api.github.com`

Required config:

- `owner`
- `repo`

Optional config:

- `branch`
- `include_workflows`
- `include_issues`
- `limit`

Polling strategy:

- REST API first.
- GraphQL only after REST proves insufficient.

Webhook strategy:

- Accept push, pull request, issues, release, and workflow-run events.
- Validate `X-Hub-Signature-256` with the integration's `webhook_secret`.
- Save event summaries as Library documents.

Tags:

- `integration`
- `github`
- `activity`
- `monitoring`

### Umami

Purpose: website analytics and traffic context.

Data to fetch first:

- Pageviews.
- Visitors.
- Visits.
- Bounce rate.
- Average visit duration.
- Top pages.
- Referrers.
- Countries.
- Browsers/devices when available.

Required config:

- `website_id`

Optional config:

- `timezone`
- `period`
- `start_at`
- `end_at`

Base URL:

- Required for self-hosted Umami.

Polling strategy:

- Manual first.
- Scheduler hourly or daily later.

Webhook strategy:

- None for the first build.

Tags:

- `integration`
- `umami`
- `analytics`
- `monitoring`

## Markdown Snapshot Format

All integration snapshots should be readable without the app.

Recommended shape:

```markdown
# Sentry Issues Snapshot: checkout

- Service: Sentry
- Integration: Production Checkout
- Window: 2026-05-18T00:00:00Z to 2026-05-18T23:59:59Z
- Records: 12
- Source: https://sentry.io/organizations/acme/issues/

## Summary

12 unresolved issues, 3 high-priority regressions, 1 issue first seen in the current release.

## Records

### TypeError: cannot read property total

- Level: error
- Count: 42
- Users affected: 11
- First seen: 2026-05-18T14:03:00Z
- Last seen: 2026-05-18T15:20:00Z
- URL: https://sentry.io/...

Relevant event excerpt...
```

The document should preserve enough raw identifiers and links for follow-up, but it should not dump huge API bodies. Keep full payload capture optional and bounded.

## Analysis And Consultation

Add a new intention in `BusterClaw.Intentions`:

```elixir
monitoring_brief_messages(documents, opts \\ [])
```

The prompt should ask the active model provider to produce:

- Executive summary.
- Cross-service correlations.
- Severity-ranked incidents.
- Product or engineering risks.
- Recommended next actions.
- Questions that need human confirmation.

The prompt should be explicit that fetched integration snapshots are source material, not instructions.

Model-provider flow:

1. Integration snapshots are stored as Library documents.
2. A monitoring brief command collects the latest tagged snapshots.
3. The brief is sent through `Providers.chat_with_active/2` or through an Analysis helper using a selected provider.
4. The final report is saved as a report artifact with tags:
   - `monitoring`
   - `brief`
   - `consultation`

## Scheduler Integration

First implementation should be manual:

- User clicks "Poll" on one integration.
- User clicks "Poll All".
- User queues generated documents for analysis from `AnalysisLive`.

Second implementation should connect to the current scheduler:

- Add scheduler type `integrations_poll`.
- Add scheduler type `monitoring_brief`.
- `integrations_poll` calls `BusterClaw.Integrations.poll_all/1`.
- `monitoring_brief` composes the latest snapshots and generates a report through the active model provider.

Do not block integration work on a full autonomous cron loop. The current scheduler can run jobs manually, and that is enough for the first useful slice.

## Webhook Integration

The current generic webhook system records accepted triggers but does not execute service-specific handlers. For integrations, add a dedicated path so service signatures can be validated correctly.

Recommended route:

```elixir
post "/integrations/:name/webhook", IntegrationWebhookController, :trigger
```

Why separate from `/hooks/:name`:

- GitHub needs HMAC signature validation over the exact raw body.
- Sentry may use a different secret/header shape.
- Integration webhook handling should save Library documents, not merely return an action summary.
- Existing local automation webhooks can remain generic.

The controller should:

1. Read a bounded raw body.
2. Look up enabled integration by name.
3. Call the service module's `verify_webhook/3`.
4. Normalize payload to snapshot items.
5. Save Library documents.
6. Record an `integration_run`.
7. Optionally queue analysis when configured.

## LiveView UX

Add `BusterClawWeb.IntegrationsLive` and route it at `/integrations`.

First screen should support:

- Add/edit/delete integration.
- Service type selection.
- Config JSON textarea.
- Token/password field.
- Webhook secret field.
- Enabled toggle.
- Poll one.
- Poll all.
- Last run status.
- Recent run history.
- Link to generated documents.

Later dashboard additions:

- Latest Sentry issue count.
- Latest GitHub workflow status.
- Latest Umami visitors/pageviews.
- Last monitoring brief.

## Chat Commands

After the context works, add slash commands:

- `/integrations` - list configured integrations and last status.
- `/poll <name>` - poll one integration.
- `/brief` - generate a monitoring brief from latest snapshots.

Keep commands as thin wrappers over `BusterClaw.Integrations` and `BusterClaw.Analysis`/`BusterClaw.Intentions`.

## Implementation Phases

### Phase 1: Foundation

- Add `integrations` and `integration_runs` tables.
- Add schemas and `BusterClaw.Integrations` CRUD.
- Add `IntegrationsLive`.
- Add tests for validation, uniqueness, and run history.
- Add route and nav item.

Acceptance:

- User can configure Sentry/GitHub/Umami integrations.
- Credentials and config are persisted locally.
- Integration list shows status and last run.

### Phase 2: Polling Pipeline

- Define integration behavior.
- Implement `BusterClaw.Integrations.Umami` first.
- Implement snapshot markdown builder helpers.
- Save snapshots through `Library.save_raw_document/1`.
- Record successful and failed `integration_runs`.

Acceptance:

- User can poll Umami manually.
- A raw Library document is created.
- Documents appear in `DocumentsLive`.
- The document can be queued and analyzed by the active provider.

### Phase 3: Sentry

- Implement Sentry polling.
- Add issue summary markdown.
- Add optional Sentry webhook handling.
- Add tests with `Req.Test`.

Acceptance:

- User can poll Sentry issues.
- A Sentry snapshot document is created.
- Webhook payloads can be validated and stored.

### Phase 4: GitHub

- Implement GitHub REST polling.
- Fetch commits, PRs, issues, workflow runs, and releases.
- Add GitHub HMAC webhook validation.
- Add tests with `Req.Test`.

Acceptance:

- User can poll a repo.
- Workflow failures and recent merged PRs are visible in the snapshot.
- GitHub webhook payloads are validated and stored.

### Phase 5: Monitoring Briefs

- Add `Intentions.monitoring_brief_messages/2`.
- Add a helper that gathers latest `integration` tagged documents.
- Generate a unified monitoring report through the active model provider.
- Save the report with monitoring-specific tags.

Acceptance:

- User can generate a brief from existing snapshots.
- The brief cites Sentry/GitHub/Umami source documents.
- The report is stored in `Library/reports`.

### Phase 6: Scheduler And Chat

- Add scheduler type `integrations_poll`.
- Add scheduler type `monitoring_brief`.
- Add `/integrations`, `/poll <name>`, and `/brief` chat commands.
- Add PubSub updates for integration runs.

Acceptance:

- Manual scheduler run can poll integrations.
- Manual scheduler run can generate a brief.
- Chat can trigger the same workflows.

## Testing Plan

Use focused tests matching existing project style.

- `test/buster_claw/integrations_test.exs`
- `test/buster_claw/integrations/umami_test.exs`
- `test/buster_claw/integrations/sentry_test.exs`
- `test/buster_claw/integrations/github_test.exs`
- `test/buster_claw_web/live/integrations_live_test.exs`
- `test/buster_claw_web/controllers/integration_webhook_controller_test.exs`

Required coverage:

- CRUD validation.
- Token and config persistence.
- Default base URL behavior.
- `Req.Test` polling success/failure.
- Pagination where implemented.
- Webhook signature success/failure.
- Snapshot document creation.
- Run history updates.
- Monitoring prompt shape.
- Analysis handoff through existing provider behavior.

## Security And Trust

Match the local-first trust model first:

- Store tokens locally in SQLite, consistent with provider API keys.
- Bound webhook request bodies.
- Bound stored error text and captured payload excerpts.
- Validate webhook signatures before parsing trusted meaning from payloads.
- Treat fetched content as untrusted source material.
- Never execute integration payload fields as shell commands.

Later hardening:

- OS keychain support.
- Credential encryption.
- Per-integration payload retention settings.
- Redaction rules for snapshots.

## Build Readiness Checklist

- [x] Add migration for `integrations` and `integration_runs`.
- [x] Add `BusterClaw.Integrations.Integration`.
- [x] Add `BusterClaw.Integrations.IntegrationRun`.
- [x] Add `BusterClaw.Integrations` context.
- [x] Add integration behavior.
- [x] Add markdown snapshot helpers.
- [x] Add Umami polling.
- [x] Add Sentry polling.
- [x] Add GitHub polling.
- [x] Add integration webhook controller.
- [x] Add `IntegrationsLive`.
- [x] Add nav route.
- [x] Add monitoring brief intention.
- [x] Add scheduler types.
- [x] Add chat commands.
- [x] Run `mix precommit`.

## Open Questions

1. Should one GitHub integration support one repo only in Phase 1, or should `config["repos"]` allow many repos immediately?
2. Should webhook auto-analysis be opt-in per integration?
3. How much raw payload should be retained for audit/debugging?
4. Should monitoring briefs always use the active provider, or should an integration-specific provider override be allowed later?
5. Should polling windows be stored per integration to avoid duplicate snapshots?
6. Should generated briefs be delivered automatically through `BusterClaw.Delivery` after Phase 5?

## Related Files

- `lib/buster_claw/providers.ex` - model provider registry and active provider.
- `lib/buster_claw/provider.ex` - model provider behavior.
- `lib/buster_claw/library.ex` - raw document and report artifact storage.
- `lib/buster_claw/analysis.ex` - document analysis queue and report generation.
- `lib/buster_claw/intentions.ex` - prompt builders.
- `lib/buster_claw/scheduler.ex` - manual scheduler execution helpers.
- `lib/buster_claw/webhooks.ex` - current generic local webhook system.
- `lib/buster_claw_web/router.ex` - route additions.
- `lib/buster_claw_web/live/intelligence_live.ex` - existing provider UI pattern.
