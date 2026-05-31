# Orchestration — Implementation Plan (2026-05-31)

## Goal

Run an unattended **12-hour "shift"**: a deterministic brain reads the schedule,
dispatches work, and stays running for the full window with **no human in the
loop** — surviving agent crashes, BEAM crashes, app crashes, and reboots.

## Locked decisions

- **Brain = Elixir GenServer**, not an LLM. The thing that must survive 12h is
  deterministic code (OTP/Tauri/launchd can keep it alive); LLM agents are
  disposable and summoned per job.
- **Dispatch:** deterministic jobs (ingest/analyze/integrations/brief) → existing
  Elixir workers; agentic tasks → **headless agent runs**.
- **Agent CLI:** both `claude -p` and `codex exec`, configurable per task,
  **Claude default**.
- **Schedule store:** new **`orchestrator_tasks`** table with lease/claim columns
  (keeps `scheduler_jobs` for deterministic cron).
- **Autonomy:** **full** — no action gating. Backed by kill switch + caps +
  audit + alerts (brakes and a black box, not a gate).
- **Uptime:** packaged `.app` + **launchd KeepAlive** + **no-sleep** power
  assertion during a shift.
- **Surface:** the home **left column** (`home-left-panel` in `StatusLive`) hosts
  a live `OrchestrationPanel`; the daily calendar stays on the right.

## Reliability model — nested watchdogs (none are an LLM)

| Layer | Guards against | Mechanism |
|---|---|---|
| launchd LaunchAgent (KeepAlive) | whole-app crash / reboot | relaunches the `.app` |
| Tauri / Rust | BEAM release exits | monitor child, respawn w/ backoff (new) |
| OTP supervision tree | Orchestrator GenServer crash | `one_for_one` restart |
| `BusterClaw.Orchestrator` | a headless run dies/hangs | per-run timeout + heartbeat; lease expiry re-dispatches |
| No-sleep power assertion | Mac sleeping mid-shift | held while a shift is active |

**Resume, don't persist:** all state lives in SQLite/workspace, never in an
agent's head. Restart re-reads schedule + work-log and continues. Task leases
(`pending → claimed(lease) → running → done/failed`, with lease expiry) prevent
double-dispatch. This also makes context-window/cost a non-issue — every agent
run is fresh and bounded, and the brain can rotate agents freely.

## Data model

- **`orchestrator_tasks`** — `id`, `type` (`:pipeline | :agent`), `engine`
  (`:claude | :codex`, agent tasks), `spec`/`prompt`, `cron` or `due_at`,
  `state`, `lease_owner`, `lease_expires_at`, `attempts`, `max_attempts`,
  `result_path`, `error`, timestamps.
- **`agent_runs`** — `id`, `task_id`, `engine`, `pid`/`os_pid`, `status`,
  `started_at`, `last_heartbeat_at`, `finished_at`, `exit_code`, `output_path`,
  token/cost estimate.
- **`shifts`** — `id`, `started_at`, `ends_at` (start + 12h), `status`
  (`active | stopped | completed`), counters (dispatched/done/failed), `stopped_reason`.

## Components

1. **`BusterClaw.Orchestrator`** (GenServer; extends the `Scheduler.Runner`
   pattern) — ticks (~30s), selects due `orchestrator_tasks`, classifies, leases,
   dispatches; pipeline → Analysis/Ingest/Integrations; agent → `AgentRunner`.
   Retries, backoff, concurrency cap. Broadcasts state on PubSub.
2. **`BusterClaw.AgentRunner`** — spawns `claude -p` / `codex exec` in the
   workspace, wired to the BusterClaw MCP server so the sub-agent can use the
   command surface; full-autonomy flags; timeout/kill; captures output to
   `shift/<date>/` + `runtime_events`; bounded concurrency via DynamicSupervisor.
3. **`OrchestrationPanel`** (home left column) — shift header (On/Off, time left,
   Start/Stop, **kill switch**), Now running (heartbeat/liveness + elapsed),
   Up next, Recently done (links to artifacts), vitals (concurrency/rate/budget),
   alerts. Live via PubSub (`shift`, `orchestrator_tasks`, `agent_runs`,
   `runtime_events`).
4. **Tauri** — respawn the release on unexpected exit; hold a no-sleep assertion
   during a shift.
5. **launchd** — install/enable a `KeepAlive` LaunchAgent on shift start, disable
   on shift end.
6. **Task playbook** — standing prompt template(s) in the workspace (sibling to
   `Introduction.ex`) telling each dispatched agent its role, the task, how to
   call BusterClaw MCP commands, where to write results, and how to report
   done/failed.
7. **MCP/command surface additions** — `orchestrator_heartbeat`,
   `orchestrator_task_*` (list/claim/complete/fail), `shift_status`, `shift_stop`.

## Safety rails (full autonomy, no gating)

- **Kill switch** — UI button + a `STOP` sentinel file checked each tick; halts
  dispatch and kills running agents immediately.
- **Caps** — max concurrent agents, runs/hour, token/$ budget per shift; on
  breach → pause + alert.
- **Black box** — every dispatch and every MCP command sub-agents run is
  Sentinel-audited.
- **Alerts** — crash-loop / stuck job / cap breach / shift end → notify via the
  existing Delivery layer.
- URLGuard SSRF protection stays.

## Phases

- **Phase 1 (dev):** `orchestrator_tasks`/`agent_runs`/`shifts` schema +
  `Orchestrator` + `AgentRunner` + `OrchestrationPanel` in the home left column.
  Dispatch a pipeline job and a headless agent task end-to-end on
  `mix phx.server`. Kill switch + caps + audit.
- **Phase 2:** resilience — Tauri respawn-on-exit, agent heartbeat/timeout,
  backoff, Delivery alerts.
- **Phase 3:** unattended packaging — launchd LaunchAgent + no-sleep + shift
  start/stop wired to the panel; real 12h dry-run.
- **Phase 4:** polish — morning report, richer vitals/history.

## Risks / watch-items

- **Full autonomy unattended** — relies on the kill switch, caps, and alerts;
  the dispatch prompt/playbook quality is the main lever on behavior.
- **Headless agent auth/limits** — API rate limits and cost over 12h; needs
  backoff in `AgentRunner` and per-shift budget caps.
- **MCP availability in headless runs** — sub-agents must reach the BusterClaw
  MCP server (loopback + token); confirm the headless invocation passes config.
- **launchd + no-sleep** — must verify the LaunchAgent survives logout and the
  power assertion actually prevents sleep.
