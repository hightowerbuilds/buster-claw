defmodule BusterClawWeb.CalendarLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Calendar

  test "creates, edits, and deletes a calendar event from the UI", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, BusterClawWeb.CalendarLive)
    assert html =~ "No calendar events yet"

    html =
      view
      |> form("#event-form", %{
        event: %{
          date: "2026-05-07",
          title: "Rewrite planning",
          notes: "Memory and calendar phase",
          event_id: "rewrite-planning"
        }
      })
      |> render_submit()

    assert html =~ "Event saved."
    assert html =~ "Rewrite planning"
    assert [event] = Calendar.list_events()

    html =
      view
      |> element("button[phx-click='edit'][phx-value-id='#{event.id}']")
      |> render_click()

    assert html =~ "Edit Event"

    html =
      view
      |> form("#event-form", %{
        event: %{
          date: "2026-05-08",
          title: "Importer follow-up",
          notes: "Verify legacy fixtures",
          event_id: "rewrite-planning"
        }
      })
      |> render_submit()

    assert html =~ "Importer follow-up"
    assert [%{title: "Importer follow-up"} = event] = Calendar.list_events()

    html =
      view
      |> element("button[phx-click='delete'][phx-value-id='#{event.id}']")
      |> render_click()

    assert html =~ "No calendar events yet"
    assert [] = Calendar.list_events()
  end
end
