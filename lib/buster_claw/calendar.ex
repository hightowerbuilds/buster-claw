defmodule BusterClaw.Calendar do
  @moduledoc "User-authored calendar events."

  alias BusterClaw.Calendar.Event
  alias BusterClaw.Repo

  def list_events, do: Repo.all(Event)
  def get_event!(id), do: Repo.get!(Event, id)
  def create_event(attrs), do: %Event{} |> Event.changeset(attrs) |> Repo.insert()
  def update_event(%Event{} = event, attrs), do: event |> Event.changeset(attrs) |> Repo.update()
  def delete_event(%Event{} = event), do: Repo.delete(event)
end
