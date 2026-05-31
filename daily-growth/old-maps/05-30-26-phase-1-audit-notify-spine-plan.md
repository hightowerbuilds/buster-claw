# Phase 1 — Audit + Notify Spine (Implementation Plan)

**Date:** 2026-05-30
**Status:** Plan only — no code written yet
**Context:** `05-30-26-security-notification-layer-research.md` §6; builds directly on the Phase 0 `Sentinel.Pending` stub.

---

## 1. Objective
Give the user **durable, complete visibility** into every consequential action and every untrusted-data crossing: a persistent security audit log + a real-time notification surface. Phase 1 is *observe & record*, not *block* (gating is Phase 2). When Phase 1 ships, nothing dangerous happens silently — it's always recorded and surfaced, even if not yet stopped.

**Definition of done:**
- One front door, `BusterClaw.Sentinel`, classifies any event into a severity and writes it to a persistent, append-only log.
- A LiveView **alert center** (badge + list, severity-filtered) shows security events live; Tauri emits an OS notification for `:critical`.
- Every consequential command (via `Commands.call/3`), every outbound send (delivery/hook/LLM submission), and every untrusted ingest is recorded — independent of whether agent mode is on.
- The Phase 0 `"security_alerts"` broadcasts and pending entries flow through this same spine (no rework).

---

## 2. What already exists (build on, don't reinvent)
- **`BusterClaw.Workflow` + `Workflow.RuntimeEvent`** — an append-only, persisted activity log. `record_event/2,3` inserts + broadcasts on the `"runtime_events"` topic; `list_runtime_events/1`; `subscribe/0`. Event types already include `mcp_event`, `system`; levels `info|warn|error`.
- **`AgentMode.record_activity/3`** — ephemeral PubSub on `"agent_activity"`, only when agent mode is on. (To be superseded by Sentinel for security purposes.)
- **`Commands.Result` redactor** — already strips `api_key`/`token`/`*_enc`/etc. Reuse for log metadata.
- **`Commands.call/3` + `:caller`** (from Phase 0) — the universal seam; `authorize/2` already records pending entries.

So Phase 1 is mostly: **formalize a security classifier on top of `Workflow.record_event`, add a dedicated notification topic + UI, and ensure all the call sites feed it.**

---

## 3. Design

### 3.1 `BusterClaw.Sentinel` — the classifier/front door
```elixir
defmodule BusterClaw.Sentinel do
  # classify any event → {severity, category}; record + notify.
  @type severity :: :info | :notice | :warn | :critical
  def observe(category, message, meta \\ %{}, opts \\ [])
end
```
- `observe/4` redacts `meta` (via `Commands.Result` redactor), computes severity from a **declarative rubric** (see §3.3), persists it, and notifies.
- Persistence: reuse `Workflow.record_event/1` (append-only `RuntimeEvent`). Add new event types: `security_block`, `command_invoke`, `outbound_send`, `untrusted_ingest`, `llm_submission`. (Migration-light: `RuntimeEvent` already has a free-form `metadata` map; severity lives there + see §3.2 for the optional schema bump.)
- Notification: broadcast on a **dedicated `"security_alerts"` topic** (the one Phase 0 already uses) so the alert center can subscribe to *just* security events, not the whole runtime feed.

### 3.2 Schema: minimal vs. richer (decision)
- **Minimal (no migration):** keep `RuntimeEvent` as-is; store `severity` + `caller` + `category` inside `metadata`. Fastest; weaker for querying/filtering.
- **Richer (small migration, recommended):** add `severity` (string) and `acknowledged_at` (utc_datetime, null) columns to `runtime_events` (or a dedicated `security_events` table if we want to keep the dashboard feed separate from the security feed). Enables "unacknowledged critical" badges and clean filtering.
- *Lean:* dedicated `security_events` table — keeps the user-facing security alert center decoupled from the noisy ops activity feed, and gives Phase 2 a natural home for approve/deny state. See §6 Q1.

### 3.3 `risk:` / `outward:` command metadata (the deferred Phase 0 decision)
Add two declarative fields to every catalog entry builder in `commands.ex`:
- `risk:` ∈ `:low | :medium | :high | :critical`
- `outward:` ∈ `true | false` (does it leave the box / cause an irreversible external effect?)

Severity rubric (data-driven, no per-command hardcoding in controllers):
- `outward: true` and irreversible (send email, dispatch delivery, exec shell, spawn process) → **:critical**
- credential/provider/config change, `document_delete`, `memory_remember` → **:warn/:high**
- new external ingest/browse, integration poll, analysis run → **:notice/:medium**
- reads → **:info/:low**

This also lets Phase 0's `authorize/2` key off `risk`/`outward` instead of the binary `:safe`/`:restricted`, and feeds Phase 2's gating directly.

### 3.4 Wire the call sites (instrumentation)
| Site | Hook |
|---|---|
| `Commands.call/3` | `Sentinel.observe(:command_invoke, …)` on every dispatch (success+failure); refusals already recorded by Phase 0 `authorize/2` → route through `Sentinel`. Removes the dependency on `agent_mode.on?`. |
| `delivery.ex` `send_payload/dispatch_all` | `Sentinel.observe(:outbound_send, …)` with destination + payload digest |
| `hooks.ex` `execute_webhook` / shell exec | `:outbound_send` (URL) / `:command_invoke` (shell target) |
| `providers.ex` / `analysis.ex` `call_provider` | `Sentinel.observe(:llm_submission, …)` with provider/model + content hash + trust label (trust label fully populated in Phase 3) |
| `ingest.ex` / `browser.ex` | `Sentinel.observe(:untrusted_ingest, …)` with source URL + bytes |

Each hook is a one-liner; the classification/redaction lives in `Sentinel`.

### 3.5 Notification surfaces
- **Alert center LiveView** (new `SecurityLive` or a pane in `StatusLive`): subscribes to `"security_alerts"`; shows a severity-filtered list, an **unacknowledged-critical count badge** in the tab shell (`layouts.ex`), and an "acknowledge" action (writes `acknowledged_at`).
- **Tauri OS notification** for `:critical`: emit a Tauri event (e.g. `security:alert`) the desktop shell listens for and raises a native notification (needs the `notification` permission added to `capabilities/default.json`). Degrades gracefully in plain-browser mode (in-app badge only).
- **Route** in `router.ex` + nav entry.

---

## 4. File-by-file change list
| File | Change | Risk |
|---|---|---|
| `lib/buster_claw/sentinel.ex` *(new; absorbs Phase 0 `Sentinel.Pending`)* | classify + redact + persist + broadcast | Medium |
| `lib/buster_claw/commands.ex` | add `risk:`/`outward:` to entry builders; `Sentinel.observe` in `call/3`; severity helper | Medium (touches every entry) |
| `priv/repo/migrations/*` *(if richer schema)* | `security_events` table or `runtime_events` columns | Low |
| `lib/buster_claw/workflow.ex` or new context | query helpers: list/ack security events | Low |
| `lib/buster_claw/delivery.ex`, `hooks.ex`, `providers.ex`, `analysis.ex`, `ingest.ex`, `browser.ex` | one-line `Sentinel.observe` hooks | Low each |
| `lib/buster_claw_web/live/security_live.ex` *(new)* + `router.ex` + `layouts.ex` badge | alert center + nav + count | Medium |
| `desktop/tauri/src/main.rs` + `capabilities/default.json` | OS-notification listener + `notification` permission | Medium |
| `docs/LOCAL_TRUST.md` | document the audit/notify guarantees | Docs |

---

## 5. Test plan
- `sentinel_test.exs`: each category → expected severity; metadata redaction strips secrets; broadcast fires on `"security_alerts"`.
- `commands_test.exs`: every catalog entry has `risk:`/`outward:` set (property test); `call/3` emits a `command_invoke` security event.
- Instrumentation tests: a delivery dispatch / hook exec / LLM submission / ingest each produce the expected security event (assert via subscribed test process).
- `security_live_test.exs`: live event appears; critical raises the badge; acknowledge clears it.
- Independence: events are recorded **with agent mode off** (regression vs. today's `record_activity` gating).

---

## 6. Open decisions
1. **Schema:** dedicated `security_events` table (recommended, clean separation) vs. reuse `runtime_events` + metadata (no migration)?
2. **Surface:** standalone `SecurityLive` page vs. a pane inside `StatusLive`?
3. **Notification scope:** OS notifications for `:critical` only, or also `:warn`? (Fatigue trade-off.)
4. **AgentMode overlap:** retire `agent_mode.record_activity` in favor of Sentinel, or keep it for the live "agent is working" UI and have it delegate to Sentinel?
