defmodule BusterClaw.Orchestration.ShiftAssignment do
  @moduledoc "A specialist role/session running inside a single orchestration shift."
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Orchestration.Shift

  @statuses ~w(active stopped blocked)

  schema "shift_assignments" do
    belongs_to :shift, Shift

    field :role_key, :string
    field :agent_name, :string
    field :shell, :string
    field :status, :string, default: "active"
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :heartbeat_at, :utc_datetime
    field :purpose, :string
    field :dedupe_key, :string
    field :notes, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :shift_id,
      :role_key,
      :agent_name,
      :shell,
      :status,
      :started_at,
      :ended_at,
      :heartbeat_at,
      :purpose,
      :dedupe_key,
      :notes
    ])
    |> validate_required([:shift_id, :role_key, :status, :started_at])
    |> validate_inclusion(:status, @statuses)
  end
end
