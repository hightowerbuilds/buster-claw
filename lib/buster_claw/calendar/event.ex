defmodule BusterClaw.Calendar.Event do
  use Ecto.Schema

  import Ecto.Changeset

  schema "calendar_events" do
    field :event_id, :string
    field :date, :date
    field :title, :string
    field :notes, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_id, :date, :title, :notes])
    |> validate_required([:event_id, :date, :title])
    |> unique_constraint(:event_id)
  end
end
