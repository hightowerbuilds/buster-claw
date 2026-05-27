# Scheduler Research: Quantum vs. Oban for Buster Claw

**Date:** 2026-05-26
**Status:** Research / Decision Pending
**Blocked By:** None — this document is intended to unblock `master-roadmap.md` item *"Finish autonomous scheduler ticking and cron parsing"*.

---

## 1. Executive Summary

Buster Claw’s scheduler today is a **manual-run system**. Users can create `scheduler_jobs` with cron expressions, but nothing evaluates those expressions autonomously. The master roadmap and `CUTOVER.md` both identify this as a primary blocker for daily-use autonomy.

This document evaluates the two libraries named in historical roadmaps — **Quantum** and **Oban** — plus a **custom OTP approach** that emerged as a strong contender during analysis. The goal is to select a strategy that:

1. Respects the **SQLite-only** persistence constraint.
2. Requires **no external infrastructure** (no Redis, no PostgreSQL, no message bus).
3. Survives **app restarts** without dropping scheduled work.
4. Integrates cleanly with the **existing `scheduler_jobs` Ecto schema**.
5. Remains **operationally simple** for a single-node, local-first desktop app.

**Preliminary recommendation:** A lightweight **custom `GenServer` scheduler** using the `crontab` library is the best fit. Quantum is viable but offers little advantage over a custom process for this use case. Oban is architecturally mismatched due to its PostgreSQL dependency.

---

## 2. Buster Claw Constraints

Before evaluating libraries, restate the operational boundaries:

| Constraint | Implication |
|------------|-------------|
| **SQLite only** | Any library requiring PostgreSQL-specific features (LISTEN/NOTIFY, advisory locks, SKIP LOCKED) is disqualified or requires a second database. |
| **Single-node / local-first** | No clustering, no distributed Erlang, no Redis shared state. Everything runs in one BEAM VM. |
| **Existing schema** | `scheduler_jobs` already stores `job_id`, `type`, `cron`, `enabled`, `last_run_at`, `next_run_at`, `last_error`. The solution should leverage this table, not replace it. |
| **Execution logic exists** | `BusterClaw.Scheduler.run_now/1` and `execute/1` already handle job dispatch. The missing piece is the *tick loop* that decides **when** to call them. |
| **No new heavy deps** | The project prefers minimal dependency surface. `mix precommit` must stay fast. |
| **PubSub integration** | LiveViews already subscribe to workflow topics. The scheduler should broadcast `:scheduler_job_started`, `:scheduler_job_finished`, etc. |

---

## 3. Option A: Quantum

### 3.1 What It Is

`quantum-core` (commonly just **Quantum**) is a cron-like job scheduler for Elixir. It runs as a supervised set of GenServers inside your OTP application. Jobs are defined as Elixir functions or MFA tuples and triggered according to standard cron expressions.

### 3.2 How It Works

Quantum maintains an in-memory job registry. A **clock process** ticks every minute, compares the current time against registered cron expressions, and spawns a **task process** for each matching job.

```elixir
# Typical Quantum configuration (config/runtime.exs or application start)
config :my_app, MyApp.Scheduler,
  jobs: [
    {"*/5 * * * *", fn -> IO.puts("every 5 min") end},
    {"0 9 * * *", {MyApp.Worker, :perform, []}}
  ]
```

Jobs can be added/removed at runtime via the `Quantum` API, but they live in the **running VM’s memory**. If the VM restarts, runtime-added jobs are lost unless you repopulate them from a database during application startup.

### 3.3 Integration Sketch for Buster Claw

Because Buster Claw already persists jobs in SQLite, a Quantum integration would look like this:

1. **On app boot**, read all `enabled` rows from `scheduler_jobs` and call `Quantum.add_job/2` for each.
2. **At runtime**, when a user creates/edits/deletes a job via `SchedulerLive`, mirror that change into Quantum’s in-memory registry.
3. **Quantum job action**: Instead of doing work directly, the Quantum job calls `BusterClaw.Scheduler.run_now(job_id)`.
4. **On crash/restart**, the `BusterClaw.Application` startup sequence re-hydrates Quantum from the DB.

```elixir
defmodule BusterClaw.Scheduler.QuantumBridge do
  @moduledoc "Re-hydrates Quantum from scheduler_jobs on boot."

  alias BusterClaw.{Repo, Scheduler}
  alias BusterClaw.Automation.SchedulerJob

  def sync_jobs do
    SchedulerJob
    |> Repo.all()
    |> Enum.filter(& &1.enabled)
    |> Enum.each(&register/1)
  end

  defp register(%SchedulerJob{job_id: id, cron: cron}) do
    # Quantum supports runtime registration
    Quantum.add_job(BusterClaw.Scheduler.Quantum, %Quantum.Job{
      schedule: Crontab.CronExpression.Parser.parse!(cron),
      task: fn -> Scheduler.run_now(id) end
    })
  end
end
```

### 3.4 Pros

- **Battle-tested** in production Elixir apps.
- **Cron expression support** is robust (uses `crontab` library internally).
- **Time zone support** out of the box.
- **Clustering support** exists (irrelevant for Buster Claw, but proves maturity).
- **Overrun protection**: can prevent a job from starting if the previous instance is still running.

### 3.5 Cons

- **State duplication**: The ground truth for jobs is the SQLite `scheduler_jobs` table, but Quantum keeps a copy in-memory. Every CRUD operation must touch both places or risk drift.
- **No durability guarantees**: If the VM crashes between a job firing and `run_now/1` completing, Quantum has no built-in retry or persistence mechanism. The `scheduler_jobs` table would record `last_run_at`, but a mid-crash job might leave no trace.
- **Boot-order dependency**: You must ensure `sync_jobs/0` runs after `Repo` is up but before the web endpoint starts accepting traffic that might trigger jobs.
- **Additional dependency**: Adds `quantum` + `crontab` to the dependency tree.
- **Overlap with existing schema**: Quantum has its own job struct. Mapping it to `SchedulerJob` is boilerplate.

---

## 4. Option B: Oban

### 4.1 What It Is

**Oban** is a durable, reliable job processor for Elixir. Unlike Quantum, which is a *scheduler*, Oban is a *queue*. Jobs are inserted into a database table, and worker processes pull them off, execute them, and record the result. It supports retries, backoff, rate limiting, batch jobs, and cron-like scheduling via the `Oban.Plugins.Cron` plugin.

### 4.2 How It Works

Oban relies on **PostgreSQL** for:

- **Job storage** (`oban_jobs` table).
- **Atomic job fetching** via `FOR UPDATE SKIP LOCKED`.
- **PubSub-like notifications** via `LISTEN/NOTIFY` so workers wake immediately when new jobs are inserted.
- **Transactional safety**: Enqueuing a job and updating application state can happen in the same SQL transaction.

```elixir
# Enqueue a job
Oban.insert(MyWorker.new(%{id: 1}))

# Cron plugin
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Cron, crontab: [
      {"*/5 * * * *", MyWorker, args: %{id: 1}}
    ]}
  ]
```

### 4.3 The SQLite Problem

**Oban OSS (open source) requires PostgreSQL.** Its core engine uses PG-specific SQL and notification channels. There is no official SQLite backend in the free version.

Options to use Oban with SQLite:

1. **Add PostgreSQL as a second database** just for Oban. This violates Buster Claw’s local-first constraint (another binary to manage, data dir complexity, desktop packaging headache).
2. **Oban Pro / Web commercial addons**: These do not add SQLite support either.
3. **Community forks/adapters**: As of mid-2026, there is no widely adopted `oban_sqlite` engine. Relying on an unmaintained fork for core infrastructure is risky.
4. **Oban 3.x (hypothetical future)**: If Oban eventually abstracts the engine, this could change, but betting on it is speculation.

**Verdict:** Oban is effectively **disqualified** unless Buster Claw is willing to adopt PostgreSQL, which would be a major architectural shift.

### 4.4 Hypothetical Integration (If Postgres Were Available)

For completeness, if the project ever accepted Postgres:

1. Replace `scheduler_jobs` with Oban’s `crontab` plugin config, or keep `scheduler_jobs` as a UI-facing table and sync changes into Oban’s plugin state.
2. Define an Oban worker for each `type` (`IngestWorker`, `IntegrationPollWorker`, etc.).
3. Use `Oban.insert/1` for one-off jobs triggered by webhooks or chat commands.
4. Gain durability, retries, and telemetry for free.

This is the *right* tool for a multi-node SaaS, but wrong for a single-node SQLite app.

---

## 5. Option C: Custom GenServer + Crontab

Given that Buster Claw already has:
- A `scheduler_jobs` table.
- A `run_now/1` function that handles execution.
- A PubSub system for broadcasting state changes.
- A hard constraint on SQLite and zero external infra.

…the simplest and most cohesive solution is a **single supervised GenServer** that queries the database, evaluates cron expressions using the `crontab` library, and sleeps until the next scheduled tick.

### 5.1 Architecture

```
+--------------------------------------------------+
|  BusterClaw.Scheduler.Ticker (GenServer)         |
|                                                  |
|  1. On init: query enabled scheduler_jobs        |
|  2. Compute next_run_at for each job             |
|  3. Sleep until min(next_run_at)                 |
|  4. Wake → call Scheduler.run_now(job)           |
|  5. Broadcast :scheduler_job_finished            |
|  6. Recompute next_run_at, goto 3                |
+--------------------------------------------------+
                    |
                    v
        +-------------------------+
        |  scheduler_jobs (SQLite) |
        |  - job_id, cron, enabled |
        |  - last_run_at           |
        |  - next_run_at           |
        +-------------------------+
```

### 5.2 Why This Fits Better Than Quantum

| Factor | Custom Ticker | Quantum |
|--------|---------------|---------|
| Source of truth | `scheduler_jobs` table only | Table + in-memory registry |
| Drift risk | Zero | Possible if DB and Quantum get out of sync |
| Dependency weight | `crontab` only (one small lib) | `quantum` + `crontab` + `gen_stage` |
| Restart behavior | Reads DB on boot, no special sync step | Requires explicit re-hydration step |
| Missed-tick handling | On boot, check if `last_run_at < expected` and run if overdue | Missed ticks are lost unless you use `Quantum.Storage` (more complexity) |
| Observability | Direct: you own the loop, easy to log | Indirect: must hook into Quantum telemetry |

### 5.3 Implementation Sketch

```elixir
defmodule BusterClaw.Scheduler.Ticker do
  @moduledoc """
  Autonomous cron ticker for scheduler_jobs.
  Reads enabled jobs from SQLite, sleeps until the next cron tick,
  and calls BusterClaw.Scheduler.run_now/1.
  """

  use GenServer

  alias BusterClaw.{Repo, Scheduler}
  alias BusterClaw.Automation.SchedulerJob
  alias Crontab.CronExpression.Parser, as: CronParser
  alias Crontab.Scheduler, as: CronScheduler

  @tick_slack_seconds 5

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def force_reschedule do
    GenServer.cast(__MODULE__, :reschedule)
  end

  # --- Callbacks ---

  @impl true
  def init(_) do
    state = schedule_next_tick(%{timer: nil})
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now()

    for job <- due_jobs(now) do
      # Run async so one slow job doesn't block the ticker
      Task.start(fn ->
        broadcast(:scheduler_job_started, job)
        result = Scheduler.run_now(job)
        broadcast(:scheduler_job_finished, job, result)
      end)
    end

    {:noreply, schedule_next_tick(%{state | timer: nil})}
  end

  @impl true
  def handle_cast(:reschedule, state) do
    # Cancel pending timer and recompute
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, schedule_next_tick(%{state | timer: nil})}
  end

  # --- Private ---

  defp schedule_next_tick(state) do
    case next_due_at() do
      nil ->
        # No enabled jobs; check again in 60 seconds
        %{state | timer: Process.send_after(self(), :tick, 60_000)}

      %DateTime{} = dt ->
        ms = max(DateTime.diff(dt, DateTime.utc_now(), :millisecond), 100)
        %{state | timer: Process.send_after(self(), :tick, ms)}
    end
  end

  defp next_due_at do
    enabled_jobs()
    |> Enum.flat_map(&next_occurrence/1)
    |> Enum.min_by(&DateTime.to_unix/1, fn -> nil end)
  end

  defp due_jobs(now) do
    enabled_jobs()
    |> Enum.filter(fn job ->
      case next_occurrence(job) do
        [dt] -> DateTime.diff(now, dt, :second) >= -@tick_slack_seconds
        [] -> false
      end
    end)
  end

  defp enabled_jobs do
    SchedulerJob
    |> where([j], j.enabled == true)
    |> Repo.all()
  end

  defp next_occurrence(%SchedulerJob{cron: cron}) do
    with {:ok, expr} <- CronParser.parse(cron),
         dt <- CronScheduler.get_next_run_date(expr, DateTime.utc_now()) do
      [DateTime.from_naive!(dt, "Etc/UTC")]
    else
      _ -> []
    end
  end

  defp broadcast(event, job, result \\ nil) do
    Phoenix.PubSub.broadcast(
      BusterClaw.PubSub,
      "scheduler",
      {event, %{job_id: job.job_id, result: result}}
    )
  end
end
```

### 5.4 Handling Crashes & Restarts

Because `run_now/1` already updates `last_run_at` and `last_error` in the database, a crash mid-job leaves durable state. On restart, the Ticker simply reads the current `last_run_at` values and computes the next tick from there. There is no "missed job" ambiguity — the cron expression is re-evaluated against wall-clock time.

If a job was supposed to run while the app was offline, the Ticker will **not** auto-catch-up. This is generally correct behavior for a *scheduler* (as opposed to a *queue*). If catch-up is needed later, it can be added by comparing `last_run_at` against the cron expression’s expected occurrences during the downtime window.

### 5.5 Daylight Saving / Time Zone Edge Cases

Buster Claw currently stores `DateTime` in UTC. Cron expressions should be evaluated in UTC unless the user explicitly requests local time. A future enhancement could add a `timezone` column to `scheduler_jobs`, but UTC is the correct default for a local app that may travel across time zones.

---

## 6. Comparative Matrix

| Criterion | Quantum | Oban | Custom Ticker |
|-----------|---------|------|---------------|
| **SQLite compatible** | Yes | No (requires Postgres) | Yes |
| **Zero external infra** | Yes | No | Yes |
| **Survives restart** | Only with custom sync | Yes (durable by design) | Yes (reads DB on boot) |
| **Retries** | No | Yes (built-in) | No (can be added) |
| **Cron parsing** | Yes (via `crontab`) | Yes (via `Oban.Plugins.Cron`) | Yes (via `crontab`) |
| **Dependency count** | Medium (3 libs) | High (Oban + Postgres) | Low (1 lib: `crontab`) |
| **Mapping to `scheduler_jobs`** | Awkward (dual state) | Replace schema | Native (uses schema directly) |
| **Operational complexity** | Low-Medium | High (DB ops) | Low |
| **Scaling story** | Single-node fine | Excellent (multi-node) | Single-node only |
| **Telemetry / Observability** | Good | Excellent | Must be built |

---

## 7. Recommendation

### Primary: Custom GenServer Ticker + `crontab`

For Buster Claw’s constraints, the custom ticker is the clear winner. It:

- Adds only one lightweight dependency (`{:crontab, "~> 1.1"}`).
- Uses the existing `scheduler_jobs` table as the single source of truth.
- Avoids the state-duplication problem inherent in Quantum.
- Avoids the PostgreSQL mandate that disqualifies Oban.
- Keeps the execution path inside `BusterClaw.Scheduler`, which already has logging, event recording, and error handling.

### Secondary: Keep Oban in Mind for a Multi-User Future

If Buster Claw ever becomes a hosted/multi-node service, Oban should be re-evaluated. It is the industry standard for Elixir job processing. At that point, migrating from a custom ticker to Oban is a natural evolution, not a rewrite — the `scheduler_jobs` table maps cleanly to Oban’s cron plugin.

### Quantum is Not Wrong, Just Unnecessary

Quantum is a fine library, but for a single-node app that already has a database table describing jobs, it introduces indirection without adding capability. The custom ticker is ~100 lines of code and has fewer moving parts.

---

## 8. Proposed Implementation Pathway

### Phase 1: Cron Parsing (Immediate)

1. Add `{:crontab, "~> 1.1"}` to `mix.exs`.
2. Add a `validate_cron/1` helper to `BusterClaw.Automation.SchedulerJob`:
   ```elixir
   def validate_cron(changeset) do
     validate_change(changeset, :cron, fn :cron, value ->
       case Crontab.CronExpression.Parser.parse(value) do
         {:ok, _} -> []
         {:error, reason} -> [cron: "invalid cron expression: #{reason}"]
       end
     end)
   end
   ```
3. Update `SchedulerJob.changeset/2` to call `validate_cron/1`.
4. Run `mix precommit`.

### Phase 2: Ticker GenServer

1. Create `lib/buster_claw/scheduler/ticker.ex` (see sketch in §5.3).
2. Add it to the supervision tree in `BusterClaw.Application`:
   ```elixir
   children = [
     # ... existing children ...
     BusterClaw.Scheduler.Ticker
   ]
   ```
3. Ensure it starts after `Repo`.

### Phase 3: PubSub & UI Integration

1. In `SchedulerLive`, subscribe to `"scheduler"` topic.
2. Handle `:scheduler_job_started` and `:scheduler_job_finished` to flash updates or refresh job list.
3. Update `next_run_at` on `scheduler_jobs` when the Ticker computes it (optional but nice for UI display).

### Phase 4: Edge Case Hardening

1. **Overlapping jobs**: If a job’s `run_now/1` takes longer than its cron interval, decide whether to:
   - Skip the overlapping occurrence (default for cron).
   - Allow overlap (spawn in `Task.start`).
   Add an `overlap_policy` field to `scheduler_jobs` if needed.
2. **Clock changes / sleep**: The Ticker uses `Process.send_after`, which is monotonic and unaffected by system clock changes. However, the cron evaluation uses wall-clock `DateTime.utc_now()`. If the system clock jumps forward, the Ticker may miss a tick. Mitigation: on wake, evaluate all jobs within a small slack window (±30s), not just the one next expected job.
3. **App asleep (laptop closed)**: When the laptop wakes, the Ticker should immediately evaluate whether any jobs are overdue. This is handled naturally by the slack-window check on the first `:tick` after wake.

### Phase 5: Migration / Legacy Import

1. Update `docs/rewrite/MIGRATION_PLAN.md` step 10: when importing `Library/scheduler.json`, validate cron expressions using the same `validate_cron` logic. Invalid jobs are imported as `enabled: false` with `last_error` set.
2. Remove "autonomous scheduler loop" from `CUTOVER.md` blockers once Phase 2 lands.

---

## 9. Open Questions

1. **Should the Ticker run jobs synchronously or asynchronously?**
   - Synchronous: simpler backpressure, but a slow job delays the whole loop.
   - Asynchronous (recommended): `Task.start` or `Task.Supervisor.start_child` so the Ticker stays responsive.

2. **Should `next_run_at` be computed and stored in the DB?**
   - Storing it makes the UI informative without querying the Ticker process.
   - The Ticker can update `next_run_at` after each execution.

3. **Should jobs have a `max_duration` or timeout?**
   - If `Ingest.ingest_sources/1` hangs on a slow URL, the job never finishes.
   - A `Task.yield` with a timeout (e.g., 5 minutes) in the Ticker would prevent this.

4. **Should the Ticker support time zones?**
   - For a desktop app, evaluating cron in the user’s local timezone may be surprising if they travel.
   - UTC is safer. Defer timezone support until a user explicitly requests it.

5. **What happens to manual `run_now` calls while the Ticker is running?**
   - They are independent. The Ticker calls `run_now/1`, which is the same function the UI uses. Both update `last_run_at`. No conflict.

---

## 10. References

- Quantum: https://hexdocs.pm/quantum/readme.html
- Crontab: https://hexdocs.pm/crontab/readme.html
- Oban: https://hexdocs.pm/oban/Oban.html
- Buster Claw `master-roadmap.md` (deferral: *Autonomous scheduler loop*)
- Buster Claw `lib/buster_claw/scheduler.ex` (existing execution logic)
- Buster Claw `lib/buster_claw/automation/scheduler_job.ex` (existing schema)
- Buster Claw `docs/rewrite/CUTOVER.md` (blocker: *Scheduler cron parsing and autonomous ticking are not implemented*)
