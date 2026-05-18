defmodule BusterClaw.Calendar.Event do
  use Ecto.Schema

  import Ecto.Changeset

  @colors ~w(neutral work personal social travel health holiday)
  @frequencies ~w(daily weekly monthly)

  schema "calendar_events" do
    field :event_id, :string
    field :date, :date
    field :start_time, :time
    field :end_time, :time
    field :title, :string
    field :notes, :string
    field :color, :string, default: "neutral"
    field :frequency, :string
    field :recur_until, :date

    timestamps(type: :utc_datetime)
  end

  def colors, do: @colors
  def frequencies, do: @frequencies

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_id,
      :date,
      :start_time,
      :end_time,
      :title,
      :notes,
      :color,
      :frequency,
      :recur_until
    ])
    |> validate_required([:event_id, :date, :title])
    |> validate_inclusion(:color, @colors)
    |> validate_inclusion(:frequency, @frequencies)
    |> validate_time_order()
    |> validate_recur_until()
    |> unique_constraint(:event_id)
  end

  defp validate_time_order(changeset) do
    start = get_field(changeset, :start_time)
    finish = get_field(changeset, :end_time)

    cond do
      is_nil(start) or is_nil(finish) -> changeset
      Time.compare(finish, start) == :gt -> changeset
      true -> add_error(changeset, :end_time, "must be later than start time")
    end
  end

  defp validate_recur_until(changeset) do
    date = get_field(changeset, :date)
    until = get_field(changeset, :recur_until)

    cond do
      is_nil(until) -> changeset
      is_nil(date) -> changeset
      Date.compare(until, date) in [:gt, :eq] -> changeset
      true -> add_error(changeset, :recur_until, "must be on or after the start date")
    end
  end
end
