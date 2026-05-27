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
