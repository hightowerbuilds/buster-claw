defmodule BusterClaw.Calendar.Grid do
  @moduledoc """
  The calendar's date arithmetic: which days a view covers, how they lay out in
  a grid, what the header above them says, and how form params become dates.

  These are questions about dates, not questions about a socket. Nothing here
  reads or writes an assign, so `BusterClawWeb.CalendarComponent` is exercised
  through the browser while this is exercised with `Date` literals and no
  LiveView at all — which is the whole reason it sits in core rather than beside
  the component.

  Weeks start on Sunday, in one place (`week_start/1`). That expression was
  written out three times before this module existed, and three copies of a
  `Date.day_of_week/2` offset is exactly the shape that drifts by one.

  `BusterClaw.Calendar` is the context that talks to the database; this is the
  arithmetic the calendar surface does to what that context hands back. They are
  separate modules on purpose — nothing here touches `Repo`.
  """

  alias BusterClaw.Calendar.Event

  @doc """
  The first day of `date`'s week, Sunday-start.

  The single definition of "start of week" in the calendar. `Date.day_of_week/2`
  with `:sunday` returns 1 for Sunday, so the offset back is that minus one.
  """
  def week_start(date), do: Date.add(date, -(Date.day_of_week(date, :sunday) - 1))

  # ---- View ranges + grid ----

  @doc "The inclusive `{first, last}` date range a view covers around `anchor`."
  def view_range(:month, anchor) do
    first = Date.beginning_of_month(anchor)
    grid_start = week_start(first)
    grid_end = Date.add(grid_start, 41)
    {grid_start, grid_end}
  end

  def view_range(:week, anchor) do
    start = week_start(anchor)
    {start, Date.add(start, 6)}
  end

  def view_range(:day, anchor), do: {anchor, anchor}

  @doc """
  The day cells a view renders: `%{date:, in_month?:, events:}`, in grid order.

  `events` is pre-sorted (all-day first, then by start time) so the markup never
  has to decide an ordering.
  """
  def build_grid_days(:month, anchor, events, range_start, range_end) do
    month = anchor.month
    by_date = group_by_date(events)

    Enum.map(0..Date.diff(range_end, range_start), fn offset ->
      date = Date.add(range_start, offset)

      %{
        date: date,
        in_month?: date.month == month,
        events: Map.get(by_date, date, [])
      }
    end)
  end

  def build_grid_days(:week, _anchor, events, range_start, range_end) do
    by_date = group_by_date(events)

    Enum.map(0..Date.diff(range_end, range_start), fn offset ->
      date = Date.add(range_start, offset)
      %{date: date, in_month?: true, events: Map.get(by_date, date, [])}
    end)
  end

  def build_grid_days(:day, _anchor, events, range_start, _range_end) do
    by_date = group_by_date(events)
    [%{date: range_start, in_month?: true, events: Map.get(by_date, range_start, [])}]
  end

  @doc "Events keyed by date, each day's list sorted all-day first then by start."
  def group_by_date(events) do
    events
    |> Enum.group_by(& &1.date)
    |> Map.new(fn {date, items} -> {date, Enum.sort_by(items, &sort_key/1)} end)
  end

  defp sort_key(%Event{start_time: nil}), do: {0, ~T[00:00:00]}
  defp sort_key(%Event{start_time: time}), do: {1, time}

  # ---- Header / labels ----

  @doc "The heading above the grid, in the shape that view wants to read."
  def header_label(:month, anchor), do: Elixir.Calendar.strftime(anchor, "%B %Y")

  def header_label(:week, anchor) do
    start = week_start(anchor)
    finish = Date.add(start, 6)

    "#{Elixir.Calendar.strftime(start, "%b %-d")} – #{Elixir.Calendar.strftime(finish, "%b %-d, %Y")}"
  end

  def header_label(:day, anchor),
    do: Elixir.Calendar.strftime(anchor, "%A, %B %-d, %Y")

  # Param-derived input must never mint atoms (the atom table is not GC'd), so
  # the view name maps through explicit clauses instead of String.to_atom/1.
  @doc "The view name from a `phx-value-view`, without minting an atom."
  def view_atom("month"), do: :month
  def view_atom("week"), do: :week
  def view_atom("day"), do: :day

  # ---- Anchor shifts ----

  @doc "Move the anchor one step of `view` in either direction."
  def shift_anchor(:month, anchor, delta), do: shift_month(anchor, delta)
  def shift_anchor(:week, anchor, delta), do: Date.add(anchor, 7 * delta)
  def shift_anchor(:day, anchor, delta), do: Date.add(anchor, delta)

  defp shift_month(date, delta) do
    months = date.year * 12 + date.month - 1 + delta
    year = div(months, 12)
    month = rem(months, 12) + 1
    day = min(date.day, Date.days_in_month(Date.new!(year, month, 1)))
    Date.new!(year, month, day)
  end

  # ---- Formatting ----

  @doc "A `Time` as `HH:MM`; anything else (a nil end time) as an empty string."
  def format_time(%Time{} = time), do: Elixir.Calendar.strftime(time, "%H:%M")
  def format_time(_), do: ""

  @doc "The one-line \"when\" for an event, as the inspect panel shows it."
  def format_event_when(%Event{} = event) do
    parts = [Elixir.Calendar.strftime(event.date, "%a, %b %-d, %Y")]

    parts =
      cond do
        event.start_time && event.end_time ->
          parts ++ ["#{format_time(event.start_time)}–#{format_time(event.end_time)}"]

        event.start_time ->
          parts ++ [format_time(event.start_time)]

        true ->
          parts ++ ["All day"]
      end

    Enum.join(parts, " · ")
  end

  # ---- Form helpers ----

  @doc "The attrs a blank event form starts from."
  def default_attrs(today),
    do: %{date: today, event_id: Ecto.UUID.generate(), color: "neutral"}

  @doc """
  Form params as the changeset wants them: real `Date`/`Time` structs, blanks
  dropped rather than cast.

  Unparseable values are left as the original string on purpose — the changeset
  is what reports them, so the operator sees "is invalid" rather than a silently
  emptied field.
  """
  def normalize_params(params) do
    params
    |> Map.update("date", nil, &parse_date/1)
    |> Map.update("recur_until", nil, &parse_date/1)
    |> Map.update("start_time", nil, &parse_time/1)
    |> Map.update("end_time", nil, &parse_time/1)
    |> Map.update("frequency", nil, &blank_to_nil/1)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc "Mint an `event_id` if the params arrived without one."
  def ensure_event_id(params) do
    case Map.get(params, "event_id") || Map.get(params, :event_id) do
      value when value in [nil, ""] -> Map.put(params, "event_id", Ecto.UUID.generate())
      _value -> params
    end
  end

  defp parse_date(%Date{} = date), do: date
  defp parse_date(""), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> value
    end
  end

  defp parse_date(value), do: value

  defp parse_time(%Time{} = time), do: time
  defp parse_time(""), do: nil
  defp parse_time(nil), do: nil

  defp parse_time(value) when is_binary(value) do
    case Time.from_iso8601(value <> ":00") do
      {:ok, time} ->
        time

      _ ->
        case Time.from_iso8601(value) do
          {:ok, time} -> time
          _ -> value
        end
    end
  end

  defp parse_time(value), do: value

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
