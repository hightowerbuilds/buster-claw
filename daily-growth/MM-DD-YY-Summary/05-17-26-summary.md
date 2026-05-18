# 05-17-2026 Summary

## Today

- Added a Models panel to the home page (`/`) in `BusterClawWeb.StatusLive` so users can add, list, delete, and activate AI provider API keys without leaving the dashboard.
- Wired the active-key `<select>` to a `phx-change="activate_provider"` event that updates `Providers.set_active_provider/1` and broadcasts a flash note.
- Auto-generated provider names from the type label (e.g., "Anthropic (Claude)"), with collision-aware suffixes; first added key auto-promotes to active.
- Wired Anthropic, Google Gemini, OpenAI Codex (Responses API), OpenAI (Chat Completions), OpenRouter, Ollama, and Custom OpenAI-compatible into the same form, with per-type API key placeholders and default model strings.
- Switched the Add-key form from bespoke `<input>` markup to the conventional `<.input>` components so changeset errors render inline below each field.
- Tightened the `BusterClaw.Providers.Providers.Provider` changeset with `maybe_require_api_key/1` — `api_key` is now required for every provider type except `ollama`, surfacing the failure at save time instead of at first-request time.
- Replaced the `phx-change="type_changed"` handler (which reset the entire form on every keystroke) with a `validate` handler that re-casts the changeset preserving entered values when the type stays the same, and only resets defaults when the user picks a different provider type.
- Bumped `BusterClaw.Provider.Anthropic` `max_tokens` from 1024 to 8192 to match current Claude usage.
- Updated `IntelligenceLive` and `StatusLive` type dropdowns to a consistent label order (Anthropic, Gemini, Codex, OpenAI, OpenRouter, Ollama, Custom).
- Added stub Codex and Gemini provider modules plus default base URLs (`https://api.openai.com/v1` and `https://generativelanguage.googleapis.com/v1beta`) in `BusterClaw.Providers.put_default_base_url/2`.
- Fixed four pre-existing tests that created non-Ollama providers without an API key (`providers_client_test.exs`, `analysis_test.exs`, `analysis_live_test.exs`).
- Reset a stale test database with orphaned `buster_claw_test 2.db-shm`/`.db-wal` files that blocked migrations from applying cleanly.
- Reworked the Tauri dev workflow in `desktop/tauri/src/main.rs` — debug builds now skip the bundled-release child-process spawn entirely and point the webview at `http://127.0.0.1:4000`, expecting `mix phx.server` to run externally. Release builds remain unchanged.
- Cleaned three stale release trees (`_build/prod/rel/buster_claw/`, `desktop/tauri/resources/release/`, `desktop/tauri/target/debug/release/`) and replaced `resources/release/` with a tracked `.gitkeep` placeholder so Tauri's build.rs `rerun-if-changed` walker stays happy in dev mode.
- Updated `desktop/tauri/.gitignore` to track `.gitkeep` while ignoring real release contents, and updated `scripts/build_desktop.sh` to restore the placeholder after a production bundle build so the dev loop keeps working.

## Verification

- Ran `mix compile --warnings-as-errors`: clean.
- Ran `mix test`: 82 tests, 0 failures (after fixing the four api_key-missing tests).
- Ran `mix format --check-formatted`: clean.
- Ran `cargo check` in `desktop/tauri`: clean.
- Curled `http://127.0.0.1:4000/` and confirmed the Models heading, API key input, and `sk-ant-...` placeholder render in the served HTML.
- Confirmed `mix phx.server` (PID 41701) stayed healthy via `GET /_health` → `200`.
- Did NOT manually launch `cargo tauri dev` end-to-end after the main.rs change — that verification was left for the user to run.

## Where we left off

API-key UI is functionally in place on the home page. The natural next item on this build-out — paused to ship the command surface build-out — was a **Test-connection button** next to each saved key:

- After saving (or for any existing key), call `Providers.test_provider/1` and surface success/error inline.
- The contract is already proven in `test/buster_claw/providers_client_test.exs` ("routes OpenAI-compatible chat through callback contract" — `Providers.test_provider(provider)` returns `{:ok, "connected"}`).
- UX questions still open: where the result lives (inline below the row vs. a flash note), whether to test automatically on save, and how to render network failures vs. auth failures distinctly.

Other items noticed but not addressed during this pass:

- API keys are stored plaintext in SQLite (`providers.api_key`). Acceptable for local-first single-user, but worth a future at-rest encryption pass if the threat model changes.
- The OpenRouter type falls through `module_for/1` to `OpenAICompatible`, which is correct but undocumented — a one-line comment in `BusterClaw.Providers` would prevent confusion.
- The `<.input>` component uses daisyUI's default `fieldset`/`label`/`input` styles, which look slightly different from the previous bespoke styling on the home page form. Confirmed in the running app to be coherent, no follow-up needed.

## Command surface build-out (afternoon)

After the home-page UI work, we pivoted to unifying Buster Claw's command vocabulary. Per the roadmap at `daily-growth/roadmaps/05-17-26-command-surface-roadmap.md`, we shipped Phases 0 → 5 in a single session.

**Phase 0 — Catalog** (`docs/rewrite/COMMAND_SURFACE.md`)

- Inventoried every public function across 17 context modules via an Explore subagent.
- Curated to 76 user-facing commands (later 94 once duplicates merged in MCP `tools/list`).
- Named with `<noun>_<verb>` convention so the catalog sorts cleanly when grouped.
- Documented each command with args (JSON-Schema-shaped), return shape, side effects, and an agent allowlist tier (`safe` vs `restricted`).

**Phase 1 — `BusterClaw.Commands` module** (`lib/buster_claw/commands.ex`)

- Single canonical surface that the HTTP API, CLI, MCP server, and internal agent all dispatch through.
- Uniform `{:ok, value} | {:error, reason_or_changeset}` contract; bang getters wrapped to translate raises into `{:error, :not_found}`.
- `call/2` dispatches by string command name; `list_commands/0` returns the catalog with arg schemas attached.
- 21 dedicated tests covering the dispatcher, catalog integrity, and one happy-path test per domain.

**Phase 2 — HTTP API + token auth** (`lib/buster_claw/api_token.ex`, `lib/buster_claw_web/plugs/api_auth.ex`, `lib/buster_claw_web/controllers/api_controller.ex`)

- `BusterClaw.ApiToken` lazy-loads a 32-byte url-safe token from `~/Library/Application Support/BusterClaw/api_token` on first access (auto-generates if missing). Dev/test override via `config :buster_claw, :api_token, "..."` so reload doesn't rotate.
- `BusterClawWeb.ApiAuth` plug checks `Authorization: Bearer <token>` with constant-time comparison.
- Single endpoint shape: `POST /api/run` with `{"command": "<name>", "args": {...}}`. `GET /api/commands` unauthenticated for catalog discovery.
- Error mapping: validation → 422 with field errors, not_found → 404, unauthorized → 401, etc.
- 10 controller tests covering auth, dispatch, error mapping, and struct serialization.

**Phase 3a — CLI escript** (`lib/buster_claw/cli.ex` + `mix.exs` escript config)

- Single binary at `./buster-claw` built via `mix escript.build` (added to `.gitignore`).
- Uses `:httpc` and `:inets` (built-in OTP) instead of Req to keep the binary minimal.
- `app: nil` in escript config prevents auto-starting the Buster Claw application — the CLI is a thin HTTP client, not a Phoenix instance.
- Subcommands: `commands`, `run <name>`, `<noun> <verb>` shorthand. Token resolution: `--token` → `BUSTER_CLAW_API_TOKEN` env → token file. URL via `--url` or `BUSTER_CLAW_URL`.

**Phase 3b — MCP server endpoint** (`lib/buster_claw_web/controllers/mcp_controller.ex`)

- Streamable HTTP transport (JSON-RPC over HTTP, synchronous JSON responses; no SSE for v1). Single endpoint `POST /mcp`.
- Implements `initialize`, `tools/list`, `tools/call`, `ping`, plus correct JSON-RPC error envelopes for unknown methods and parse errors.
- `tools/list` maps each command's args spec to a JSON Schema via `BusterClaw.Commands.Schema.to_json_schema/1` (extracted from the controller and reused by AgentTools).
- `tools/call` invokes `Commands.call/2`, serializes the result via `BusterClaw.Commands.Result.to_json/1` (also extracted as a shared module), and packages it into MCP `content[].type = "text"` blocks.
- 7 controller tests covering auth, initialize, tools/list, tools/call (success + error), unknown methods, notifications.

**Phase 4 — Internal agent tool wiring** (`lib/buster_claw/agent_tools.ex`, modified `lib/buster_claw/provider/anthropic.ex` and `lib/buster_claw/chat/session.ex`)

- `BusterClaw.AgentTools` exposes only `tier: :safe` commands and refuses to execute restricted-tier calls even if the model requests them — defense in depth against prompt injection that tries to widen the model's reach.
- `BusterClaw.Provider.Anthropic.chat_agentic/3` runs the tool-use loop: sends `tools` alongside messages, parses `stop_reason: tool_use` responses, executes each tool call, appends both assistant `tool_use` blocks and user `tool_result` blocks, re-sends. Caps at 6 iterations to prevent runaway recursion.
- `BusterClaw.Providers.agentic_chat_with_active/2` routes to the agentic loop for Anthropic providers; falls back to plain `chat/3` for OpenAI/Gemini/Codex/Ollama (their tool-call adapters are deferred).
- `BusterClaw.Chat.Session.provider_chat/1` switched from `chat_with_active` to `agentic_chat_with_active`, so ChatLive now passes the tool catalog automatically when the user has an Anthropic provider active.
- 2 round-trip tests using `Req.Test.stub` to simulate Anthropic's tool_use → final response flow, including the "refuses restricted-tier tool" path.

**Phase 5 — Docs + smoke tests**

- README `## Driving Buster Claw (CLI, MCP, HTTP)` section with example invocations for each frontend, MCP config snippet for Claude Code.
- `scripts/smoke_command_surface.sh` — end-to-end test against the running phx.server: hits `_health`, `/api/commands`, exercises auth rejection, runs the CLI binary, hits MCP `initialize`/`tools/list`/`tools/call`. All 9 checks pass.
- `docs/rewrite/CUTOVER.md` updated: command surface and internal-agent tool wiring listed as newly ready.

## Verification (afternoon pass)

- `mix compile --warnings-as-errors`: clean.
- `mix test`: 146 tests, 0 failures (up from 121 in the morning).
- `mix escript.build`: clean (5.3 MB `./buster-claw` binary).
- `./scripts/smoke_command_surface.sh`: 9/9 checks pass against the live dev server.
- Manual: curl'd MCP `tools/call` for `runtime_status` and saw the snapshot returned in a `text` content block.

## Notes (afternoon pass)

- Architectural decision worth flagging: HTTP API is "required" because MCP also needs HTTP transport, so adding a few JSON routes alongside MCP is essentially free. Unix-socket alternative considered and rejected for that reason.
- The token defends only against other local users on a shared machine — the Phoenix endpoint binds to `127.0.0.1`, so no remote caller can reach it regardless of token.
- Restricted-tier commands (`*_delete`, `provider_set_active`, `delivery_dispatch_all`, etc.) are exposed via the HTTP API and CLI (which are operating on behalf of an authenticated human/agent) but NOT exposed to MCP or to the chat model's tool catalog (which is the path most likely to be hijacked by prompt injection).
- 94 tools end up in the catalog at the wire level vs. 76 commands in the docs — the difference is property fields named `name` in arg schemas that the smoke-test grep counts as catalog entries. Cosmetic only.

## Notes

- The dev workflow now relies on two terminals: `mix phx.server` for the Phoenix backend (LiveView hot reload + asset watch) and `cd desktop/tauri && cargo tauri dev` for the Tauri Rust shell. Closing and reopening the dev window is cheap; the bundled release is only spawned for production bundles (`scripts/build_desktop.sh`).
- The `.gitkeep` placeholder at `desktop/tauri/resources/release/` is load-bearing — Tauri's build.rs errors with "resource path `resources/release` doesn't exist" if the directory is missing entirely, even though no contents are referenced in dev mode.

## Evening planning (Gmail prep + code review)

Pivoted from execution to planning for two pieces of upcoming work.

**Gmail integration roadmap** (`daily-growth/roadmaps/05-17-26-gmail-integration-roadmap.md`)

- Scoped a Google Workspace integration starting with Gmail. Confirmed there is no separate "Gmail Agent API" — agentic behavior on Gmail comes from how we surface the standard Gmail REST API, not a different endpoint.
- Locked decisions via a 4-question structured planning pass: surface = inbox ingest + agent tool calls; OAuth flow = loopback / Installed App (`http://127.0.0.1:<ephemeral>/oauth/callback`); code location = new `lib/buster_claw/google/` context; OAuth client provisioning = bring-your-own (paste `client_id` + `client_secret`); scopes = `gmail.readonly` + `gmail.compose`; accounts = multi-account; ingest trigger = manual "Sync now" + `gmail.sync` command (so the stubbed scheduler can take over later without rework).
- Roadmap enumerates 7 phases with concrete file layout, `google_accounts` schema (encrypted client_secret/refresh_token/access_token + scopes + default_query + last_seen_history_id), the OAuth orchestration flow (PubSub-driven callback completion), and the full `gmail.*` command surface additions (`gmail.search`, `gmail.read`, `gmail.draft`, `gmail.send`, `gmail.labels`, `gmail.sync`, plus account-management commands).
- Defers attachments, push notifications via `gmail watch` + Pub/Sub, domain-wide delegation, and shared OAuth client (which would require Google verification).

**Code quality review** (3 parallel lenses)

- Ran three parallel Explore agents — architecture/module organization, Elixir idioms, tests + security — across the whole `lib/` and `test/` trees, then verified every concrete claim with a `grep`/`wc` pass before relaying.
- **Net verdict:** foundation is solid for a 6-month-old rewrite. Webhook signature verification is correct (`webhooks.ex:101–115` uses Bitwise XOR constant-time compare). Path traversal is architecturally defended via `library/artifact.ex:safe_join!/2`. `ApiAuth` plug uses `Plug.Crypto.secure_compare/2`. `Analysis.run_job` (`analysis.ex:77–91`) is a textbook idiomatic `with` chain.
- **Five real defects identified** — all small, isolated, fixable in one session:
  1. `inspect(reason)` leaks unknown error terms into HTTP/UI responses at 7 sites (2 controllers, 5 LiveViews). Low exposure today but a real risk once OAuth client secrets start flowing through Req errors.
  2. `lib/buster_claw/api_token.ex:40` writes the loopback token with default umask — likely world-readable on multi-user macOS. Trivial `File.chmod!(path, 0o600)` fix.
  3. `lib/buster_claw_web/live/status_live.ex:113` reaches around the `Providers` context to call `BusterClaw.Repo.update/1` directly, while lines 124 and 448 of the same file use the proper `Providers.set_active_provider/1`.
  4. `lib/buster_claw/commands.ex` has grown to 1,251 lines with ~80 public functions and repetitive CRUD blocks that should be macro-deduped using the same `for` pattern already in `automation.ex` and `workflow.ex`.
  5. Naming triad `Provider` (behaviour) / `Providers` (context) / `Providers.Provider` (schema) is a cognitive tax on every reader. Optional cleanup.
- **Test gaps that matter:** `api_token.ex` has zero direct tests; catalog count assertions in `api_controller_test.exs:60` and `mcp_controller_test.exs:31` ratchet (`>= 70 commands`) with every new command; webhook tests cover happy + wrong-secret only.

**Quality refactor roadmap** (`daily-growth/roadmaps/05-17-26-quality-refactor-roadmap.md`)

- Bundled all five defects + three test gaps into a 7-phase hygiene roadmap. Explicitly positioned as a **prerequisite to Gmail work**: Phase 1 (`inspect(reason)` purge via a shared `ErrorFormatter`) pays for itself the moment OAuth client secrets enter the system.
- Success criteria are objective: `grep "inspect(reason)" lib/buster_claw_web/` returns zero hits; `api_token` file persists at mode `0o600` (verified by test); `commands.ex` drops ≥250 lines; `status_live.ex` no longer references `BusterClaw.Repo`; smoke script still 9/9.
- Estimated as a single focused session; Phases 1–3 are highest-value and should land together, 4–7 are independently sliceable.

## Where we left off (evening)

Two roadmaps queued, no code written this evening. The natural next sessions are:

1. **Execute the quality refactor** (Phases 1–3 minimum) — small, well-scoped, lands cleanups Gmail will lean on.
2. **Then execute the Gmail integration roadmap** Phase 1 (storage + crypto) onward.

The order matters: the `ErrorFormatter` from quality-refactor Phase 1 is what keeps OAuth client secrets from being `inspect/1`'d into HTTP error responses on the very first Gmail dev iteration.

## Late-evening session: home page + calendar overhaul

After the roadmaps were drafted, we shifted to UI polish instead. The full afternoon-into-evening arc:

**Repo push** — committed everything from the morning + afternoon + integrations work as one `e18736a` to `origin/main` (81 files, +9,014 / −179). Pre-existing local commit `db75a7e` (the integrations plan doc) also went up. Added `/priv/static/*-*.{ico,txt}` and `/priv/static/*.gz` gitignore patterns to keep Phoenix digest artifacts out of git. Screenshot dropped in the working tree was left untracked.

**Sidebar layout** (`lib/buster_claw_web/components/layouts.ex`)

- Replaced the top-strip navigation with a 240px left sidebar (`flex min-h-screen` outer, `sticky top-0 h-screen` aside). Nav `<a>` items live in the middle with `flex-1 overflow-y-auto` so they scroll independently when the viewport is short. Branding pinned to the top of the aside, theme toggle pinned to the bottom — both `shrink-0` so they don't compress.
- Then added a sticky top-bar inside `<main>` (`sticky top-0 z-10 bg-base-100/95 backdrop-blur`) holding right-aligned status chips (PubSub, Endpoint, plus an "Agent mode on" pulse chip when active). Every page sees the chip bar.

**Home page slimmed down repeatedly** (`lib/buster_claw_web/live/status_live.ex`)

- Deleted the "Parity Views" and "Supervised Services" containers entirely (data still flows through `Runtime.Status.snapshot/0` for a future docs tab).
- Moved the SQLite Database card off home, onto `/memory` (`MemoryLive` now calls `Status.snapshot/0` and renders a "SQLite Database" card with the same ready/pending pill).
- Moved the Library Root card off home, onto `/documents`.
- Moved PubSub + Endpoint into the global sticky top-bar.
- Deleted the now-unused `status_card/1` private helper from `status_live.ex`.

**Agent mode UI on the home page** (`lib/buster_claw/agent_mode.ex` + the home page tab selector)

- Added `BusterClaw.AgentMode` — an `Agent`-backed boolean flag with PubSub broadcasts on `"agent_mode"` (state changes) and `"agent_activity"` (command invocations). Supervised in `Application`. Defensive `ensure_started/0` lazy-starts the process so the layout doesn't crash on stale dev servers that missed the supervision-tree change.
- `BusterClaw.Commands.call/2` now broadcasts each invocation on `"agent_activity"` when agent mode is on. Off-state → no spam.
- Home page got a 2-tab selector: **"Use an API key"** (existing Models panel) vs. **"Hand off to a terminal agent"** (new). Agent panel shows: "Ready for agent" toggle, success banner when on, full 76-command roster + real-time activity feed (last 25 invocations, each tagged `ok`/`error` with a timestamp).
- End-to-end smoke-tested: flipped the toggle, fired calls from a terminal (`curl POST /api/run`), watched the activity feed light up live. Created two real calendar events through it ("Terminal Agent Demo" on May 17, "Kyle's Bachelor Party" on May 23).

**Calendar redesign — three passes**

*Pass 1: list-view → month grid* (`lib/buster_claw_web/live/calendar_live.ex`)

- Replaced the bulleted list with a proper 7×6 month grid. Sunday-first weekday labels, prev/today/next nav, today highlighted with a filled badge, out-of-month days dimmed. Clicking a day cell pre-fills the form below. Clicking an event tile fires an `edit` event.

*Pass 2: time, colors, detail view + delete affordance*

- Migration `20260518060000_extend_calendar_events.exs`: added `start_time :time`, `end_time :time`, `color :string`. Event changeset validates `end_time > start_time` and restricts `color` to a 7-option enum (`neutral`, `work`, `personal`, `social`, `travel`, `health`, `holiday`).
- Form grew: Date · Title · Start · End · Color (select) · buttons · Notes (full-width textarea below).
- Event chips in the grid now show a time prefix when set (`09:00 Kyle's Bachelor Party`) and use color-themed Tailwind classes pre-listed in `@color_classes` so v4's source scanner keeps them.
- Click-to-edit became click-to-**inspect**: clicking an event chip opens a detail panel (color swatch + title + "Repeats X" pill if recurring + formatted "when" line + notes) with Edit / Delete / Close buttons. Editing still works the same way; Delete fires from either the inspect panel or the form's edit mode.

*Pass 3: week + day views and recurring events*

- Migration `20260518070000_add_recurrence_to_calendar_events.exs`: added `frequency :string` (`daily` / `weekly` / `monthly`) and `recur_until :date`. Changeset validates `recur_until >= date`.
- New `BusterClaw.Calendar.events_in_range/2` expands recurring events into per-occurrence virtual structs (same id, shifted `:date`, inherited attrs). Monthly recurrence uses **anchor-day clamping** — Jan 31 → Feb 28 → Mar 31 → Apr 30 (not Feb 28 → Mar 28). Done by computing the Nth occurrence from the anchor each time instead of iterating with state.
- View toggle in the calendar header: Month / Week / Day. Prev/Next/Today shift by the active view's unit. Each view reuses a common `day_cell` function component for consistency. Week view shows 7 wider columns with day-of-month numbers under each weekday label. Day view is a single column listing the day's events with full time-ranges and a "weekly" / "monthly" tag for recurring instances.
- Form added **Repeat** (select: "Does not repeat" / Daily / Weekly / Monthly) and **Repeat until** (date) inputs.

*Pass 4: drag-to-move*

- Added a `CalendarDrag` LiveView JS hook in `assets/js/app.js`. Listens for HTML5 `dragstart` / `dragover` / `drop` events on the calendar grid. Source elements are event chips marked `draggable="true"` with `data-event-id={event.id}`. Drop targets are day cells with `data-drop-date={Date.to_iso8601(day.date)}`. While dragging, the chip dims to 50% and the target cell gets a `ring-2 ring-base-content` highlight.
- On drop, the hook pushes `move_event {id, date}` to the LiveView. `CalendarLive.handle_event("move_event", ...)` updates the event's date (entire series for recurring events for now), broadcasts a result flash like `Moved "Standup" to Jun 8, 2026.`, and rebuilds the view.
- Event chips also have `cursor-grab` / `active:cursor-grabbing` so the affordance reads as draggable before the user picks it up.

## Verification (late-evening pass)

- `mix compile --warnings-as-errors`: clean throughout (one warning caught and fixed: `@impl true` repeated on grouped `handle_event` clauses; another caught: `prompt={nil}` on `<.input>` — both addressed).
- `mix test`: 153 tests, 0 failures (up from 146 morning; +7 came from the new `calendar_recurrence_test.exs` covering single events, out-of-range exclusion, daily/weekly/monthly expansion, `recur_until` cap, attribute inheritance, monthly-clamp regression).
- Calendar live-page checks via `curl`: month grid, week view, day view, recurrence form fields, drag attributes all render as expected.
- Activity-feed end-to-end: turning agent mode on and firing `event_create` from a terminal reflected in the home-page activity feed in real time with `ok` pills.

## Known gaps after this session

- **Edit semantics for recurring events**: editing/dragging changes the *whole series*. No "edit this one only," no "edit this and following," no per-occurrence exceptions yet. That's the next layer of RRULE-like complexity.
- **Recurrence interval**: no "every 2 weeks" or "every 3 days" — only 1-unit steps. Add `interval :integer` field if needed.
- **Test gap**: the `move_event` handler is exercised live but doesn't have a LiveView test (would require simulating the JS hook's `push_event`). Underlying `Calendar.update_event/2` is already well-covered.
- **Recurring-event drag**: dragging an occurrence currently shifts the parent series anchor — fine for now but surprising once the user thinks of occurrences as independent. Same fix as the edit-semantics question.
