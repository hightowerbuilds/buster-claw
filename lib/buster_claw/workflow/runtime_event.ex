defmodule BusterClaw.Workflow.RuntimeEvent do
  use Ecto.Schema

  import Ecto.Changeset

  schema "runtime_events" do
    field :kind, :string
    field :message, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:kind, :message, :metadata, :occurred_at])
    |> validate_required([:kind, :message, :occurred_at])
  end
end
