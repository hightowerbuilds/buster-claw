defmodule BusterClaw.Orchestration.Shift do
  @moduledoc "A bounded unattended run (default 12h) during which the Orchestrator dispatches work."
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(active stopped completed)

  schema "shifts" do
    field :started_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :status, :string, default: "active"
    field :job_key, :string, default: "lookout"
    field :job_name, :string, default: "Lookout"
    field :job_description, :string
    field :agent_name, :string
    field :shell, :string
    field :duration_hours, :integer, default: 12
    field :dispatched_count, :integer, default: 0
    field :done_count, :integer, default: 0
    field :failed_count, :integer, default: 0
    field :stopped_reason, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(shift, attrs) do
    shift
    |> cast(attrs, [
      :started_at,
      :ends_at,
      :status,
      :job_key,
      :job_name,
      :job_description,
      :agent_name,
      :shell,
      :duration_hours,
      :dispatched_count,
      :done_count,
      :failed_count,
      :stopped_reason
    ])
    |> validate_required([:started_at, :ends_at, :status, :job_key, :job_name, :duration_hours])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:duration_hours, greater_than: 0, less_than_or_equal_to: 168)
  end
end
