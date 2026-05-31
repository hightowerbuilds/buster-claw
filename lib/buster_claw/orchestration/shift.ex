defmodule BusterClaw.Orchestration.Shift do
  @moduledoc "A bounded unattended run (default 12h) during which the Orchestrator dispatches work."
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(active stopped completed)

  schema "shifts" do
    field :started_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :status, :string, default: "active"
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
      :dispatched_count,
      :done_count,
      :failed_count,
      :stopped_reason
    ])
    |> validate_required([:started_at, :ends_at, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
