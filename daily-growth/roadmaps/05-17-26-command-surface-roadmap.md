# Command Surface Roadmap

## Purpose

Unify Buster Claw's command vocabulary into a single canonical surface that three callers can use:

1. **The internal agent** — the active provider's chat model, calling tools to manipulate Buster Claw from inside its own chat session.
2. **An external CLI** (`./buster-claw <cmd>`) — for shell scripting, ad-hoc human use, and quick checks.
3. **An MCP server** hosted by Buster Claw itself — so external TUI agents like Claude Code and Codex can drive Buster Claw as a tool-using peer.

All three consume the same `BusterClaw.Commands` module. There is no parallel implementation; there is no second source of truth.

## Non-Goals

- [ ] Do not expose Buster Claw on a non-loopback interface. All endpoints stay on `127.0.0.1`.
- [ ] Do not support standalone-without-app operation. CLI and MCP require `mix phx.server` (dev) or the bundled release (prod) to be running.
- [ ] Do not invent a new wire protocol. HTTP+JSON for the API; SSE for MCP per the MCP spec; stdout for the escript.
- [ ] Do not duplicate any context logic. Commands wrap existing modules (`Sources`, `Providers`, `Ingest`, `Analysis`, `Memory`, etc.) — never re-implement.
- [ ] Do not block on the internal agent tool wiring (Phase 4) to ship the external surfaces. The agent integration is independent.

## Architecture

```
                  ┌────────────────────────────────┐
                  │  BusterClaw.Commands           │  ← canonical API
                  │  Wraps every context.          │
                  │  ~30 functions, fully tested.  │
                  └────────────────────────────────┘
                          ▲          ▲          ▲
                          │          │          │
        ┌─────────────────┘          │          └──────────────────┐
        │                            │                             │
┌───────┴────────┐         ┌─────────┴───────────┐       ┌─────────┴──────────┐
│  HTTP /api/*   │         │  Internal agent     │       │  MCP server        │
│  JSON in/out,  │         │  (tool calls from   │       │  SSE on /mcp.      │
│  token auth.   │         │  ChatLive — direct  │       │  Same Commands.    │
│                │         │  function call)     │       │                    │
└────────┬───────┘         └─────────────────────┘       └────────────────────┘
         │
         │ HTTP (localhost only, token in header)
         ▼
┌────────────────┐
│  ./buster-claw │
│  escript       │
└────────────────┘
```

### Key decisions

- [ ] One canonical surface: `BusterClaw.Commands`. Every command exists exactly once.
- [ ] HTTP API at `/api/*`, JSON in/out, token auth via `Authorization: Bearer <token>` header.
- [ ] MCP via SSE at `GET /mcp` (in-process, no separate subprocess). Per the MCP spec, supports `tools/list` and `tools/call`.
- [ ] CLI escript built via `mix escript.build` to repo root. Run as `./buster-claw <subcommand> [args]`.
- [ ] Shared token stored at `~/Library/Application Support/BusterClaw/api_token`, generated on first launch alongside `secret_key_base`. Same pattern as the existing secret_key_base flow in `desktop/tauri/src/main.rs`.
- [ ] Loopback-only binding stays unchanged. The token defends against other users on a shared machine, not against network attackers (none can reach the port).

## Phase 0 — Command Inventory

Goal: write down every command before writing any code, so the surface is complete and consistent.

- [ ] Inventory read-only commands across every context (Sources, Providers, Documents, Analysis, Memory, Calendar, MCP, Webhooks, Hooks, Delivery, Scheduler, Integrations, Runtime).
- [ ] Inventory mutation commands (create/update/delete) for every config-bearing context.
- [ ] Inventory trigger commands (ingest a source, queue an analysis, run a webhook, run a delivery, poll an integration, test a provider).
- [ ] Inventory chat commands (`chat_once/2` for a single round-trip, `chat_stream/2` for streamed output).
- [ ] Decide naming convention: `<noun>_<verb>` (`source_create`, `analysis_queue`) — matches MCP tool-naming conventions and reads cleanly in CLI form.
- [ ] Decide return shape: `{:ok, value} | {:error, reason_atom_or_changeset}` everywhere. No mixed tuples.
- [ ] Document each command with a short docstring including: purpose, args (with types), return shape, side effects, idempotency.
- [ ] Pin the inventory in `docs/rewrite/COMMAND_SURFACE.md` so the three frontends share a reference.

## Phase 1 — `BusterClaw.Commands` Module

Goal: implement the canonical surface. No transport, no auth, no UI — just functions.

- [ ] Create `lib/buster_claw/commands.ex` with `@moduledoc` linking to `docs/rewrite/COMMAND_SURFACE.md`.
- [ ] Wrap every inventoried command. Functions are pure delegates — no extra business logic.
- [ ] Add `BusterClaw.Commands.list_commands/0` returning the command catalog as data (used by MCP `tools/list` and CLI `--help`).
- [ ] Add JSON-Schema-shaped argument descriptions per command (used by MCP and CLI argument parsing).
- [ ] Add `test/buster_claw/commands_test.exs` covering happy path and error case for every command.
- [ ] Verify: `mix test` clean, `mix compile --warnings-as-errors` clean, `mix format` clean.

## Phase 2 — HTTP API + Token Auth

Goal: expose `Commands` over HTTP for external clients. Keep it thin — controllers only translate.

- [ ] Generate `~/Library/Application Support/BusterClaw/api_token` on app boot if missing (64-char alphanumeric, same generator as `secret_key_base`). In dev, use a stable `dev_api_token` so reload doesn't rotate.
- [ ] Add `BusterClawWeb.ApiAuth` plug that reads `Authorization: Bearer <token>`, compares constant-time, 401s on mismatch.
- [ ] Add `BusterClawWeb.ApiController` with `action :run` that dispatches to `Commands.<name>(args)` based on `params["command"]`.
- [ ] Route shape: `POST /api/run` with body `{"command": "source_create", "args": {...}}`. Single endpoint keeps the surface narrow; one path to audit and rate-limit.
- [ ] Add `GET /api/commands` returning the catalog (no auth needed — just metadata).
- [ ] Error mapping: `{:error, %Ecto.Changeset{}}` → 422 with errors as JSON; `{:error, :not_found}` → 404; `{:error, :unauthorized}` → 401.
- [ ] Add `test/buster_claw_web/controllers/api_controller_test.exs` covering auth, happy path, validation errors.
- [ ] Verify: `mix test` clean.

## Phase 3a — CLI Escript

Goal: ship `./buster-claw` as a thin HTTP client over the API. Runs in parallel with Phase 3b.

- [ ] Add `escript:` entry in `mix.exs` pointing at `BusterClaw.CLI.Main`.
- [ ] Add `lib/buster_claw/cli/main.ex` — argument parsing, subcommand dispatch.
- [ ] Resolve the token from `~/Library/Application Support/BusterClaw/api_token` at run time. Fail fast with a clear message if missing.
- [ ] Resolve the base URL from `BUSTER_CLAW_URL` env var, default `http://127.0.0.1:4000`. Fail fast with a clear message on connection refused.
- [ ] Output: human-readable table by default, `--json` for machine-readable. Both come from the same JSON response — only the formatter differs.
- [ ] Build target: `mix escript.build` → `./buster-claw` at repo root. Add to `.gitignore`.
- [ ] Add smoke tests via `test/buster_claw/cli/main_test.exs` — invoke via `:os.cmd/1` against a running test server, or stub the HTTP client.
- [ ] Verify: `./buster-claw source list`, `./buster-claw source create --url https://example.com --type rss`, `./buster-claw chat "what's the latest news source?"` all work.

## Phase 3b — MCP Server Endpoint

Goal: expose Buster Claw as an MCP server over SSE so Claude Code / Codex can consume it. Parallel with 3a.

- [ ] Read the MCP spec sections for SSE transport and `tools/list` / `tools/call` (latest: 2025-06-18 revision).
- [ ] Add `lib/buster_claw_web/mcp_server.ex` — handler that translates MCP JSON-RPC messages to `Commands` calls.
- [ ] Route `GET /mcp` (SSE handshake) and `POST /mcp/message` (client → server messages). Use a Plug that hijacks the connection for SSE.
- [ ] Implement: `initialize`, `tools/list` (from `Commands.list_commands/0`), `tools/call` (dispatches to `Commands.<name>(args)`).
- [ ] Auth: require `Authorization: Bearer <token>` on both the SSE handshake and message POST.
- [ ] Add an example MCP config snippet to README for Claude Code (`claude_desktop_config.json`) and Codex (`codex.toml` or wherever Codex configures MCP servers).
- [ ] Add `test/buster_claw_web/mcp_server_test.exs` — initialize, tools/list, tools/call happy path, tools/call error path, auth failure.
- [ ] Verify by adding `buster-claw` to a real Claude Code MCP config and confirming `tools/list` returns the catalog.

## Phase 4 — Internal Agent Tool Wiring

Goal: let Buster Claw's active provider call `Commands` as tool calls from within ChatLive.

- [ ] Decide tool-calling format per provider (Anthropic, OpenAI, Gemini, Codex). Each has a slightly different shape — needs a small adapter layer in the provider modules.
- [ ] Add `BusterClaw.Provider.Behaviour.supports_tools?/0` and `tool_definitions/1` callbacks.
- [ ] Map `Commands.list_commands/0` output into each provider's tool-definition format.
- [ ] In `ChatLive`, when the active provider returns a tool-use response, call `Commands.<name>(args)`, send the result back as a tool-result message, continue the conversation.
- [ ] Decide which subset of commands the internal agent is allowed to call. Probably: read-only + chat + low-risk triggers. NOT delete/destroy. NOT delivery (so the model can't accidentally email a half-baked report).
- [ ] Add `test/buster_claw_web/live/chat_live_tool_test.exs` covering tool-use → tool-result round-trip.

## Phase 5 — Docs and Smoke Tests

Goal: make this discoverable and resilient.

- [ ] `docs/rewrite/COMMAND_SURFACE.md` — full catalog with examples for each frontend (HTTP, CLI, MCP).
- [ ] README: add a "Driving Buster Claw" section covering the three surfaces with example invocations.
- [ ] Integration smoke test: spin up `mix phx.server`, hit `/api/commands`, run `./buster-claw source list`, exercise one MCP `tools/call` over SSE — all in a single script that can be wired into CI later.
- [ ] Roadmap retrospective: update `docs/rewrite/CUTOVER.md` to note the command surface as a new readiness gate.

## Risks and Open Questions

- [ ] **Token rotation**: if the user wants to revoke an issued token, today there's no UI. Initial answer: rewrite the file and restart the app. Revisit if it becomes friction.
- [ ] **Streaming chat over MCP**: MCP supports streamed responses; the existing `Providers.chat/3` callback model fits, but mapping it to MCP's stream chunks needs care.
- [ ] **Codex MCP version**: confirm what MCP spec revision Codex CLI currently implements. May lag Claude Code.
- [ ] **Concurrency**: `tools/call` happens-before semantics — if two agents fire `analysis_queue` for the same document, the second should be a no-op, not a duplicate.
- [ ] **CLI installation**: today the escript lives in-repo; later, consider an `install.sh` that symlinks to `/usr/local/bin/buster-claw` so users can call it from anywhere.
- [ ] **MCP discoverability**: ideally Buster Claw advertises its MCP endpoint via mDNS or a well-known file so TUI agents auto-discover it. Out of scope for v1; worth a note.

## Verification Gates

Each phase must pass before the next begins (except 3a/3b which run in parallel):

- [ ] Phase 0: catalog reviewed and committed to `docs/rewrite/COMMAND_SURFACE.md`.
- [ ] Phase 1: `mix test` clean, every command has a test.
- [ ] Phase 2: `curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/BusterClaw/api_token)" -X POST http://127.0.0.1:4000/api/run -d '{"command":"source_list"}'` returns a valid response.
- [ ] Phase 3a: `./buster-claw source list` produces a readable table.
- [ ] Phase 3b: Claude Code's `/mcp` lists `buster-claw` and shows the tool catalog.
- [ ] Phase 4: the active model successfully calls `document_list` from inside a ChatLive session and uses the result in its next reply.
- [ ] Phase 5: integration smoke test passes end-to-end.
