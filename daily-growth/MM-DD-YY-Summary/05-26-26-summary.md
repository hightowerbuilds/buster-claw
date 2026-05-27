# 05-26-2026 Summary

## Today

### Roadmap consolidation and cutover focus

- Reviewed the Phoenix/Tauri rewrite against the dated roadmaps and created
  `daily-growth/roadmaps/master-roadmap.md` as the active source of truth.
- Archived older roadmap files under `daily-growth/old-maps/`.
- Added `daily-growth/roadmaps/Leftovers.md` for explicitly deferred work so the
  master roadmap stays focused on cutover and daily-use hardening.
- Deferred:
  - Supervised Playwright browser sidecar.
  - Real external provider credential smoke testing.
  - MCP SSE/streaming and external MCP `tools/call` routing.
  - CLI install helper, token rotation UI, provider tool adapters, Gmail, and
    packaging/distribution follow-ups.

### Source completeness and legacy imports

- Restored missing Library source modules:
  - `BusterClaw.Library.Document`
  - `BusterClaw.Library.Report`
  - `BusterClaw.Library.Artifact`
  - `BusterClaw.Library.Frontmatter`
- Expanded legacy migration coverage for automation JSON and report manifest
  imports: `mcp.json`, hooks, webhooks, delivery, scheduler, and reports.

### Scheduler hardening

- Added autonomous scheduler ticking and cron-based `next_run_at` advancement.
- Added cron validation and due-job execution coverage.
- Replaced intended scheduler placeholders:
  - `analyze` now queues fetched documents and drains pending analysis jobs.
  - `full` now runs ingest and then analysis.
  - `digest` now generates a monitoring brief.
- Kept `custom` scheduler jobs recorded-only by design.

### Post-report side effects

- Wired analysis/report completion to run post-report side effects:
  - hook events for `post_analysis` and `post_report`
  - delivery dispatch attempts linked to the generated report
- Side effects are nonfatal so report generation remains durable if a webhook or
  delivery endpoint fails.

### MCP runtime

- Added supervised MCP stdio client support:
  - Port-backed process launch.
  - startup `initialize` request.
  - `notifications/initialized`.
  - `tools/list` discovery.
  - visible unavailable status on startup failure.
- Added MCP registry/supervisor/bootstrap to the application supervision tree.
- Added command-surface entries:
  - `mcp_server_connect`
  - `mcp_server_tools`
- Added a Connect button to the MCP LiveView.

### Browser ingestion decision

- Tested sample ingestion sources:
  - RSS sample worked.
  - Static/server-rendered page worked.
  - JS-heavy app/social pages returned 403, app shells, titles only, or error
    shells.
- Decision: defer Playwright sidecar. Current HTTP fallback is acceptable for
  RSS/static/server-rendered sources during cutover.

### CLI and Codex loopback smoke

- Tried the CLI path with a Codex provider pointed at a local OpenAI Responses
  API loopback mock.
- Found and fixed a CLI transport bug: the escript used `:httpc`, which crashed
  on local CA discovery before reaching the loopback HTTP server.
- Updated `BusterClaw.CLI` to use `Req`.
- Rebuilt `./buster-claw`.
- Verified through the CLI:
  - `provider_create` for a temporary `codex` provider.
  - `provider_test` returned `"connected"`.
  - `provider_set_active` selected the temporary Codex provider.
  - `chat_send` and `chat_messages` returned an assistant reply through the
    Codex loopback.
- Cleaned up:
  - stopped the temporary Codex mock server on `127.0.0.1:4059`
  - deleted the temporary Codex provider
  - restored the previous active loopback provider

### Tauri / desktop runtime

- Opened the Tauri desktop window with `cargo tauri dev`.
- Confirmed Phoenix remains reachable on `127.0.0.1:4000`.
- Current session state at summary time:
  - Phoenix dev server is listening on `127.0.0.1:4000`.
  - Tauri dev process is still running.

### Advanced navigation consolidation

- Changed the sidebar so Delivery, Hooks, Webhooks, Integrations, and MCP are no
  longer top-level sidebar entries.
- Kept those advanced surfaces routable for direct links and tests.
- Changed `/advanced` to open the Delivery advanced surface by default.
- Added a shared Advanced tab row across Delivery, Hooks, Webhooks,
  Integrations, and MCP so users move between those sections inside the main
  content area.
- Updated LiveView route tests to verify the hidden sidebar links and shared
  Advanced tabs.

### Packaged release cutover smoke

- Built the packaged desktop release with `./scripts/build_desktop.sh`.
- Produced:
  - `desktop/tauri/target/release/bundle/macos/Buster Claw.app`
  - `desktop/tauri/target/release/bundle/dmg/Buster Claw_0.1.0_x64.dmg`
- Ran the bundled release binary from inside the `.app` against an isolated temp
  data directory with a loopback OpenAI-compatible provider.
- Imported the available real legacy input:
  - 11 sources from repo-local `sources.json`
- Caveat: no full legacy `Library/` corpus was present in this checkout or the
  common searched local project/user-data locations, so historical raw/report
  artifact import could not be validated against user data in this pass.
- Verified through the packaged release:
  - release migrations and startup
  - health endpoint
  - HTTP API, CLI, and MCP command surface
  - provider create/test/activate with loopback provider
  - chat send/messages
  - document save/read path
  - analysis queue/run/report generation
  - RSS source ingestion from imported Hacker News source, writing 20 raw docs
  - memory, calendar, scheduler, webhook, hook, and delivery records
  - restart persistence against the same SQLite database and Library root
- Updated `docs/rewrite/CUTOVER.md` to mark the app ready for a packaged local
  daily-use trial.

### Google Workspace foundation

- Started the Gmail / Google Workspace build-out after cutover smoke completed.
- Added `google_accounts` storage for Google account email, OAuth client ID,
  encrypted client secret, encrypted refresh/access tokens, scopes, sync cursors,
  and enabled state.
- Added `BusterClaw.Google.Vault` for AES-256-GCM credential encryption keyed
  from the app secret key base.
- Added `BusterClaw.Google.Account` and `BusterClaw.Google` context APIs for
  account CRUD, safe summaries, and PubSub change broadcasts.
- Added command-surface entries:
  - `google_account_list`
  - `google_account_get`
  - `google_account_create`
  - `google_account_update`
  - `google_account_delete`
- Updated `docs/rewrite/COMMAND_SURFACE.md`, `master-roadmap.md`, and
  `Leftovers.md` to reflect the completed Google account foundation.

### GWS connection flow

- Added Google OAuth helpers for desktop authorization URLs and token exchange.
- Added `/google/oauth/callback` to finish Google authorization and persist
  encrypted access/refresh tokens.
- Added a simple Home-page GWS connection form for email, OAuth client ID, and
  OAuth client secret.
- Added a dedicated `GWS` sidebar tab at `/gws` for account status,
  reconnect/toggle/delete controls, scopes, and token readiness.
- Verified the live connected account state was clean after setup: one connected
  Google account row, no duplicate/stale account rows left to delete.
- Fixed the GWS account delete control so it uses the LiveView event path
  directly.

### Gmail API first pass

- Added `BusterClaw.Google.Client`, a `Req`-based authenticated Gmail HTTP client
  that reads encrypted access tokens and refreshes OAuth tokens when stale or
  rejected by Gmail.
- Added `BusterClaw.Google.Gmail` helpers for:
  - listing labels
  - searching messages with Gmail query syntax and a bounded limit
  - reading a full message and extracting headers plus text/html bodies
- Added command-surface entries:
  - `gmail_label_list`
  - `gmail_search`
  - `gmail_read`
  - `gmail_sync`
- Added Gmail tools to the `GWS` tab so connected accounts can load labels,
  search Gmail, read a selected search result, and sync matching messages into
  the Library from the desktop UI.
- Added query/limit-based Gmail sync into stable raw Library markdown documents:
  `Library/raw/YYYY-MM-DD/gmail-<message-id>.md`.
- Made raw document saves idempotent by artifact path so repeated Gmail syncs
  update the same document instead of creating duplicates.
- Updated Google account sync cursor fields after sync: `last_synced_at` and the
  latest Gmail history ID observed in the synced messages.
- Verified the real connected Gmail account through the local command API with
  `gmail_label_list`.
- Updated `docs/rewrite/COMMAND_SURFACE.md`, `master-roadmap.md`, and
  `Leftovers.md` to reflect labels/search/read and Library sync being complete
  while send and incremental history sync remain pending.

### Google Calendar sync and local date fix

- Added app-local date helper so the Home daily calendar and Calendar page use
  the desktop local date instead of UTC. This fixes the evening issue where the
  app could show tomorrow's events.
- Added Google Calendar API read helper using the same authenticated Google HTTP
  client/token refresh path.
- Added one-way Google Calendar sync into app calendar events:
  - imports events from the selected Google account/calendar
  - upserts rows with stable `google-calendar:<account>:<calendar>:<event>` IDs
  - removes stale previously imported Google events for that account/calendar
  - leaves local calendar items, scheduler/cron items, and manually authored
    events untouched
- Added command-surface entry:
  - `google_calendar_sync`
- Added a Google Calendar sync form/results panel to the `GWS` tab.

### Gmail draft creation

- Extended the shared Google HTTP client with authenticated JSON POST support
  while keeping the same token refresh path used by Gmail and Calendar reads.
- Added `gmail_draft_create`, a restricted command that builds a plain-text MIME
  message, base64url encodes it for Gmail, and creates a Gmail draft without
  sending mail.
- Added header sanitization for draft `to`/`cc`/`bcc`/`subject` fields so
  newline input cannot inject extra MIME headers.
- Added `https://www.googleapis.com/auth/gmail.compose` to the default Google
  OAuth scope set for new/reconnected accounts.
- Made reconnect authorization URLs merge the current default scopes with any
  older persisted scope string, so existing accounts can request compose without
  manually editing their saved scope field.
- Updated `docs/rewrite/COMMAND_SURFACE.md`, `master-roadmap.md`,
  `Leftovers.md`, and the command-surface smoke representative list for
  `gmail_draft_create`.

### Gmail send command

- Added `gmail_send`, a restricted command that uses the same sanitized
  plain-text MIME path as draft creation and posts to Gmail's send endpoint.
- Added an explicit `confirm_send` guard so command callers cannot send mail by
  accidentally invoking the command without a positive confirmation flag.
- Updated command docs, roadmap files, leftovers, and command-surface smoke
  representative coverage for `gmail_send`.

### Incremental GWS sync

- Added Gmail incremental history sync using `users/me/history` and the stored
  `last_seen_history_id` cursor.
- Preserved query/limit Gmail sync while allowing `gmail_sync` callers to pass
  `incremental: true` and optionally `start_history_id`.
- Added bounded Gmail fallback reporting for missing or expired history cursors:
  `full_sync_required: true`.
- Added per-calendar Google Calendar `nextSyncToken` persistence on Google
  accounts through a `calendar_sync_tokens` map.
- Updated Google Calendar sync to reuse stored sync tokens, apply incremental
  event deltas, remove explicit cancelled Google events, and clear invalidated
  tokens when Google returns `410 Gone`.
- Added Calendar pagination handling so all event pages are consumed before a
  new sync token is stored.
- Updated command docs, roadmap files, and leftovers to mark the remaining GWS
  incremental sync work complete.

## Verification

- `mix test test/buster_claw/analysis_test.exs`: 6 tests, 0 failures.
- `mix test test/buster_claw/scheduler_test.exs`: 13 tests, 0 failures.
- `mix test test/buster_claw/mcp_test.exs test/buster_claw/commands_test.exs test/buster_claw_web/live/mcp_live_test.exs`: 27 tests, 0 failures.
- `mix test test/buster_claw_web/live/status_live_test.exs test/buster_claw_web/live/automation_routes_test.exs`: 8 tests, 0 failures.
- `./scripts/smoke_command_surface.sh`: all checks passed against the running
  Phoenix server.
- `./scripts/build_desktop.sh`: built `.app` and `.dmg` successfully.
- Packaged release command-surface smoke against `127.0.0.1:4101`: all checks
  passed.
- `mix test test/buster_claw/ingest/ingest_test.exs test/buster_claw/commands_test.exs test/buster_claw/google_test.exs`: 31 tests, 0 failures.
- `mix test test/buster_claw/google_test.exs test/buster_claw_web/controllers/google_oauth_controller_test.exs test/buster_claw_web/live/status_live_test.exs test/buster_claw_web/live/gws_live_test.exs test/buster_claw_web/live/automation_routes_test.exs`: 20 tests, 0 failures.
- `mix test test/buster_claw/google/gmail_test.exs test/buster_claw/commands_test.exs test/buster_claw_web/live/gws_live_test.exs test/buster_claw/google_test.exs`: 39 tests, 0 failures.
- `mix test test/buster_claw/google/gmail_test.exs test/buster_claw/google/gmail_sync_test.exs test/buster_claw/commands_test.exs test/buster_claw_web/live/gws_live_test.exs test/buster_claw/google_test.exs test/buster_claw/library_artifact_test.exs`: 45 tests, 0 failures.
- `mix test test/buster_claw/google/calendar_sync_test.exs test/buster_claw/commands_test.exs test/buster_claw_web/live/gws_live_test.exs test/buster_claw/calendar_test.exs test/buster_claw_web/live/status_live_test.exs test/buster_claw_web/live/calendar_live_test.exs`: 44 tests, 0 failures.
- `mix test test/buster_claw/google/gmail_test.exs test/buster_claw/commands_test.exs test/buster_claw/google_test.exs`: 44 tests, 0 failures.
- `mix test test/buster_claw/google/gmail_sync_test.exs test/buster_claw/google/calendar_sync_test.exs`: 7 tests, 0 failures.
- `mix test test/buster_claw/google/gmail_sync_test.exs test/buster_claw/google/calendar_sync_test.exs test/buster_claw/commands_test.exs test/buster_claw_web/live/gws_live_test.exs test/buster_claw/google/gmail_test.exs test/buster_claw/google_test.exs`: 57 tests, 0 failures.
- `mix precommit`: final run passed with 244 tests, 0 failures.
- `mix ecto.migrate`: migrations already up.

## Where we left off

- The packaged release cutover smoke is complete against the available real
  legacy source data.
- Real external provider credential testing is deferred.
- Advanced sidebar consolidation is complete.
- Google Workspace account storage and encrypted credential handling are in
  place.
- The Home-page GWS connection flow and dedicated GWS tab are in place.
- Gmail labels/search/read/sync, Gmail draft creation, Gmail send, Google
  Calendar one-way sync, Gmail history sync, and Google Calendar sync-token
  deltas are available through commands. Gmail and Calendar sync are also
  available through the GWS tab.
- The remaining Gmail / Google Workspace roadmap items in `Leftovers.md` are
  complete.
