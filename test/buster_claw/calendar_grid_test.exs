defmodule BusterClaw.Calendar.GridTest do
  @moduledoc """
  The calendar's date arithmetic, with no LiveView and no database in the room.

  That is the point of the module existing: every case below is a `Date` in and
  an answer out, so a leap-year clamp or an off-by-one week start is a two-line
  assertion instead of a rendered month someone has to count squares in.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Calendar.Event
  alias BusterClaw.Calendar.Grid

  # An in-memory event. Never inserted — nothing here touches Repo.
  defp event(date, opts \\ []) do
    %Event{
      id: Keyword.get(opts, :id, System.unique_integer([:positive])),
      date: date,
      title: Keyword.get(opts, :title, "Something"),
      start_time: Keyword.get(opts, :start_time),
      end_time: Keyword.get(opts, :end_time),
      color: "neutral"
    }
  end

  describe "week_start/1" do
    test "a Sunday is its own week start" do
      sunday = ~D[2026-08-09]
      assert Date.day_of_week(sunday, :sunday) == 1
      assert Grid.week_start(sunday) == sunday
    end

    test "a Saturday walks back six days" do
      assert Grid.week_start(~D[2026-08-15]) == ~D[2026-08-09]
    end

    test "it crosses a month and a year boundary" do
      assert Grid.week_start(~D[2026-08-01]) == ~D[2026-07-26]
      assert Grid.week_start(~D[2027-01-01]) == ~D[2026-12-27]
    end
  end

  describe "view_range/2" do
    test "month is always six full Sunday-start weeks" do
      {first, last} = Grid.view_range(:month, ~D[2026-08-20])

      assert Date.day_of_week(first, :sunday) == 1
      assert Date.diff(last, first) == 41
      # The grid must contain the whole month it is a grid for.
      assert Date.compare(first, ~D[2026-08-01]) in [:lt, :eq]
      assert Date.compare(last, ~D[2026-08-31]) in [:gt, :eq]
    end

    test "a month starting on a Sunday still gets the full 42 cells" do
      {first, last} = Grid.view_range(:month, ~D[2026-11-14])

      assert first == ~D[2026-11-01]
      assert Date.diff(last, first) == 41
    end

    test "week is Sunday through Saturday around the anchor" do
      assert Grid.view_range(:week, ~D[2026-08-13]) == {~D[2026-08-09], ~D[2026-08-15]}
      # Any day in that week gives the same range.
      assert Grid.view_range(:week, ~D[2026-08-09]) == {~D[2026-08-09], ~D[2026-08-15]}
      assert Grid.view_range(:week, ~D[2026-08-15]) == {~D[2026-08-09], ~D[2026-08-15]}
    end

    test "day is the anchor, twice" do
      assert Grid.view_range(:day, ~D[2026-08-13]) == {~D[2026-08-13], ~D[2026-08-13]}
    end
  end

  describe "build_grid_days/5" do
    test "month yields 42 cells and flags the ones outside the month" do
      {first, last} = Grid.view_range(:month, ~D[2026-08-01])
      days = Grid.build_grid_days(:month, ~D[2026-08-01], [], first, last)

      assert length(days) == 42
      assert Enum.map(days, & &1.date) == Enum.map(0..41, &Date.add(first, &1))

      in_month = days |> Enum.filter(& &1.in_month?) |> Enum.map(& &1.date)
      assert length(in_month) == 31
      assert List.first(in_month) == ~D[2026-08-01]
      assert List.last(in_month) == ~D[2026-08-31]
    end

    test "month places each event on its own day and leaves the rest empty" do
      {first, last} = Grid.view_range(:month, ~D[2026-08-01])
      events = [event(~D[2026-08-13], title: "Standup"), event(~D[2026-08-20], title: "Review")]
      days = Grid.build_grid_days(:month, ~D[2026-08-01], events, first, last)

      by_date = Map.new(days, &{&1.date, &1.events})
      assert [%{title: "Standup"}] = by_date[~D[2026-08-13]]
      assert [%{title: "Review"}] = by_date[~D[2026-08-20]]
      assert by_date[~D[2026-08-14]] == []
    end

    test "week yields 7 cells, all of them in-month" do
      {first, last} = Grid.view_range(:week, ~D[2026-08-13])
      days = Grid.build_grid_days(:week, ~D[2026-08-13], [], first, last)

      assert length(days) == 7
      assert Enum.all?(days, & &1.in_month?)
      assert List.first(days).date == ~D[2026-08-09]
    end

    test "week does not dim a day just because it belongs to the next month" do
      # The week of Aug 30 2026 runs into September. A week view has no
      # out-of-month concept, so nothing in it may be flagged as such.
      {first, last} = Grid.view_range(:week, ~D[2026-08-31])
      days = Grid.build_grid_days(:week, ~D[2026-08-31], [], first, last)

      assert Enum.map(days, & &1.date) |> List.last() == ~D[2026-09-05]
      assert Enum.all?(days, & &1.in_month?)
    end

    test "day yields exactly one cell, carrying only that day's events" do
      {first, last} = Grid.view_range(:day, ~D[2026-08-13])

      events = [
        event(~D[2026-08-13], title: "Today's"),
        event(~D[2026-08-14], title: "Tomorrow's")
      ]

      assert [day] = Grid.build_grid_days(:day, ~D[2026-08-13], events, first, last)
      assert day.date == ~D[2026-08-13]
      assert day.in_month?
      assert [%{title: "Today's"}] = day.events
    end
  end

  describe "group_by_date/1" do
    test "keys events by date" do
      grouped = Grid.group_by_date([event(~D[2026-08-13]), event(~D[2026-08-14])])

      assert Map.keys(grouped) |> Enum.sort() == [~D[2026-08-13], ~D[2026-08-14]]
    end

    test "all-day events sort ahead of timed ones, then by start time" do
      events = [
        event(~D[2026-08-13], title: "Late", start_time: ~T[16:00:00]),
        event(~D[2026-08-13], title: "All day"),
        event(~D[2026-08-13], title: "Early", start_time: ~T[09:00:00])
      ]

      assert %{~D[2026-08-13] => day} = Grid.group_by_date(events)
      assert Enum.map(day, & &1.title) == ["All day", "Early", "Late"]
    end
  end

  describe "shift_anchor/3" do
    test "day and week move by whole days" do
      assert Grid.shift_anchor(:day, ~D[2026-08-13], 1) == ~D[2026-08-14]
      assert Grid.shift_anchor(:day, ~D[2026-08-13], -1) == ~D[2026-08-12]
      assert Grid.shift_anchor(:week, ~D[2026-08-13], 1) == ~D[2026-08-20]
      assert Grid.shift_anchor(:week, ~D[2026-08-13], -1) == ~D[2026-08-06]
    end

    test "month moves by a month and crosses the year in both directions" do
      assert Grid.shift_anchor(:month, ~D[2026-08-13], 1) == ~D[2026-09-13]
      assert Grid.shift_anchor(:month, ~D[2026-12-13], 1) == ~D[2027-01-13]
      assert Grid.shift_anchor(:month, ~D[2026-01-13], -1) == ~D[2025-12-13]
    end

    test "month clamps a day the target month does not have" do
      assert Grid.shift_anchor(:month, ~D[2026-01-31], 1) == ~D[2026-02-28]
      assert Grid.shift_anchor(:month, ~D[2024-01-31], 1) == ~D[2024-02-29]
      assert Grid.shift_anchor(:month, ~D[2026-03-31], -1) == ~D[2026-02-28]
    end

    test "twelve single steps land where one twelve-step does" do
      stepped =
        Enum.reduce(1..12, ~D[2026-08-13], fn _i, d -> Grid.shift_anchor(:month, d, 1) end)

      assert stepped == Grid.shift_anchor(:month, ~D[2026-08-13], 12)
      assert stepped == ~D[2027-08-13]
    end
  end

  describe "header_label/2" do
    test "month names the month and year" do
      assert Grid.header_label(:month, ~D[2026-08-13]) == "August 2026"
    end

    test "week spans its own Sunday to Saturday" do
      assert Grid.header_label(:week, ~D[2026-08-13]) == "Aug 9 – Aug 15, 2026"
    end

    test "a week that crosses a month says both months" do
      assert Grid.header_label(:week, ~D[2026-08-31]) == "Aug 30 – Sep 5, 2026"
    end

    test "day names the weekday and the full date" do
      assert Grid.header_label(:day, ~D[2026-08-13]) == "Thursday, August 13, 2026"
    end
  end

  describe "view_atom/1" do
    test "maps the three view names" do
      assert Grid.view_atom("month") == :month
      assert Grid.view_atom("week") == :week
      assert Grid.view_atom("day") == :day
    end

    test "refuses anything else rather than minting an atom" do
      # The atom table is not garbage collected, so a crafted phx-value-view must
      # raise here rather than become a new atom.
      assert_raise FunctionClauseError, fn -> Grid.view_atom("month'; DROP") end
    end
  end

  describe "format_time/1 and format_event_when/1" do
    test "a time renders 24-hour, anything else renders empty" do
      assert Grid.format_time(~T[09:05:00]) == "09:05"
      assert Grid.format_time(nil) == ""
      assert Grid.format_time("") == ""
    end

    test "an all-day event says so" do
      assert Grid.format_event_when(event(~D[2026-08-13])) == "Thu, Aug 13, 2026 · All day"
    end

    test "a start alone shows just the start" do
      assert Grid.format_event_when(event(~D[2026-08-13], start_time: ~T[09:00:00])) ==
               "Thu, Aug 13, 2026 · 09:00"
    end

    test "a start and end show as a range" do
      event = event(~D[2026-08-13], start_time: ~T[09:00:00], end_time: ~T[10:30:00])
      assert Grid.format_event_when(event) == "Thu, Aug 13, 2026 · 09:00–10:30"
    end

    test "an end without a start is not a range" do
      assert Grid.format_event_when(event(~D[2026-08-13], end_time: ~T[10:30:00])) ==
               "Thu, Aug 13, 2026 · All day"
    end
  end

  describe "normalize_params/1" do
    test "parses dates and times into structs" do
      params =
        Grid.normalize_params(%{
          "date" => "2026-08-13",
          "recur_until" => "2026-09-13",
          "start_time" => "09:00",
          "end_time" => "10:30"
        })

      assert params["date"] == ~D[2026-08-13]
      assert params["recur_until"] == ~D[2026-09-13]
      assert params["start_time"] == ~T[09:00:00]
      assert params["end_time"] == ~T[10:30:00]
    end

    test "drops blanks instead of casting them" do
      params =
        Grid.normalize_params(%{
          "title" => "Standup",
          "date" => "",
          "start_time" => "",
          "frequency" => ""
        })

      assert params == %{"title" => "Standup"}
    end

    test "leaves an unparseable value as the string it arrived as" do
      # The changeset is what reports "is invalid"; silently emptying the field
      # would hide the typo from the operator who made it.
      params = Grid.normalize_params(%{"date" => "not-a-date", "start_time" => "25:99"})

      assert params["date"] == "not-a-date"
      assert params["start_time"] == "25:99"
    end

    test "passes already-parsed structs straight through" do
      params = Grid.normalize_params(%{"date" => ~D[2026-08-13], "start_time" => ~T[09:00:00]})

      assert params["date"] == ~D[2026-08-13]
      assert params["start_time"] == ~T[09:00:00]
    end

    test "accepts a seconds-bearing time as well as HH:MM" do
      assert Grid.normalize_params(%{"start_time" => "09:00:30"})["start_time"] == ~T[09:00:30]
    end

    test "keeps a frequency that is not blank" do
      assert Grid.normalize_params(%{"frequency" => "weekly"})["frequency"] == "weekly"
    end
  end

  describe "ensure_event_id/1 and default_attrs/1" do
    test "mints an id when there is none, or when it is blank" do
      assert %{"event_id" => minted} = Grid.ensure_event_id(%{})
      assert {:ok, _} = Ecto.UUID.cast(minted)

      assert %{"event_id" => replaced} = Grid.ensure_event_id(%{"event_id" => ""})
      assert {:ok, _} = Ecto.UUID.cast(replaced)
    end

    test "keeps an id that is already there, under either key" do
      assert Grid.ensure_event_id(%{"event_id" => "abc"}) == %{"event_id" => "abc"}
      assert Grid.ensure_event_id(%{event_id: "abc"}) == %{event_id: "abc"}
    end

    test "a blank form starts on the given day, neutral, with an id" do
      attrs = Grid.default_attrs(~D[2026-08-13])

      assert attrs.date == ~D[2026-08-13]
      assert attrs.color == "neutral"
      assert {:ok, _} = Ecto.UUID.cast(attrs.event_id)
    end

    test "two blank forms do not share an id" do
      refute Grid.default_attrs(~D[2026-08-13]).event_id ==
               Grid.default_attrs(~D[2026-08-13]).event_id
    end
  end
end
