defmodule BusterClawWeb.CalendarLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Calendar
  alias BusterClaw.LocalTime

  test "creates, edits, and deletes a calendar event from the UI", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, BusterClawWeb.CalendarLive)

    # Month-grid header renders the current month
    today = LocalTime.today()
    month_name = Elixir.Calendar.strftime(today, "%B %Y")
    assert html =~ month_name

    # Create
    html =
      view
      |> form("#event-form", %{
        event: %{
          date: "#{today.year}-#{pad(today.month)}-15",
          title: "Rewrite planning",
          notes: "Memory and calendar phase"
        }
      })
      |> render_submit()

    assert html =~ "Event saved."
    assert html =~ "Rewrite planning"
    assert [event] = Calendar.list_events()

    # Click event chip → opens detail view
    view
    |> element("li[phx-click='inspect'][phx-value-id='#{event.id}']")
    |> render_click()

    # Click Edit button in detail view → opens form
    view
    |> element("button[phx-click='edit'][phx-value-id='#{event.id}']")
    |> render_click()

    html =
      view
      |> form("#event-form", %{
        event: %{
          date: "#{today.year}-#{pad(today.month)}-16",
          title: "Importer follow-up",
          notes: "Verify legacy fixtures"
        }
      })
      |> render_submit()

    assert html =~ "Importer follow-up"
    assert [%{title: "Importer follow-up"} = event] = Calendar.list_events()

    # Delete via the inspect view's Delete button
    view
    |> element("li[phx-click='inspect'][phx-value-id='#{event.id}']")
    |> render_click()

    html =
      view
      |> element("button[phx-click='delete'][phx-value-id='#{event.id}']")
      |> render_click()

    assert html =~ "Event deleted."
    assert [] = Calendar.list_events()
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end
