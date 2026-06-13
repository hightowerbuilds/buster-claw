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
  alias BusterClaw.Orchestration.{AgentRun, Shift, ShiftAssignment, Task}
  alias BusterClaw.Repo
  alias BusterClaw.Scheduler.Cron

  @topic "orchestration"
  @default_lease_ms :timer.minutes(30)
  @kill_switch_file "STOP"
  @shift_jobs [
    %{
      key: "lookout",
      name: "Lookout",
      shell: "Primary terminal",
      description:
        "Maintain situational awareness across the workspace, scheduled work, browser state, and incoming signals. Escalate anything that needs a human decision."
    },
    %{
      key: "dispatcher",
      name: "Dispatcher",
      shell: "Ops terminal",
      description:
        "Triage queued tasks, choose the next agent run, and keep the unattended shift moving without overloading the system."
    },
    %{
      key: "scribe",
      name: "Scribe",
      shell: "Notes terminal",
      description:
        "Keep the workspace notes, summaries, and handoff context current so the next operator can pick up cleanly."
    }
  ]
  @shift_assignment_roles [
    %{
      key: "mail-triage",
      name: "Mail Triage",
      shell: "Email terminal",
      purpose: "Handle email review, drafting, follow-up, and handoff inside the current shift."
    },
    %{
      key: "scribe",
      name: "Scribe",
      shell: "Notes terminal",
      purpose: "Keep summaries, notes, and handoff context current during the shift."
    },
    %{
      key: "ci-fix",
      name: "CI Fix",
      shell: "CI terminal",
      purpose: "Investigate failing checks and produce focused fixes while the shift is active."
    },
    %{
      key: "dispatcher",
      name: "Dispatcher",
      shell: "Ops terminal",
      purpose: "Triage queued work and route specialist tasks without starting another shift."
    }
  ]

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  def shift_jobs, do: @shift_jobs

  def shift_job(key) when is_binary(key),
    do: Enum.find(@shift_jobs, &(&1.key == key)) || Enum.find(@shift_jobs, &(&1.name == key))

  def shift_job(_key), do: nil

  def shift_assignment_roles, do: @shift_assignment_roles

  def shift_assignment_role(key) when is_binary(key),
    do:
      Enum.find(@shift_assignment_roles, &(&1.key == key)) ||
        Enum.find(@shift_assignment_roles, &(&1.name == key))

  def shift_assignment_role(_key), do: nil

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:orchestration, event})
    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp shift_attrs(opts) do
    job_key = opt(opts, :job_key) || opt(opts, :job) || "lookout"
    job = shift_job(job_key) || shift_job("lookout")

    %{
      job_key: job.key,
      job_name: present(opt(opts, :job_name)) || job.name,
      job_description: present(opt(opts, :job_description)) || job.description,
      agent_name: present(opt(opts, :agent_name) || opt(opts, :agent)),
      shell: present(opt(opts, :shell)) || job.shell
    }
  end

  defp opt(opts, key) when is_list(opts) do
    opts = Map.new(opts)
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  defp opt(opts, key) when is_map(opts),
    do: Map.get(opts, key) || Map.get(opts, Atom.to_string(key))

  defp opt(_opts, _key), do: nil

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(value), do: value

  defp assignment_attrs(%Shift{} = shift, opts) do
    role_key = present(opt(opts, :role_key) || opt(opts, :role) || opt(opts, :job))
    role = shift_assignment_role(role_key)
    role_key = (role && role.key) || normalize_role_key(role_key || "specialist")

    %{
      shift_id: shift.id,
      role_key: role_key,
      agent_name:
        present(opt(opts, :agent_name) || opt(opts, :agent)) ||
          (role && role.name) || role_title(role_key),
      shell: present(opt(opts, :shell)) || (role && role.shell),
      status: "active",
      started_at: now(),
      heartbeat_at: now(),
      purpose: present(opt(opts, :purpose)) || (role && role.purpose),
      dedupe_key: present(opt(opts, :dedupe_key)),
      notes: present(opt(opts, :notes))
    }
  end

  defp normalize_role_key(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "specialist"
      key -> key
    end
  end

  defp role_title(role_key) do
    role_key
    |> String.split("-", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # ---------------------------------------------------------------------------
  # Shifts
  # ---------------------------------------------------------------------------

  @doc "Start a shift that runs until stopped. Completes any other active shift first."
  def start_shift(opts \\ []) do
    attrs = shift_attrs(opts)

    Enum.each(active_shifts(), &complete_shift(&1, "superseded"))

    %Shift{}
    |> Shift.changeset(Map.merge(attrs, %{started_at: now(), status: "active"}))
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

  @doc "Mark a shift completed (e.g. superseded by a new shift)."
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
    result =
      shift
      |> Shift.changeset(%{status: status, stopped_reason: reason})
      |> Repo.update()

    case result do
      {:ok, updated} ->
        stop_active_assignments(updated)
        result

      error ->
        error
    end
  end

  @doc "Increment a shift counter (:dispatched | :done | :failed)."
  def bump_shift(%Shift{} = shift, counter) when counter in [:dispatched, :done, :failed] do
    field = :"#{counter}_count"
    {1, _} = Repo.update_all(from(s in Shift, where: s.id == ^shift.id), inc: [{field, 1}])
    :ok
  end

  # ---------------------------------------------------------------------------
  # Shift assignments — specialist shells inside one active shift
  # ---------------------------------------------------------------------------

  def active_shift_assignments(nil), do: []

  def active_shift_assignments(%Shift{} = shift) do
    ShiftAssignment
    |> where([a], a.shift_id == ^shift.id and a.status == "active")
    |> order_by([a], asc: a.started_at, asc: a.id)
    |> Repo.all()
  end

  def active_shift_assignments do
    active_shift()
    |> active_shift_assignments()
  end

  def list_shift_assignments(%Shift{} = shift) do
    ShiftAssignment
    |> where([a], a.shift_id == ^shift.id)
    |> order_by([a], desc: a.started_at, desc: a.id)
    |> Repo.all()
  end

  def start_shift_assignment(opts \\ []) do
    case active_shift() do
      nil ->
        {:error, :no_active_shift}

      %Shift{} = shift ->
        attrs = assignment_attrs(shift, opts)
        stop_duplicate_assignment(attrs)

        %ShiftAssignment{}
        |> ShiftAssignment.changeset(attrs)
        |> Repo.insert()
        |> tap_broadcast(:shift_assignment_started)
    end
  end

  def stop_shift_assignment(opts \\ []) do
    status = present(opt(opts, :status)) || "stopped"

    with :ok <- validate_assignment_stop_status(status),
         {:ok, assignment} <- find_assignment_to_stop(opts) do
      assignment
      |> ShiftAssignment.changeset(%{status: status, ended_at: now(), notes: opt(opts, :notes)})
      |> Repo.update()
      |> tap_broadcast(:shift_assignment_stopped)
    end
  end

  def shift_assignment_status(_opts \\ []) do
    shift = active_shift()

    {:ok,
     %{
       active_shift_id: shift && shift.id,
       active_shift?: shift != nil,
       assignments: active_shift_assignments(shift)
     }}
  end

  defp validate_assignment_stop_status(status) when status in ["stopped", "blocked"], do: :ok
  defp validate_assignment_stop_status(_status), do: {:error, :bad_status}

  defp find_assignment_to_stop(opts) do
    query = from(a in ShiftAssignment, where: a.status == "active")

    query =
      cond do
        id = opt(opts, :id) ->
          from(a in query, where: a.id == ^id)

        dedupe_key = present(opt(opts, :dedupe_key)) ->
          from(a in query, where: a.dedupe_key == ^dedupe_key)

        role_key = present(opt(opts, :role_key) || opt(opts, :role) || opt(opts, :job)) ->
          role_key = normalize_role_key(role_key)
          shift = active_shift()
          shift_id = shift && shift.id
          from(a in query, where: a.shift_id == ^shift_id and a.role_key == ^role_key)

        true ->
          from(a in query, where: false)
      end

    case Repo.one(query) do
      nil -> {:error, :not_found}
      assignment -> {:ok, assignment}
    end
  end

  defp stop_duplicate_assignment(%{dedupe_key: dedupe_key} = attrs)
       when is_binary(dedupe_key) and dedupe_key != "" do
    stop_matching_assignments(attrs.shift_id, dynamic([a], a.dedupe_key == ^dedupe_key))
  end

  defp stop_duplicate_assignment(attrs) do
    stop_matching_assignments(attrs.shift_id, dynamic([a], a.role_key == ^attrs.role_key))
  end

  defp stop_matching_assignments(shift_id, condition) do
    ShiftAssignment
    |> where([a], a.shift_id == ^shift_id and a.status == "active")
    |> where(^condition)
    |> Repo.update_all(set: [status: "stopped", ended_at: now(), updated_at: now()])

    :ok
  end

  defp stop_active_assignments(%Shift{} = shift) do
    ShiftAssignment
    |> where([a], a.shift_id == ^shift.id and a.status == "active")
    |> Repo.update_all(set: [status: "stopped", ended_at: now(), updated_at: now()])

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
    shift = active_shift()

    %{
      shift: shift,
      assignments: active_shift_assignments(shift),
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

    # One pass over agent_runs with conditional counts, replacing four separate
    # COUNT queries. Time windows (hour_ago / day_start) match the prior logic
    # exactly. Failed-today counts the "failed"/"timeout"/"killed" terminal states.
    %{running: running, runs_last_hour: runs_last_hour, done_today: done, failed_today: failed} =
      from(r in AgentRun,
        select: %{
          running: fragment("COUNT(CASE WHEN ? = 'running' THEN 1 END)", r.status),
          runs_last_hour: fragment("COUNT(CASE WHEN ? >= ? THEN 1 END)", r.started_at, ^hour_ago),
          done_today:
            fragment(
              "COUNT(CASE WHEN ? = 'done' AND ? >= ? THEN 1 END)",
              r.status,
              r.inserted_at,
              ^day_start
            ),
          failed_today:
            fragment(
              "COUNT(CASE WHEN ? IN ('failed', 'timeout', 'killed') AND ? >= ? THEN 1 END)",
              r.status,
              r.inserted_at,
              ^day_start
            )
        }
      )
      |> Repo.one()

    %{
      running: running,
      max_concurrent: Application.get_env(:buster_claw, :orchestrator_max_concurrent, 3),
      runs_last_hour: runs_last_hour,
      max_runs_per_hour: Application.get_env(:buster_claw, :orchestrator_max_runs_per_hour, 120),
      done_today: done,
      failed_today: failed
    }
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
