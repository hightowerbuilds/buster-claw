# Phase 0 — Close the MCP Tier-Bypass Hole (Implementation Plan)

**Date:** 2026-05-30
**Status:** Plan only — no code written yet
**Depends on / context:** `05-30-26-security-notification-layer-research.md` §4 (headline finding)
**Decisions locked (2026-05-30):** **Option A+B** — scoped MCP token, airtight (§3). **Refusal + minimal pending stub** — deny restricted agent calls AND record them where the user can see them immediately (§4.2).
**Estimated size:** Medium. ~6 source files (incl. second token + auth plug + pending-stub store), ~3 test files. No DB migration required (token is a file; pending stub can be an in-memory/ETS or PubSub-backed list for Phase 0).

---

## 1. Objective

Make it impossible for an **external agent over `/mcp`** to silently execute a `:restricted` command (send email, run shell hooks, spawn processes, swap providers/credentials, delete documents, etc.). Restricted commands invoked by an agent must be **refused with a clear "needs human confirmation" signal** — the actual approval UI comes later (Phase 2). This phase only installs the *enforcement seam* and closes the silent-execution path.

**Definition of done:**
- `tools/list` over `/mcp` advertises only `:safe`-tier commands.
- `tools/call` over `/mcp` for a `:restricted` command returns a structured "restricted / requires confirmation" error, and **does not execute**.
- The chat agent path is unchanged in behavior (already correct), but now shares the same central enforcement.
- The user's own CLI / `/api/run` automation path is consciously decided (see §3) and documented.
- Regression tests prove a representative restricted command (`gmail_send`, `hook_test`) is rejected over `/mcp`.

---

## 2. Current state (verified in source)

| Surface | Path | Today's behavior |
|---|---|---|
| Chat agent | `provider/anthropic.ex:103` → `AgentTools.execute/2` → `Commands.call/2` | ✅ Gated: `AgentTools` filters to `tier == :safe` before calling (`agent_tools.ex:31-50`) |
| MCP endpoint | `mcp_controller.ex:56` (`tools/list`), `:68` (`tools/call`) → `Commands.call/2` | ❌ No filter: advertises + executes the **full** catalog |
| HTTP API | `api_controller.ex:16` / `:25` (`/api/run`, `/api/commands`) → `Commands.call/2` | ⚠️ No filter (full access); used by the CLI with the bearer token |
| CLI | `cli.ex` → HTTP `/api/run` | Inherits `/api/run` behavior (thin HTTP client) |
| Internal code | direct `Commands.source_list/1` etc. | Bypasses `call/2` entirely — trusted, unaffected |

`Commands.call/2` (`commands.ex:55-65`) does **no authorization** — it dispatches by name and records activity. This is the natural single seam to add enforcement.

---

## 3. ⚠️ Key decision: the shared-token problem

`/api/run` and `/mcp` both sit behind the **same** `:api_authenticated` pipeline and the **same single bearer token** (`api_token.ex`). When we configure an external agent as an MCP client, we hand it that token. That means a malicious agent could **bypass an MCP-only restriction by calling `/api/run` directly** with the same token.

So "restrict `/mcp`" alone does **not** fully close the hole. Three options:

- **Option A — Caller-tagging only (minimal).** Tag the MCP endpoint as an untrusted caller, leave `/api/run` full-access. Closes the *honest-tool-discovery* path and stops accidental/standard MCP execution, but a hostile token-holder can still reach restricted commands via `/api/run`.
  - *Pros:* smallest change, no token/migration work, doesn't disrupt the user's CLI automation. *Cons:* not airtight against a hostile agent that has the token.
- **Option B — Caller-tagging + separate scoped MCP token (recommended).** Issue a distinct, restricted **MCP token** (safe-tier only); keep the existing full-access token for the user's own CLI/`/api/run`. The MCP client config gets only the restricted token.
  - *Pros:* makes the trust boundary real — an agent literally cannot hold a token that unlocks restricted commands. *Cons:* second token to manage (write to `api_token.ex`, update MCP client docs); slightly more work.
- **Option C — Treat all token-holders as semi-trusted.** Apply the same restriction to `/api/run`. *Cons:* breaks the user's own CLI for legitimate restricted ops (e.g. scripted `source_create`); rejected for Phase 0.

**DECIDED: Option A+B (airtight).** The caller is derived from *which token authenticated*, not hardcoded per-route, so the boundary is real: an agent is issued only the restricted MCP token and therefore cannot reach restricted commands on *any* route (incl. `/api/run`). The user's own CLI keeps the full-access token. See §4.5 (now required) and §6.

---

## 4. Design

### 4.1 Add a `:caller` concept to the command seam
Extend dispatch with an optional, backward-compatible third argument:

```elixir
# commands.ex
@type caller :: :trusted | :agent | :mcp
def call(name, args \\ %{}, opts \\ []) when is_binary(name) do
  caller = Keyword.get(opts, :caller, :trusted)
  with :ok <- authorize(name, caller) do
    # ... existing dispatch + record_activity ...
  end
end

# Restricted commands are refused for untrusted callers.
defp authorize(name, caller) when caller in [:agent, :mcp] do
  case command_tier(name) do
    :safe -> :ok
    _     -> {:error, :requires_confirmation}
  end
end
defp authorize(_name, _trusted), do: :ok
```

- `command_tier/1` reads the existing `:tier` field already on every catalog entry (`commands.ex` `*_entry` builders).
- Default `caller: :trusted` keeps **all existing internal/`/api/run` callers working unchanged** — only the MCP (and agent) call sites opt into restriction.
- `record_activity` still fires (so even a *refused* attempt is observable now; becomes the audit hook in Phase 1).

### 4.2 New error in the contract + minimal pending stub (DECIDED)
Introduce `{:error, :requires_confirmation}` as a first-class result so frontends can render it consistently. **In addition (decided):** when a restricted command is refused for an untrusted caller, record a **pending request** so the user has immediate visibility before the full Phase 2 approval UI exists.

Phase-0 pending stub (intentionally lightweight — no DB migration):
- A small `BusterClaw.Sentinel.Pending` GenServer/ETS holding recent blocked requests `{id, command, args-digest (secrets redacted via `Commands.Result`), caller, at}`.
- `authorize/2` records the entry on refusal and broadcasts `{:pending_action, entry}` on a `"security_alerts"` PubSub topic (the same topic Phase 1's Notifier will use — so this is forward-compatible, not throwaway).
- A minimal surface for the user to *see* them: either a badge/list in `StatusLive`, or a new lightweight pane. Phase 0 only needs **read/visibility** (approve/deny actions are Phase 2). Keep it to a list + count.
- The entry id is the seam Phase 2's `Gate` will later use to resolve approve/deny.

### 4.3 Wire the MCP controller (the actual fix)
- `tools/list` (`mcp_controller.ex:56`): filter to safe-tier, e.g.
  `Commands.list_commands() |> Enum.filter(&(&1.tier == :safe)) |> Enum.map(&command_to_tool/1)`.
  Consider exposing a small helper `Commands.safe_commands/0` (also reusable by `AgentTools.safe_commands/0` to remove duplication).
- `tools/call` (`mcp_controller.ex:68`): pass `caller: :mcp` →
  `Commands.call(name, args, caller: :mcp)`.
- Map `{:error, :requires_confirmation}` to an MCP `isError: true` result whose text explains the command requires human approval in the Buster Claw app (so the agent reports it back cleanly rather than retrying blindly).

### 4.4 Align the chat agent on the same seam (DECIDED — do now)
`AgentTools.execute/2` passes `caller: :agent` and relies on central enforcement instead of its own pre-filter; advertisement reuses `Commands.safe_commands/0`. Behavior is identical, but there is now a **single source of truth** for "what an untrusted caller may run." Keeps the chat agent and MCP endpoint from drifting apart again.

### 4.5 Scoped MCP token (REQUIRED — Option B decided)
- `api_token.ex`: add a second token (`mcp_token`), same file-permission discipline (`0600`/`0700`), generated on first run.
- `plugs/api_auth.ex`: on auth, set `conn.assigns.caller` = `:trusted` (full token) or `:mcp` (mcp token); the MCP controller reads it instead of hardcoding `:mcp`. This makes the boundary token-derived, not route-derived (and means even `/api/run` with the MCP token is restricted).
- Update MCP client config docs to use the MCP token.

---

## 5. File-by-file change list

| File | Change | Risk |
|---|---|---|
| `lib/buster_claw/commands.ex` | Add `call/3` with `opts[:caller]`; `authorize/2` (records pending + broadcasts on refuse); `command_tier/1`; `safe_commands/0` | Low — additive, default preserves behavior |
| `lib/buster_claw/sentinel/pending.ex` *(new)* | Minimal pending-request store (GenServer/ETS) + `"security_alerts"` broadcast; add to supervision tree in `application.ex` | Medium — new process |
| `lib/buster_claw_web/controllers/mcp_controller.ex` | Filter `tools/list` to safe; pass `caller: :mcp`; render `:requires_confirmation` | Low |
| `lib/buster_claw/api_token.ex` + `plugs/api_auth.ex` | Second scoped MCP token + `conn.assigns.caller` assignment (`:trusted` vs `:mcp`) | Medium |
| `lib/buster_claw_web/controllers/api_controller.ex` | Read `conn.assigns.caller`, pass to `Commands.call/3`; map new error | Low |
| `lib/buster_claw/agent_tools.ex` | Route through `caller: :agent`; dedupe via `Commands.safe_commands/0` | Low |
| `lib/buster_claw_web/live/status_live.ex` (or new pane) | Minimal pending-actions list + count badge (read-only) | Low–medium |
| `application.ex` | Supervise `Sentinel.Pending` | Low |
| `docs/LOCAL_TRUST.md` | Document the MCP trust boundary + the two-token model | Docs |

---

## 6. Test plan

New / updated tests:
- `test/buster_claw_web/controllers/mcp_controller_test.exs`:
  - **Update existing** "returns the full catalog" test (`:23`) — it currently asserts representatives incl. `chat_send`; verify each representative's tier and switch the assertion to "returns only safe-tier tools" + assert a known restricted command (e.g. `gmail_send`) is **absent**.
  - **Add**: `tools/call` for `gmail_send` / `hook_test` returns `isError: true` with a confirmation message and **does not execute** (assert no side effect — e.g. no delivery attempt / no hook run recorded).
- `test/buster_claw/commands_test.exs`:
  - `Commands.call("gmail_send", %{}, caller: :mcp)` → `{:error, :requires_confirmation}`.
  - `Commands.call("source_list", %{}, caller: :mcp)` → `{:ok, _}` (safe still works).
  - `Commands.call("gmail_send", %{}, caller: :trusted)` path still dispatches (so `/api/run` unaffected under Option A).
- `test/buster_claw/security_hardening_test.exs`: extend the existing `hook_test`-rejection style to cover the MCP caller, keeping a single security-regression home.
- `api_token` test for two-token generation + `api_auth` test asserting the MCP token yields `caller: :mcp` and is **refused on a restricted `/api/run`** (proves Option B airtightness), while the full token still works there.
- `sentinel/pending` test: a refused MCP call **adds a pending entry** (with secrets redacted) and **broadcasts** on `"security_alerts"`; a safe call does not.

Regression guard idea: a property-style test asserting **every** `:restricted` command in the catalog is rejected for `caller: :mcp` — so new restricted commands are covered automatically.

---

## 7. Rollout & verification
1. Implement §4.1–4.3 (+ optionally 4.4).
2. `mix precommit` (compile `--warnings-as-errors`, format, full test).
3. Manual smoke: run `mix phx.server`, hit `/mcp` `tools/list` with the token → confirm restricted names absent; `tools/call gmail_send` → confirm refusal + no email. Then `/api/run gmail_send` → confirm still works under Option A (or refused under B with MCP token).
4. Update `docs/LOCAL_TRUST.md`.

No data migration under Option A; Option B adds a token file (no DB change).

---

## 8. Decisions
1. ✅ **Option A+B (airtight)** — scoped MCP token; trust boundary is token-derived (§3, §4.5).
2. ✅ **Refusal + minimal pending stub** — deny restricted agent calls and record them for immediate user visibility on the `"security_alerts"` topic (§4.2).
3. ✅ **Chat-agent dedup** — fold the agent onto the central `Commands.call/3` seam now (one source of truth), keeping `safe_commands/0` for advertisement (§4.4).

Still open (not blocking Phase 0):
4. **Tier granularity** — `:safe`/`:restricted` is binary today. Introduce the `risk:`/`outward:` metadata from the research doc *now* (so Phase 1/2 classification is ready), or keep Phase 0 strictly on the existing tiers? *(Lean: keep Phase 0 on existing tiers; add metadata in Phase 1.)*
