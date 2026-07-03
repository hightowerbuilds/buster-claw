# Entire Codebase Code Review

**Date:** 2026-05-30
**Status:** Review complete - no code changes made
**Scope:** Phoenix/LiveView app, command surface, MCP/API boundaries, browser sidecar, automation, library ingestion, scheduler, tests
**Validation:** `mix test` ran: 301 tests, 2 failures (`Exqlite.Error: Database busy` in `BusterClaw.SchedulerTest`)

---

## Executive Summary

The codebase has a coherent local-first architecture: Phoenix/LiveView UI, SQLite/Ecto persistence, a shared command catalog, library artifacts, LLM provider adapters, scheduler, hooks, delivery automation, MCP, and a Tauri desktop shell.

The main risks are trust-boundary bugs and behavior drift between the command catalog, schemas, and automation implementation. The highest-priority fixes are MCP tier enforcement, browser-sidecar SSRF redirect protection, and making webhook actions actually execute.

---

## Findings

### 1. Critical - MCP exposes restricted commands

**Files:**
- `lib/buster_claw_web/controllers/mcp_controller.ex:55`
- `lib/buster_claw_web/controllers/mcp_controller.ex:68`
- `lib/buster_claw/agent_tools.ex:31`
- `lib/buster_claw/commands.ex:661`
- `README.md:111`

`McpController` advertises every command via `Commands.list_commands()` and executes tool calls directly through `Commands.call/2`. This bypasses the safe-tier filter used by `AgentTools`.

Impact: any MCP client with the local token can discover and call restricted commands, including provider changes, document deletion, analysis execution, delivery dispatch, and shell hook execution. This contradicts the README claim that restricted commands are not exposed to MCP.

**Recommended fix:** centralize command authorization at `Commands.call/3`, add caller context (`:trusted`, `:mcp`, `:agent`), expose only safe-tier tools through MCP, and reject restricted calls for untrusted callers.

---

### 2. High - Playwright sidecar bypasses SSRF guard on redirects

**Files:**
- `lib/buster_claw/browser.ex:10`
- `lib/buster_claw/browser.ex:61`
- `priv/playwright_sidecar/server.js:83`
- `lib/buster_claw/url_guard.ex:37`

`BusterClaw.Browser.fetch/2` validates only the original URL before sending it to the Playwright sidecar. Playwright then follows redirects without revalidating each hop. The HTTP fallback correctly uses `URLGuard.req_step/1` to revalidate redirects, but the sidecar path does not.

Impact: a public URL can redirect to localhost, private IPs, or metadata endpoints and be fetched by the sidecar.

**Recommended fix:** enforce redirect validation inside the sidecar using Playwright request/response hooks, or disable/handle redirects manually and validate every destination URL before navigation continues.

---

### 3. High - Webhook triggers accept requests but do not execute actions

**Files:**
- `lib/buster_claw_web/controllers/webhook_controller.ex:8`
- `lib/buster_claw_web/controllers/webhook_controller.ex:29`
- `lib/buster_claw/webhooks.ex:35`
- `lib/buster_claw/webhooks.ex:57`
- `lib/buster_claw/automation/webhook.ex:6`

`Webhooks.trigger/3` authenticates and audits the webhook, then returns `action_summary/1`. It does not run ingest, analysis, full pipeline, command execution, or delivery behavior.

There is also a body-handling issue: `WebhookController` calls `Plug.Conn.read_body/2` after normal request parsing may already have consumed the body.

Impact: external webhook callers receive `202 Accepted`, but configured actions do not happen. Tests currently miss this because they assert acceptance rather than side effects.

**Recommended fix:** implement action dispatch for `ingest`, `analyze`, `full`, and `command`; use the cached raw body from the endpoint; add side-effect tests per action.

---

### 4. Medium - Command catalog schemas drift from Ecto changesets

**Files:**
- `lib/buster_claw/commands.ex:591`
- `lib/buster_claw/commands.ex:806`
- `lib/buster_claw/commands.ex:905`
- `lib/buster_claw/sources/source.ex:6`
- `lib/buster_claw/automation/webhook.ex:6`

Examples:
- `source_create` and `source_update` advertise `["rss", "url"]`, but sources allow `article`, `documentation`, `rss`, `youtube_transcript`, and `browser`.
- Webhook commands advertise `run_analysis`, `ingest_url`, `run_scheduler`, and `shell`, but the webhook schema allows `ingest`, `analyze`, `full`, and `command`.
- Delivery destination commands include `"webhook"`, while the delivery schema allows `slack`, `discord`, `telegram`, and `email`.

Impact: generated MCP/API clients will produce invalid calls, and valid app concepts are hidden from external tools.

**Recommended fix:** derive command enums from schema constants or add tests asserting command catalog enums match changeset inclusions.

---

### 5. Medium - `analysis_run_pending` ignores requested max

**Files:**
- `lib/buster_claw/commands.ex:211`
- `lib/buster_claw/analysis.ex:57`
- `lib/buster_claw/commands.ex:703`

`Commands.analysis_run_pending/1` reads `"max"` but passes `max: max` to `Analysis.run_pending/1`. `Analysis.run_pending/1` reads `:limit`, so callers requesting multiple jobs still run one job.

Impact: CLI/API/MCP callers get misleading behavior from a documented command.

**Recommended fix:** pass `limit: max`, or rename the command argument to `limit` and maintain backward compatibility for `"max"`.

---

### 6. Medium - Hook `async` is ignored and shell hooks have no timeout

**Files:**
- `lib/buster_claw/automation/hook.ex:14`
- `lib/buster_claw/commands.ex:858`
- `lib/buster_claw/hooks.ex:33`
- `lib/buster_claw/hooks.ex:67`

Hooks expose and store `async`, but `Hooks.execute_event/3` runs all hooks synchronously. Shell hooks call `System.cmd("sh", ["-c", hook.target])` without a timeout.

Impact: a hanging shell command can block scheduler, analysis, or UI-triggered workflows indefinitely despite being configured as async.

**Recommended fix:** honor `async` through supervised tasks and add explicit timeouts/output limits for shell hooks.

---

### 7. Medium - Raw document filenames can collide and overwrite content

**Files:**
- `lib/buster_claw/library/artifact.ex:37`
- `lib/buster_claw/library/artifact.ex:153`
- `lib/buster_claw/library.ex:51`

Raw document paths are based on date plus slugified filename. `Library.save_raw_document/1` then upserts by `artifact_path`.

Impact: two same-day articles with the same title or fallback filename collapse into one markdown file and one database row.

**Recommended fix:** include a stable URL hash, source id, timestamp, or conflict suffix in the artifact filename.

---

### 8. Low - Chat provider failures leak collector Agents

**Files:**
- `lib/buster_claw/chat/session.ex:123`
- `lib/buster_claw/chat/session.ex:131`
- `lib/buster_claw/chat/session.ex:134`

`provider_chat/1` starts an Agent to collect streamed chunks and stops it only on success. Provider errors return without stopping the Agent.

Impact: repeated provider failures can leak lightweight processes.

**Recommended fix:** stop the Agent in both success and error paths, preferably using `try/after` once the Agent is started.

---

## Test Result

Command run:

```sh
mix test
```

Result:

```text
301 tests, 2 failures
```

Failures:
- `test run_now records monitoring brief errors on the job (BusterClaw.SchedulerTest)` - `Exqlite.Error: Database busy`
- `test run_now full ingests sources then drains analysis (BusterClaw.SchedulerTest)` - `Exqlite.Error: Database busy`

These look like SQLite contention or test isolation failures rather than assertion failures. The suite is not currently clean.

---

## Recommended Fix Order

1. **MCP tier enforcement** - security boundary bug; highest risk.
2. **Browser sidecar redirect guard** - SSRF bypass when sidecar is enabled.
3. **Webhook action execution** - major user-visible functional gap.
4. **Command catalog/schema alignment** - prevents invalid MCP/API tool calls.
5. **Analysis `max`/`limit` fix** - small, high-confidence correctness fix.
6. **Hook async/timeout semantics** - prevents workflow hangs.
7. **Artifact filename collision prevention** - protects library integrity.
8. **Chat Agent cleanup** - small leak fix.

---

## Follow-Up Test Coverage

- Add MCP tests proving restricted commands are absent from `tools/list` and rejected by `tools/call`.
- Add SSRF redirect tests for the sidecar path, or a sidecar-level request interception test.
- Add webhook side-effect tests for each valid action.
- Add command catalog/schema consistency tests for source, webhook, and delivery enums.
- Add `analysis_run_pending` behavior tests for `max > 1`.
- Add hook timeout/async tests using supervised processes.
- Add artifact collision tests for duplicate same-day titles.
