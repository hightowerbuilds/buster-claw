defmodule BusterClaw.Notifications.ScheduleTest do
  @moduledoc """
  The Notify widget's wall-clock arithmetic, asserted directly.

  This logic was pure the whole time and lived inside `StatusLive`, so the only
  way to ask "what does 11:30pm mean when it is 11:45pm" was to drive a mount,
  an event, and a form. Extracted 08-03; these are the cases that were never
  written because writing them was expensive.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.Schedule

  describe "timers count down from now" do
    test "a positive number of minutes lands that far ahead" do
      now = ~U[2026-08-03 12:00:00Z]

      assert {:ok, ~U[2026-08-03 12:25:00Z]} =
               Schedule.fire_at("timer", %{"minutes" => "25"}, now)
    end

    test "whitespace and a trailing unit are tolerated" do
      now = ~U[2026-08-03 12:00:00Z]

      assert {:ok, ~U[2026-08-03 12:05:00Z]} =
               Schedule.fire_at("timer", %{"minutes" => " 5 "}, now)

      assert {:ok, ~U[2026-08-03 12:10:00Z]} =
               Schedule.fire_at("timer", %{"minutes" => "10m"}, now)
    end

    test "zero, negative, empty and non-numeric are refused on the minutes field" do
      now = ~U[2026-08-03 12:00:00Z]

      for value <- ["0", "-5", "", "soon", nil] do
        assert {:error, :minutes, _} = Schedule.fire_at("timer", %{"minutes" => value}, now),
               "expected #{inspect(value)} to be refused"
      end
    end

    test "a missing minutes key is refused rather than defaulted" do
      assert {:error, :minutes, _} = Schedule.fire_at("timer", %{}, ~U[2026-08-03 12:00:00Z])
    end
  end

  describe "alarms and reminders arm the next local occurrence" do
    test "both kinds take the same path" do
      for kind <- ["alarm", "reminder"] do
        assert {:ok, %DateTime{}} = Schedule.fire_at(kind, %{"at" => "07:30"})
      end
    end

    test "an unparseable time is refused on the at field" do
      for value <- ["", "half seven", "25:00", nil] do
        assert {:error, :at, _} = Schedule.fire_at("alarm", %{"at" => value}),
               "expected #{inspect(value)} to be refused"
      end
    end

    test "an unknown kind is refused rather than silently treated as a timer" do
      assert {:error, :label, _} = Schedule.fire_at("countdown", %{"minutes" => "5"})
    end
  end

  describe "next_local_occurrence" do
    test "is always in the future, and within the next 24 hours" do
      # Whatever the machine's clock and offset, both properties must hold —
      # which is the real contract, and testable without pinning a timezone.
      for hour <- [0, 6, 12, 18, 23] do
        result = Schedule.next_local_occurrence(Time.new!(hour, 30, 0))

        assert DateTime.compare(result, DateTime.utc_now()) == :gt,
               "#{hour}:30 resolved to a moment already past"

        assert DateTime.diff(result, DateTime.utc_now(), :second) <= 86_400,
               "#{hour}:30 resolved more than a day out"
      end
    end

    test "the seconds are truncated, so a fire time never carries microseconds" do
      assert %DateTime{microsecond: {0, 0}} = Schedule.next_local_occurrence(~T[09:15:00])
    end
  end

  describe "parsing helpers" do
    test "wall time accepts HH:MM and HH:MM:SS" do
      assert {:ok, ~T[07:30:00]} = Schedule.parse_wall_time("07:30")
      assert {:ok, ~T[07:30:45]} = Schedule.parse_wall_time("07:30:45")
      assert :error = Schedule.parse_wall_time("7:30")
    end

    test "a blank alarm label becomes Alarm; every other kind keeps its own" do
      assert Schedule.default_label("", "alarm") == "Alarm"
      assert Schedule.default_label("", "timer") == ""
      assert Schedule.default_label("Tea", "alarm") == "Tea"
      assert Schedule.default_label("Stand up", "reminder") == "Stand up"
    end
  end
end
