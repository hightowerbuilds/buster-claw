defmodule BusterClaw.Orchestration.Task do
  @moduledoc """
  A unit of scheduled work the Orchestrator dispatches.

  `type` is `pipeline` (run by existing Elixir workers via `command`) or `agent`
  (run as a headless `claude`/`codex` job from `prompt`). Lease columns
  (`lease_owner`, `lease_expires_at`) let a crashed dispatch be reclaimed without
  double-running. `cron` makes a task recurring; `due_at` makes it one-shot.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Orchestration.AgentRun

  @types ~w(pipeline agent)
  @engines ~w(claude codex)
  @states ~w(pending claimed running done failed cancelled)

  schema "orchestrator_tasks" do
    field :name, :string
    field :type, :string, default: "agent"
    field :engine, :string
    field :command, :string
    field :prompt, :string
    field :params, :map, default: %{}
    field :cron, :string
    field :due_at, :utc_datetime
    field :next_run_at, :utc_datetime
    field :last_run_at, :utc_datetime
    field :enabled, :boolean, default: true
    field :state, :string, default: "pending"
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :result_path, :string
    field :error, :string

    has_many :agent_runs, AgentRun

    timestamps(type: :utc_datetime)
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :name,
      :type,
      :engine,
      :command,
      :prompt,
      :params,
      :cron,
      :due_at,
      :next_run_at,
      :last_run_at,
      :enabled,
      :state,
      :lease_owner,
      :lease_expires_at,
      :attempts,
      :max_attempts,
      :result_path,
      :error
    ])
    |> validate_required([:name, :type, :state])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:state, @states)
    |> validate_engine()
    |> validate_dispatch_target()
  end

  # Agent tasks need a prompt; pipeline tasks need a command.
  defp validate_dispatch_target(changeset) do
    case get_field(changeset, :type) do
      "agent" -> validate_required(changeset, [:prompt])
      "pipeline" -> validate_required(changeset, [:command])
      _ -> changeset
    end
  end

  defp validate_engine(changeset) do
    case get_field(changeset, :engine) do
      nil -> changeset
      _ -> validate_inclusion(changeset, :engine, @engines)
    end
  end
end
