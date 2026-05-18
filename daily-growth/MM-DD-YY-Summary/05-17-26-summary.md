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
