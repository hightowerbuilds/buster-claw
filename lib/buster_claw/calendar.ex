defmodule BusterClaw.Calendar do
  @moduledoc "User-authored calendar events."

  alias BusterClaw.Calendar.Event
  alias BusterClaw.Repo

  def list_events, do: Repo.all(Event)
  def get_event!(id), do: Repo.get!(Event, id)
  def get_event_by_event_id(event_id), do: Repo.get_by(Event, event_id: event_id)
  def create_event(attrs), do: %Event{} |> Event.changeset(attrs) |> Repo.insert()
  def update_event(%Event{} = event, attrs), do: event |> Event.changeset(attrs) |> Repo.update()
  def delete_event(%Event{} = event), do: Repo.delete(event)

  def sync_external_events(prefix, attrs_list) when is_binary(prefix) and is_list(attrs_list) do
    incoming_event_ids = attrs_list |> Enum.map(&event_id!/1) |> MapSet.new()

    existing =
      list_events()
      |> Enum.filter(&String.starts_with?(&1.event_id, prefix))

    stale = Enum.reject(existing, &MapSet.member?(incoming_event_ids, &1.event_id))

    deleted =
      Enum.map(stale, fn event ->
        {:ok, deleted} = delete_event(event)
        deleted
      end)

    {created, updated, events} =
      Enum.reduce(attrs_list, {0, 0, []}, fn attrs, {created, updated, events} ->
        case upsert_external_event(attrs) do
          {:created, event} -> {created + 1, updated, [event | events]}
          {:updated, event} -> {created, updated + 1, [event | events]}
        end
      end)

    {:ok,
     %{
       created: created,
       updated: updated,
       deleted: length(deleted),
       events: Enum.reverse(events),
       deleted_events: deleted
     }}
  end

  @doc """
  Return all event occurrences whose date falls within `range_start..range_end`
  inclusive. Non-recurring events are returned as-is; recurring events are
  expanded into per-occurrence virtual records that share the parent's id but
  carry the occurrence date.

  Each expanded occurrence is a struct identical to the parent `%Event{}` with
  its `:date` field shifted to the occurrence date.
  """
  def events_in_range(%Date{} = range_start, %Date{} = range_end) do
    list_events()
    |> Enum.flat_map(&expand_event(&1, range_start, range_end))
  end

  defp expand_event(%Event{frequency: nil} = event, range_start, range_end) do
    if in_range?(event.date, range_start, range_end), do: [event], else: []
  end

  defp expand_event(%Event{} = event, range_start, range_end) do
    cap = event.recur_until || range_end

    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(&nth_occurrence(event.date, event.frequency, &1))
    |> Stream.take_while(&(Date.compare(&1, cap) != :gt))
    |> Stream.drop_while(&(Date.compare(&1, range_start) == :lt))
    |> Stream.take_while(&(Date.compare(&1, range_end) != :gt))
    |> Enum.map(fn occurrence_date -> %{event | date: occurrence_date} end)
  end

  defp nth_occurrence(base, "daily", n), do: Date.add(base, n)
  defp nth_occurrence(base, "weekly", n), do: Date.add(base, 7 * n)

  defp nth_occurrence(base, "monthly", n) do
    months = base.year * 12 + base.month - 1 + n
    year = div(months, 12)
    month = rem(months, 12) + 1
    day = min(base.day, days_in_month(year, month))
    Date.new!(year, month, day)
  end

  defp days_in_month(year, month) do
    {:ok, d} = Date.new(year, month, 1)
    Date.days_in_month(d)
  end

  defp in_range?(date, range_start, range_end) do
    Date.compare(date, range_start) != :lt and Date.compare(date, range_end) != :gt
  end

  defp upsert_external_event(attrs) do
    event_id = event_id!(attrs)

    case get_event_by_event_id(event_id) do
      nil ->
        {:ok, event} = create_event(attrs)
        {:created, event}

      %Event{} = event ->
        {:ok, event} = update_event(event, attrs)
        {:updated, event}
    end
  end

  defp event_id!(attrs), do: Map.get(attrs, :event_id) || Map.fetch!(attrs, "event_id")
end
