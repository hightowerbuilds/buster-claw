defmodule BusterClaw.CalendarTest do
  use BusterClaw.DataCase

  alias BusterClaw.Calendar
  alias BusterClaw.LocalTime

  test "creates, updates, lists, and deletes calendar events" do
    assert {:ok, event} =
             Calendar.create_event(%{
               event_id: "event-1",
               date: ~D[2026-05-07],
               title: "Rewrite planning",
               notes: "Phase 2"
             })

    assert [^event] = Calendar.list_events()

    assert {:ok, event} = Calendar.update_event(event, %{title: "SQLite planning"})
    assert event.title == "SQLite planning"

    assert {:ok, _} = Calendar.delete_event(event)
    assert [] = Calendar.list_events()
  end

  test "sync_external_events upserts a prefix and prunes stale rows without touching others" do
    # A row under the prefix that should be pruned, plus an unrelated row that must
    # survive — exercises the single prefix query + in-memory create/update.
    {:ok, _stale} =
      Calendar.create_event(%{
        event_id: "google-calendar:1:primary:stale",
        date: ~D[2026-05-01],
        title: "Stale import"
      })

    {:ok, other} =
      Calendar.create_event(%{
        event_id: "manual:keep",
        date: ~D[2026-05-02],
        title: "Hand-entered"
      })

    attrs = [
      %{event_id: "google-calendar:1:primary:keep", date: ~D[2026-05-03], title: "Imported"}
    ]

    assert {:ok, result} = Calendar.sync_external_events("google-calendar:1:primary:", attrs)
    assert result.created == 1
    assert result.deleted == 1

    ids = Calendar.list_events() |> Enum.map(& &1.event_id) |> Enum.sort()
    assert ids == ["google-calendar:1:primary:keep", "manual:keep"]
    assert Calendar.get_event!(other.id)
  end

  test "events_by_event_ids returns a map keyed by event_id" do
    {:ok, a} = Calendar.create_event(%{event_id: "by-id-a", date: ~D[2026-05-01], title: "A"})
    {:ok, _b} = Calendar.create_event(%{event_id: "by-id-b", date: ~D[2026-05-02], title: "B"})

    map = Calendar.events_by_event_ids(["by-id-a", "missing"])
    assert Map.keys(map) == ["by-id-a"]
    assert map["by-id-a"].id == a.id
  end

  test "local today can be overridden for UI date boundaries" do
    previous = Application.get_env(:buster_claw, :local_today)
    Application.put_env(:buster_claw, :local_today, ~D[2026-05-26])

    on_exit(fn ->
      if previous do
        Application.put_env(:buster_claw, :local_today, previous)
      else
        Application.delete_env(:buster_claw, :local_today)
      end
    end)

    assert LocalTime.today() == ~D[2026-05-26]
  end
end
