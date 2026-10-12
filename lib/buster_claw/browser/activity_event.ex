defmodule BusterClaw.Browser.ActivityEvent do
  @moduledoc "A browser action's receipt, without page contents or entered values."
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [:id, :source, :run_id, :action, :outcome, :url, :duration_ms, :inserted_at]}
  schema "browser_activity_events" do
    field :source, :string
    field :run_id, :string
    field :action, :string
    field :outcome, :string
    field :url, :string
    field :duration_ms, :integer
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:source, :run_id, :action, :outcome, :url, :duration_ms])
    |> validate_required([:source, :action, :outcome])
    |> validate_inclusion(:source, ~w(shared agent))
    |> validate_length(:run_id, max: 160)
    |> validate_length(:action, max: 60)
    |> validate_length(:outcome, max: 60)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
  end
end
