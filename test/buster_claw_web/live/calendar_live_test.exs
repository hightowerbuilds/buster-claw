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

    # The form lives in a modal now: absent until Add Events opens it.
    refute html =~ "event-form"
    html = view |> element("#calendar-add-events") |> render_click()
    assert html =~ "Add Event"

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
    # Saving closes the modal.
    refute html =~ "event-form"
    assert [event] = Calendar.list_events()

    # Click event chip → opens detail view
    view
    |> element("li[phx-click='inspect'][phx-value-id='#{event.id}']")
    |> render_click()

    # Click Edit button in detail view → opens the modal in edit mode
    html =
      view
      |> element("button[phx-click='edit'][phx-value-id='#{event.id}']")
      |> render_click()

    assert html =~ "Edit Event"

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

  test "the modal opens from a day cell with the date filled, and closes clean", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, BusterClawWeb.CalendarLive)
    refute html =~ "event-form"

    # Clicking a day is the "add something on this date" gesture.
    today = LocalTime.today()
    date = Date.to_iso8601(Date.beginning_of_month(today))
    html = view |> element("button[phx-value-date='#{date}']") |> render_click()

    assert html =~ "Add Event"
    assert html =~ ~s(value="#{date}")

    # Cancel closes and abandons the draft; a later open starts clean.
    html = view |> element("#event-form button", "Cancel") |> render_click()
    refute html =~ "event-form"
    assert Calendar.list_events() == []
  end

  test "a crafted non-integer event id does not crash the LiveView", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, BusterClawWeb.CalendarLive)

    # A malformed phx-value-id would raise on Calendar.get_event!/1; the guarded
    # handlers must swallow it and keep the view alive. The calendar now lives in
    # a LiveComponent, so route the events through a component-owned element
    # (#calendar-grid carries phx-target) rather than the root LiveView.
    grid = element(view, "#calendar-grid")
    assert render_hook(grid, "inspect", %{"id" => "not-a-number"})
    assert render_hook(grid, "edit", %{"id" => "not-a-number"})
    assert render_hook(grid, "delete", %{"id" => "999999999"})
    assert Process.alive?(view.pid)
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end
