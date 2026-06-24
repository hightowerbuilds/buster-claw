defmodule BusterClaw.Orchestration do
  @moduledoc """
  Context for the unattended orchestration shift: shifts and their specialist
  shift assignments.

  Shifts power `shift run`, the kill switch, and the Dispatch pull-queue. The
  `BusterClaw.Orchestrator` GenServer watches the active shift for the kill
  switch. All state lives here (SQLite) so a restart resumes from durable state.
  """

  import Ecto.Query

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Orchestration.{Shift, ShiftAssignment}
  alias BusterClaw.Repo

  @topic "orchestration"
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
      shell: present(opt(opts, :shell)) || job.shell,
      unattended: opt(opts, :unattended) == true
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

  def kill_switch_path, do: Artifact.workspace_path(@kill_switch_file)
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

  @doc """
  Increment a shift counter (:dispatched | :done | :failed) by `amount` (default 1).
  A swarm tick passes its sub-run count so fan-out draws against the run-cap budget
  the same as the equivalent number of serial runs.
  """
  def bump_shift(shift, counter, amount \\ 1)

  def bump_shift(%Shift{} = shift, counter, amount)
      when counter in [:dispatched, :done, :failed] and is_integer(amount) and amount > 0 do
    field = :"#{counter}_count"
    {1, _} = Repo.update_all(from(s in Shift, where: s.id == ^shift.id), inc: [{field, amount}])
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
  # Helpers
  # ---------------------------------------------------------------------------

  defp tap_broadcast({:ok, _} = result, event) do
    broadcast(event)
    result
  end

  defp tap_broadcast(other, _event), do: other
end
