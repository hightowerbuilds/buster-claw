defmodule BusterClaw.Orchestration.AgentRun do
  @moduledoc "One headless agent invocation (claude/codex) dispatched for a Task."
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Orchestration.Task

  @statuses ~w(running done failed killed timeout)

  schema "agent_runs" do
    belongs_to :task, Task

    field :engine, :string
    field :os_pid, :integer
    field :status, :string, default: "running"
    field :started_at, :utc_datetime
    field :last_heartbeat_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :exit_code, :integer
    field :output_path, :string
    field :error, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :task_id,
      :engine,
      :os_pid,
      :status,
      :started_at,
      :last_heartbeat_at,
      :finished_at,
      :exit_code,
      :output_path,
      :error
    ])
    |> validate_required([:engine, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
