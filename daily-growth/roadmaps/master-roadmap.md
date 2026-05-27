# Buster Claw Master Roadmap

Assessment date: 2026-05-26

This roadmap replaces the dated build-out roadmaps under `daily-growth/roadmaps/`.
Older planning files are archived in `daily-growth/old-maps/`; durable reference
docs remain under `docs/rewrite/`.

## Current Read

Buster Claw is a local-first Phoenix/LiveView application wrapped by Tauri. The
main product spine is in place: SQLite-backed configuration and workflow state,
markdown artifacts under the local Library root, provider-backed chat and
analysis, integrations, automation surfaces, a command surface, and desktop
packaging.

The immediate priority is not another broad feature pass. Source completeness
has been restored, the local loopback parity smoke has passed, legacy automation
imports are covered, and intended scheduler workflow jobs now run real
orchestration. MCP stdio servers can now launch under supervision and discover
tools. The Playwright browser sidecar is deferred after sample-source testing
showed RSS and static/server-rendered ingestion are enough for the current
cutover. Real external provider credential testing is deferred. The packaged
release now smokes successfully against the available repo-local legacy source
data with a loopback provider. The app is ready for a local daily-use trial;
remaining work should be treated as hardening or future feature build-out unless
a new cutover blocker is discovered.

## Critical Caveat

At roadmap creation, the checkout appeared incomplete. Multiple modules
referenced these Library submodules, but their source files were not present
under `lib/`:

- [x] `BusterClaw.Library.Document`
- [x] `BusterClaw.Library.Report`
- [x] `BusterClaw.Library.Artifact`
- [x] `BusterClaw.Library.Frontmatter`

Current pass: these modules have been restored in `lib/buster_claw/library/`.
Dependencies were installed locally and `mix precommit` now passes. Keep this
caveat in the roadmap as provenance for why source completeness was treated as
the first priority.

## Status By Build-Out

### Phoenix / Tauri Rewrite

Status: packaged local daily-use trial verified.

Implemented:

- [x] Phoenix 1.8 / LiveView app shell, routes, layout, and major UI surfaces.
- [x] Ecto/SQLite migrations for core configuration and workflow state.
- [x] Sources, providers, chat, documents, analysis, search, memory, calendar,
  scheduler, webhooks, hooks, delivery, MCP config, integrations, and runtime
  status contexts.
- [x] Tauri macOS shell that starts a bundled Phoenix release, waits on `/_health`,
  stores data under `~/Library/Application Support/BusterClaw/`, and shuts the
  release down on app exit.
- [x] Broad tests for contexts, controllers, LiveViews, integrations, provider
  clients, command dispatch, and workflow behavior.

Completed:

- [x] Run the local manual parity smoke test against persisted local data with a
  loopback OpenAI-compatible provider.
- [x] Finish legacy imports for automation JSON files: `mcp.json`, hooks, webhooks,
  delivery, scheduler, and report manifest.
- [x] Add autonomous scheduler ticking and cron-based `next_run_at` advancement.
- [x] Wire post-report side effects: hook events and delivery dispatch after
  analysis/report generation.
- [x] Replace scheduler placeholders for `analyze`, `full`, and `digest` with
  workflow orchestration.
- [x] Implement MCP stdio supervision and `tools/list` discovery for configured
  local MCP servers.
- [x] Smoke a packaged release against available real legacy source data with a
  loopback OpenAI-compatible provider.

Deferred:

- [ ] Supervised Playwright browser sidecar. See `daily-growth/roadmaps/Leftovers.md`.

### Command Surface

Status: largely implemented, with spec drift from the original roadmap.

Implemented:

- [x] `BusterClaw.Commands` is the canonical command surface.
- [x] HTTP API:
  - [x] `GET /api/commands`
  - [x] authenticated `POST /api/run`
- [x] CLI escript via `BusterClaw.CLI`.
- [x] MCP-compatible JSON-RPC endpoint at authenticated `POST /mcp`.
- [x] Configured local MCP stdio servers can launch and discover tools.
- [x] Command catalog is documented in `docs/rewrite/COMMAND_SURFACE.md`.
- [x] Internal Anthropic agent path exposes safe-tier commands as tools.
- [x] Smoke script exists at `scripts/smoke_command_surface.sh`.

Known drift / remaining work:

- [ ] The old roadmap described MCP over SSE; the implemented endpoint uses the
  Streamable HTTP JSON-response form at `POST /mcp`.
- [ ] CLI module naming differs from the old plan (`BusterClaw.CLI`, not
  `BusterClaw.CLI.Main`).
- [ ] Internal tool calling is Anthropic-only. OpenAI, Gemini, and Codex provider
  tool adapters are still planned.
- [ ] MCP streaming responses are not implemented.
- [x] Command count assertions in `test/buster_claw/commands_test.exs` and
  `scripts/smoke_command_surface.sh` now use representative-command assertions
  so new commands do not create noisy test churn.
- [ ] CLI installation/symlink flow is still deferred.

### Quality Refactor

Status: mostly landed.

Implemented:

- [x] `BusterClawWeb.ErrorFormatter` exists and is used by API/MCP/frontend error
  paths.
- [x] `BusterClaw.ApiToken` now persists token files with tightened POSIX modes and
  has direct tests.
- [x] StatusLive active-provider flow uses the provider context path.
- [x] `BusterClaw.Commands` already uses macro-style CRUD generation for repeated
  resource wrappers.
- [x] API/MCP controller tests use representative command assertions.
- [x] Command tests and command-surface smoke checks use representative command
  assertions instead of catalog counts.
- [x] Webhook and integration webhook tests cover more unhappy paths.
- [x] Provider behavior was renamed to `BusterClaw.Providers.Backend`.

Still needed:

- [ ] Audit remaining `inspect(reason)` paths. Some are operational/audit fields and
  may be acceptable, but user-facing chat replies and scheduler-visible errors
  should be reviewed for redaction.
- [ ] Keep the full precommit suite green as follow-up cleanup lands.

### Sentry / GitHub / Umami Integrations

Status: implemented to the planned useful slice.

Implemented:

- [x] `integrations` and `integration_runs` tables.
- [x] `BusterClaw.Integrations` context.
- [x] Service behavior and adapters for Umami, Sentry, and GitHub.
- [x] Snapshot markdown helper.
- [x] Poll-one and poll-all paths.
- [x] Integration webhook controller with service-specific signature validation.
- [x] `IntegrationsLive` management UI.
- [x] Monitoring brief prompt and report generation path.
- [x] Scheduler types for `integrations_poll` and `monitoring_brief`.
- [x] Chat commands for `/integrations`, `/poll`, and `/brief`.
- [x] Tests for CRUD, polling, webhook handling, snapshots, scheduler integration,
  and monitoring briefs.

Still needed:

- [ ] Manual smoke with real Sentry, GitHub, and Umami credentials.
- [ ] Decide whether integration webhook events should auto-queue analysis.
- [ ] Decide retention policy for raw webhook payload excerpts.
- [ ] Decide whether monitoring briefs should allow provider overrides.
- [ ] Add polling-window/dedup controls if repeated snapshots become noisy.
- [ ] Optionally dispatch generated monitoring briefs through Delivery.

### Gmail / Google Workspace

Status: account connection, Gmail read tools, and first Library sync implemented.

Implemented:

- [x] `BusterClaw.Google` context family with account CRUD.
- [x] Encrypted credential storage for Google account client secrets and OAuth
  tokens.
- [x] Google account command surface:
  `google_account_list`, `google_account_get`, `google_account_create`,
  `google_account_update`, and `google_account_delete`.
- [x] Safe account summaries that expose credential presence flags without
  returning plaintext secrets or tokens.
- [x] BYO Google OAuth desktop credentials.
- [x] Loopback OAuth callback route for Google authorization.
- [x] Simple Home-page GWS connection form.
- [x] Dedicated `GWS` app tab for account management and authorization status.
- [x] Gmail HTTP client using `Req`, connected-account access tokens, and OAuth
  refresh on stale/401 tokens.
- [x] Gmail label/search/read command surface:
  `gmail_label_list`, `gmail_search`, and `gmail_read`.
- [x] GWS tab Gmail tools for loading labels, searching messages, and reading a
  selected result.
- [x] Gmail sync command and GWS tab action that save Gmail messages into stable
  `Library/raw/YYYY-MM-DD/gmail-<message-id>.md` documents.
- [x] Google account sync cursor update for `last_synced_at` and latest Gmail
  history ID seen during sync.
- [x] Real connected-account Gmail label smoke through the local command API.

Planned direction:

- [ ] Gmail draft/send commands.
- [ ] Incremental Gmail history sync beyond query/limit-based pulls.

Next decision before implementation:

- [x] Do not start Gmail until the existing app passes a real local smoke test.
- [x] Reconfirm encrypted-secret design, because it is broader than Gmail and may
  eventually cover provider keys and integration tokens.

## Active Priority Order

Completed in the first implementation pass:

- [x] Restored the missing Library source modules.
- [x] Installed dependencies locally and ran `mix precommit` successfully.

Next:

1. [x] Update stale assertions in command tests and smoke script.
2. [x] Run a real local manual smoke:
   - [x] start app
   - [x] configure provider
   - [x] add source
   - [x] ingest source
   - [x] inspect raw document
   - [x] queue and run analysis
   - [x] inspect report
   - [x] test memory and chat
   - [x] test search and browser fetch
   - [x] create calendar event
   - [x] add/run scheduler job
   - [x] add/trigger webhook
   - [x] add/test delivery destination
   - [x] add/test hook
   - [x] restart and confirm state survives
3. [x] Close cutover blockers in `docs/rewrite/CUTOVER.md`.
   - [x] Audit `docs/rewrite/CUTOVER.md` against the current implementation.
   - [x] Expand legacy migration coverage for automation JSON and report manifest
     files.
   - [x] Add autonomous scheduler ticking and real cron handling.
   - [x] Replace intended scheduler placeholders with real workflow orchestration.
   - [x] Wire post-report hook events and delivery dispatch after report generation.
   - [x] Defer the browser sidecar path until real required sources need rendered
     ingestion.
   - [x] Implement MCP stdio supervision and tool discovery.
   - [x] Defer real external provider credential smoke testing.
   - [x] Smoke a packaged release against available real legacy source data with a
     local or loopback provider.
     - Built the macOS `.app` and `.dmg`.
     - Imported 11 sources from repo-local legacy `sources.json`.
     - Verified packaged release startup, migrations, command surface, CLI, MCP,
       provider test, chat, analysis/report generation, source ingestion, memory,
       calendar, scheduler, webhook, hook, delivery, and restart persistence in an
       isolated temp data directory.
     - Caveat: no full legacy `Library/` corpus was present locally, so raw/report
       legacy artifact import could not be validated against user historical
       artifacts in this pass.
4. [x] Decide whether the next feature is Gmail or hardening of existing automation.
   - Started Gmail / Google Workspace with the account storage, encrypted
     credential vault, and command-surface foundation.
5. [x] Implement the Gmail API client layer and first read/search paths.
6. [x] Implement Gmail sync into Library documents.
7. [ ] Decide whether Gmail draft/send or incremental history sync is the next
   Google Workspace slice.

## Deferred Work

Deferred and future work has moved to `daily-growth/roadmaps/Leftovers.md`.

## Archived Planning Sources

The following roadmap files were consolidated into this master roadmap:

- [x] `05-07-26-elixir-rewrite-roadmap.md`
- [x] `05-17-26-command-surface-roadmap.md`
- [x] `05-17-26-gmail-integration-roadmap.md`
- [x] `05-17-26-quality-refactor-roadmap.md`
- [x] `INTEGRATION_PLAN.md`

Keep `docs/rewrite/*` as current reference documentation until each document is
explicitly superseded.
