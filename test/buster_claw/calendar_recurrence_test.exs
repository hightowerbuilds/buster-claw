defmodule BusterClaw.CalendarRecurrenceTest do
  use BusterClaw.DataCase

  alias BusterClaw.Calendar

  describe "events_in_range/2" do
    test "non-recurring events appear once when within range" do
      {:ok, _} =
        Calendar.create_event(%{
          event_id: "single",
          date: ~D[2026-06-10],
          title: "One-off"
        })

      assert [event] = Calendar.events_in_range(~D[2026-06-01], ~D[2026-06-30])
      assert event.title == "One-off"
      assert event.date == ~D[2026-06-10]
    end

    test "non-recurring events outside the range are excluded" do
      {:ok, _} =
        Calendar.create_event(%{
          event_id: "outside",
          date: ~D[2026-07-15],
          title: "Far future"
        })

      assert [] = Calendar.events_in_range(~D[2026-06-01], ~D[2026-06-30])
    end

    test "daily recurring events expand to every day in the range" do
      {:ok, _} =
        Calendar.create_event(%{
          event_id: "daily-standup",
          date: ~D[2026-06-01],
          title: "Standup",
          frequency: "daily"
        })

      occurrences = Calendar.events_in_range(~D[2026-06-01], ~D[2026-06-07])
      assert length(occurrences) == 7
      assert Enum.map(occurrences, & &1.date) == Enum.map(0..6, &Date.add(~D[2026-06-01], &1))
    end

    test "weekly recurring events step by 7 days" do
      {:ok, _} =
        Calendar.create_event(%{
          event_id: "weekly-1on1",
          date: ~D[2026-06-01],
          title: "1:1",
          frequency: "weekly"
        })

      occurrences = Calendar.events_in_range(~D[2026-06-01], ~D[2026-06-30])

      assert Enum.map(occurrences, & &1.date) == [
               ~D[2026-06-01],
               ~D[2026-06-08],
               ~D[2026-06-15],
               ~D[2026-06-22],
               ~D[2026-06-29]
             ]
    end

    test "monthly recurring events step by month and clamp on shorter months" do
      {:ok, _} =
        Calendar.create_event(%{
          event_id: "monthly-rent",
          date: ~D[2026-01-31],
          title: "Rent",
          frequency: "monthly"
        })

      occurrences = Calendar.events_in_range(~D[2026-01-01], ~D[2026-04-30])

      assert Enum.map(occurrences, & &1.date) == [
               ~D[2026-01-31],
               ~D[2026-02-28],
               ~D[2026-03-31],
               ~D[2026-04-30]
             ]
    end

    test "recur_until stops the series" do
      {:ok, _} =
        Calendar.create_event(%{
          event_id: "limited-series",
          date: ~D[2026-06-01],
          title: "Sprint",
          frequency: "weekly",
          recur_until: ~D[2026-06-15]
        })

      occurrences = Calendar.events_in_range(~D[2026-06-01], ~D[2026-12-31])
      assert Enum.map(occurrences, & &1.date) == [~D[2026-06-01], ~D[2026-06-08], ~D[2026-06-15]]
    end

    test "occurrences inherit parent attributes (color, time, notes)" do
      {:ok, _} =
        Calendar.create_event(%{
          event_id: "daily-meditate",
          date: ~D[2026-06-01],
          title: "Meditate",
          frequency: "daily",
          color: "health",
          start_time: ~T[07:00:00],
          end_time: ~T[07:15:00],
          notes: "Box breathing"
        })

      [first, second | _] = Calendar.events_in_range(~D[2026-06-01], ~D[2026-06-03])
      assert first.color == "health"
      assert first.start_time == ~T[07:00:00]
      assert second.color == "health"
      assert second.notes == "Box breathing"
      assert second.date == ~D[2026-06-02]
    end
  end
end
