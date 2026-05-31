defmodule BusterClaw.Orchestration do
  @moduledoc """
  Context for the unattended orchestration shift: shifts, scheduled
  `orchestrator_tasks`, and their `agent_runs`.

  The deterministic `BusterClaw.Orchestrator` GenServer drives this — selecting
  due tasks, claiming them under a lease, dispatching, and recording outcomes.
  All state lives here (SQLite) so a restart resumes from durable state; leases
  with expiry let a crashed dispatch be reclaimed without double-running.
  """

  import Ecto.Query

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Orchestration.{AgentRun, Shift, Task}
  alias BusterClaw.Repo
  alias BusterClaw.Scheduler.Cron

  @topic "orchestration"
  @default_shift_hours 12
  @default_lease_ms :timer.minutes(30)
  @kill_switch_file "STOP"

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:orchestration, event})
    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # ---------------------------------------------------------------------------
  # Shifts
  # ---------------------------------------------------------------------------

  @doc "Start a shift (default 12h). Completes any other active shift first."
  def start_shift(opts \\ []) do
    hours = Keyword.get(opts, :hours, @default_shift_hours)
    started = now()
    ends = DateTime.add(started, hours * 3600, :second)

    Enum.each(active_shifts(), &complete_shift(&1, "superseded"))

    %Shift{}
    |> Shift.changeset(%{started_at: started, ends_at: ends, status: "active"})
    |> Repo.insert()
    |> tap_broadcast(:shift_started)
  end

  @doc "The current active shift, or nil."
  def active_shift do
    Shift
    |> where([s], s.status == "active")
    |> order_by([s], desc: s.started_at)
    |> limit(1)
    |> Repo.one()
  end

  def shift_active?, do: active_shift() != nil

  @doc "The most recent shift regardless of status (e.g. to read why it stopped)."
  def latest_shift do
    Shift |> order_by([s], desc: s.started_at) |> limit(1) |> Repo.one()
  end

  # --- kill switch (a STOP file in the workspace the Orchestrator checks) ---

  def kill_switch_path, do: Path.join(Artifact.workspace_root(), @kill_switch_file)
  def kill_switch_engaged?, do: File.exists?(kill_switch_path())
  def engage_kill_switch, do: File.write(kill_switch_path(), "stop\n")

  def clear_kill_switch do
    _ = File.rm(kill_switch_path())
    :ok
  end

  defp active_shifts do
    Shift |> where([s], s.status == "active") |> Repo.all()
  end

  @doc "Stop the active shift (kill switch / manual / cap breach)."
  def stop_shift(reason \\ "manual") do
    case active_shift() do
      nil -> {:error, :no_active_shift}
      shift -> shift |> set_shift_status("stopped", reason) |> tap_broadcast(:shift_stopped)
    end
  end

  @doc "Mark a shift completed (window elapsed)."
  def complete_shift(shift \\ nil, reason \\ nil)

  def complete_shift(nil, reason) do
    case active_shift() do
      nil -> {:error, :no_active_shift}
      shift -> complete_shift(shift, reason)
    end
  end

  def complete_shift(%Shift{} = shift, reason),
    do: shift |> set_shift_status("completed", reason) |> tap_broadcast(:shift_completed)

  defp set_shift_status(%Shift{} = shift, status, reason) do
    shift
    |> Shift.changeset(%{status: status, stopped_reason: reason})
    |> Repo.update()
  end

  @doc "Increment a shift counter (:dispatched | :done | :failed)."
  def bump_shift(%Shift{} = shift, counter) when counter in [:dispatched, :done, :failed] do
    field = :"#{counter}_count"
    {1, _} = Repo.update_all(from(s in Shift, where: s.id == ^shift.id), inc: [{field, 1}])
    :ok
  end

  # ---------------------------------------------------------------------------
  # Tasks — CRUD
  # ---------------------------------------------------------------------------

  def list_tasks do
    Task |> order_by([t], asc: t.name) |> Repo.all()
  end

  def get_task!(id), do: Repo.get!(Task, id)
  def get_task(id), do: Repo.get(Task, id)

  def create_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
    |> tap_broadcast(:task_created)
  end

  def update_task(%Task{} = task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Repo.update()
    |> tap_broadcast(:task_updated)
  end

  def delete_task(%Task{} = task) do
    task |> Repo.delete() |> tap_broadcast(:task_deleted)
  end

  def change_task(%Task{} = task \\ %Task{}, attrs \\ %{}), do: Task.changeset(task, attrs)

  # ---------------------------------------------------------------------------
  # Tasks — scheduling, leasing, lifecycle
  # ---------------------------------------------------------------------------

  @doc "Give cron tasks without a next_run_at their first scheduled time."
  def ensure_next_runs(at \\ nil) do
    at = at || now()

    Task
    |> where([t], t.enabled == true and not is_nil(t.cron) and is_nil(t.next_run_at))
    |> Repo.all()
    |> Enum.each(fn task ->
      case Cron.next_run(task.cron, at) do
        {:ok, next} -> update_task(task, %{next_run_at: DateTime.truncate(next, :second)})
        _ -> :ok
      end
    end)
  end

  @doc "Enabled, pending tasks whose due_at/next_run_at has arrived."
  def list_due_tasks(at \\ nil) do
    at = at || now()

    Task
    |> where([t], t.enabled == true and t.state == "pending")
    |> where(
      [t],
      (not is_nil(t.due_at) and t.due_at <= ^at) or
        (not is_nil(t.next_run_at) and t.next_run_at <= ^at)
    )
    |> order_by([t], asc: t.next_run_at, asc: t.due_at, asc: t.id)
    |> Repo.all()
  end

  @doc """
  Atomically claim a pending task for `owner` under a lease. Returns
  `{:ok, task}` or `{:error, :not_claimable}` if it was already taken.
  """
  def claim_task(%Task{id: id}, owner, lease_ms \\ @default_lease_ms) do
    expires = DateTime.add(now(), lease_ms, :millisecond) |> DateTime.truncate(:second)

    {count, _} =
      from(t in Task, where: t.id == ^id and t.state == "pending")
      |> Repo.update_all(
        set: [state: "claimed", lease_owner: owner, lease_expires_at: expires, updated_at: now()],
        inc: [attempts: 1]
      )

    case count do
      1 ->
        task = get_task!(id)
        broadcast(:task_updated)
        {:ok, task}

      _ ->
        {:error, :not_claimable}
    end
  end

  @doc "Return claimed/running tasks whose lease expired to the pending pool."
  def reclaim_expired(at \\ nil) do
    at = at || now()

    {count, _} =
      from(t in Task,
        where:
          t.state in ["claimed", "running"] and not is_nil(t.lease_expires_at) and
            t.lease_expires_at < ^at
      )
      |> Repo.update_all(
        set: [state: "pending", lease_owner: nil, lease_expires_at: nil, updated_at: now()]
      )

    if count > 0, do: broadcast(:tasks_reclaimed)
    count
  end

  def mark_running(%Task{} = task) do
    update_task(task, %{state: "running", last_run_at: now()})
  end

  @doc "Record success and either reschedule (cron) or close out (one-shot)."
  def complete_task(%Task{} = task, result_path \\ nil) do
    update_task(task, finish_attrs(task, :done, %{result_path: result_path, error: nil}))
  end

  @doc "Record failure: retry, reschedule (cron), or mark failed at max attempts."
  def fail_task(%Task{} = task, error) do
    update_task(task, finish_attrs(task, :failed, %{error: truncate(error)}))
  end

  defp finish_attrs(%Task{} = task, outcome, extra) do
    base = Map.merge(%{lease_owner: nil, lease_expires_at: nil, last_run_at: now()}, extra)

    cond do
      is_binary(task.cron) and task.cron != "" ->
        next =
          case Cron.next_run(task.cron, now()) do
            {:ok, dt} -> DateTime.truncate(dt, :second)
            _ -> nil
          end

        Map.merge(base, %{state: "pending", next_run_at: next, attempts: 0})

      outcome == :done ->
        Map.put(base, :state, "done")

      task.attempts < task.max_attempts ->
        Map.put(base, :state, "pending")

      true ->
        Map.put(base, :state, "failed")
    end
  end

  # ---------------------------------------------------------------------------
  # Agent runs
  # ---------------------------------------------------------------------------

  def create_run(attrs) do
    %AgentRun{}
    |> AgentRun.changeset(Map.put_new(attrs, :started_at, now()))
    |> Repo.insert()
    |> tap_broadcast(:run_started)
  end

  def update_run(%AgentRun{} = run, attrs) do
    run |> AgentRun.changeset(attrs) |> Repo.update() |> tap_broadcast(:run_updated)
  end

  def heartbeat_run(%AgentRun{} = run), do: update_run(run, %{last_heartbeat_at: now()})

  def list_active_runs do
    AgentRun
    |> where([r], r.status == "running")
    |> order_by([r], asc: r.started_at)
    |> Repo.all()
  end

  def list_recent_runs(limit \\ 10) do
    AgentRun |> order_by([r], desc: r.inserted_at) |> limit(^limit) |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Panel snapshot
  # ---------------------------------------------------------------------------

  @doc "Everything the home OrchestrationPanel needs in one call."
  def snapshot do
    %{
      shift: active_shift(),
      running: running_tasks(),
      upcoming: upcoming_tasks(),
      recent: list_recent_runs(8),
      vitals: vitals()
    }
  end

  @doc """
  Live operational gauges for the active shift: in-flight concurrency, the
  rolling hourly dispatch rate (both against their configured caps), and
  today's done/failed tallies. Computed via cheap aggregate queries.
  """
  def vitals do
    now = now()
    hour_ago = DateTime.add(now, -3600, :second)
    day_start = DateTime.to_date(now) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    %{
      running: count_runs(where: dynamic([r], r.status == "running")),
      max_concurrent: Application.get_env(:buster_claw, :orchestrator_max_concurrent, 3),
      runs_last_hour: count_runs(where: dynamic([r], r.started_at >= ^hour_ago)),
      max_runs_per_hour: Application.get_env(:buster_claw, :orchestrator_max_runs_per_hour, 120),
      done_today:
        count_runs(where: dynamic([r], r.status == "done" and r.inserted_at >= ^day_start)),
      failed_today:
        count_runs(
          where:
            dynamic(
              [r],
              r.status in ["failed", "timeout", "killed"] and r.inserted_at >= ^day_start
            )
        )
    }
  end

  defp count_runs(where: condition) do
    AgentRun |> where(^condition) |> Repo.aggregate(:count, :id)
  end

  defp running_tasks do
    Task
    |> where([t], t.state in ["claimed", "running"])
    |> order_by([t], asc: t.last_run_at)
    |> Repo.all()
  end

  defp upcoming_tasks do
    Task
    |> where([t], t.enabled == true and t.state == "pending")
    |> order_by([t], asc: t.next_run_at, asc: t.due_at, asc: t.id)
    |> limit(8)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tap_broadcast({:ok, _} = result, event) do
    broadcast(event)
    result
  end

  defp tap_broadcast(other, _event), do: other

  defp truncate(nil), do: nil
  defp truncate(text) when is_binary(text), do: String.slice(text, 0, 2000)
  defp truncate(other), do: other |> inspect() |> String.slice(0, 2000)
end
