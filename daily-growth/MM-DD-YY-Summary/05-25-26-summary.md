# 05-25-2026 Summary

## Today

### Code-quality review pass

Ran a three-way parallel review of the whole codebase (core lib, tests, web/scripts/config) and produced a prioritized findings list. No code changes yet — review only.

Top items surfaced (kept here as a working punch list):

- **Critical** — Per-turn `Agent.start_link` for stream-chunk collection in three call sites (`lib/buster_claw/chat/session.ex:117`, `lib/buster_claw/analysis.ex:255`, `lib/buster_claw/integrations.ex:391`) leaks processes on early provider errors and races on `Agent.update`.
- **Critical** — `Chat.Session.handle_cast` runs the provider HTTP call inline (`lib/buster_claw/chat/session.ex:34-53`), blocking the GenServer mailbox for the full LLM duration; `/clear` and `messages/1` queue behind it.
- **Critical** — `BusterClaw.AgentMode` is double-supervised (`lib/buster_claw/agent_mode.ex:22-63`); `ensure_started/0` spawns an unlinked second copy and `on?/0` swallows all exits.
- **Critical** — `Hooks.execute_shell/1` has no timeout (`lib/buster_claw/hooks.ex:67-80`); a stuck script blocks the caller forever.
- **Critical** — `secret_key_base` and signing salts committed to git (`config/dev.exs:23`, `config/test.exs:17`, `endpoint.ex:10`, `config.exs:24`); need rotation + move to `runtime.exs`/env.
- **Critical** — Webhook secrets default-allow when blank (`webhooks.ex:46`); combined with `check_origin: false` in dev, any localhost-aware browser tab can POST `/hooks/:name`.
- **Critical** — `AgentTools` (LLM→`Commands.call/2` boundary) has no direct tests; restricted-tier refusal is only covered via a vague `text =~ "healthy"` assertion in `anthropic_agentic_test.exs:61`.
- **High** — Three hand-rolled copies of `secure_compare/2` + HMAC verification (`webhooks.ex:101`, `integrations/github.ex:396`, `integrations/sentry.ex:340`); should extract to `BusterClaw.WebhookAuth` and use `Plug.Crypto.secure_compare/2`.
- **High** — `Library.save_raw_document/1` writes file before DB row with no rollback (`library.ex:26-49`); unique-constraint collision desyncs disk and DB.
- **High** — `Endpoint.cache_raw_body/2` buffers entire request body uncapped (`endpoint.ex:57-70`); trivial OOM vector.
- **High** — `ecto_sqlite3` pinned to `">= 0.0.0"` (`mix.exs:66`).
- **High** — `commands_test.exs` has ~6 tautology tests passing by construction; replace with a single property test.
- **High** — `Chat.Session` writes to DB from a spawned process but `chat_test.exs:36` only sets up `Req.Test.allow`, not `Sandbox.allow`; works today only because tests aren't `async: true`.

Full prioritized list (Critical → Nit) was captured for follow-up. None of the items were addressed in this pass.

### Launched the app end-to-end

- Started `mix phx.server` in the background (`beam.smp` on `127.0.0.1:4000`, healthy via `GET /_health`).
- Started `cd desktop/tauri && cargo tauri dev` — first build took ~1m 24s (`cargo` compiled 395 crates).
- The Tauri window appeared blank/hidden initially. Traced it to `tauri.conf.json` setting `"visible": false` for the main window and `main.rs:74-99` only calling `window.show()` after `wait_for_health` succeeds against `http://127.0.0.1:4000/_health` (or times out at 30s). Once Phoenix's `/_health` returned 2xx, the window flipped visible. No code change required — just confirmed the handshake.

### Removed the Intelligence tab (consolidated to Home)

Goal was eliminating the duplicate model-selection UI. Ported every Intelligence-tab feature onto the Home tab first, then deleted the tab.

Additions to `lib/buster_claw_web/live/status_live.ex`:

- Added `"Custom OpenAI-compatible" → "custom"` to `@type_options`.
- Added a `name` input to the Add-key form (optional; auto-named by type when blank — same behavior as before).
- Added a `base_url` input (optional; placeholder reflects the per-type default).
- Added a per-row **Test** button beside Delete, wired to a new `handle_event("test_provider", …)` clause that calls `Providers.test_provider/1` and surfaces the result through the existing `:flash_note` assign.
- Added `default_model("custom") → ""`, `api_key_placeholder("custom") → "(if your endpoint requires one)"`, and a new `base_url_placeholder/1` helper covering all seven provider types.
- Updated `fill_defaults/2` to preserve user-typed `name` (only fall back to auto-name when blank).
- Restructured the form layout from a 4-column row to a 2-column grid (name + type, base_url + model, then api_key full-width, then submit button) so the extra fields fit without crowding.

Deletions:

- `lib/buster_claw_web/live/intelligence_live.ex` — removed.
- `test/buster_claw_web/live/intelligence_live_test.exs` — removed; equivalent add-via-form and delete-button coverage ported into `test/buster_claw_web/live/status_live_test.exs` using the new selectors (`form[phx-submit='add_provider']`, `button[phx-click='delete_provider']`).
- `lib/buster_claw_web/router.ex` — dropped `live "/intelligence", IntelligenceLive, :index`.
- `lib/buster_claw_web/components/layouts.ex` — removed the `"Intelligence"` sidebar nav entry.
- `lib/buster_claw/runtime/status.ex` — removed the `:intelligence` entry from `@views`.

## Verification

- Ran `mix compile --warnings-as-errors`: clean (`Compiling 4 files (.ex) / Generated buster_claw app`).
- Ran the affected test files (`test/buster_claw_web/live/status_live_test.exs test/buster_claw/runtime/ test/buster_claw_web/live/automation_routes_test.exs`): 7 tests, 0 failures.
- Curled the running endpoint: `GET /` → `200`, `GET /intelligence` → `404`.
- Visual verification in the running Tauri window happened live during the session (Phoenix dev-reload picked up each edit immediately).

## Where we left off

- The full code-quality review (Critical → Nit) is unaddressed. The "Top 5 to fix first" from the review:
  1. Make `Chat.Session` non-blocking + add `Sandbox.allow` for the session pid.
  2. Replace the three per-turn chunk-collection `Agent`s with closure accumulators.
  3. Default-deny on empty webhook secrets + cap raw-body buffering in `Endpoint.cache_raw_body/2`.
  4. Rotate committed `secret_key_base` and salts; move to `runtime.exs`.
  5. Extract `BusterClaw.WebhookAuth` to dedupe the three HMAC implementations.
- Tauri dev shell is up; Phoenix is up on `127.0.0.1:4000`. Both are running in background tasks for this session.
- Auto-memory's `project_architecture.md` is stale (still says Wails+SolidJS). Mentioned to the user but not yet updated.
