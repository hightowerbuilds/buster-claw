defmodule BusterClawWeb.StatusLiveTest do
  use BusterClawWeb.ConnCase

  alias BusterClaw.Calendar
  alias BusterClaw.LocalTime

  test "GET / renders the home shell", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Buster Claw"
    # Browser-style shell: top tab strip + bottom dock (former sidebar).
    assert response =~ ~s(id="tab-strip")
    assert response =~ ~s(phx-hook="TabStrip")
    assert response =~ ~s(id="app-dock")
    # The Connect-GWS panel was removed from the home page; GWS lives at /gws + /setup.
    refute response =~ ~s(id="home-google-workspace-login")
    refute response =~ ~s(id="home-recent-emails")
    refute response =~ "Active key"
    assert response =~ ~s(href="/advanced")
    refute response =~ ~s(href="/webhooks")
    refute response =~ ~s(href="/hooks")
    refute response =~ ~s(href="/integrations")
    refute response =~ ~s(href="/mcp")
    refute response =~ ~s(href="/delivery")
  end

  test "GET / renders today's calendar events", %{conn: conn} do
    today = LocalTime.today()

    {:ok, _event} =
      Calendar.create_event(%{
        event_id: "home-today-event",
        date: today,
        start_time: ~T[09:30:00],
        title: "Home page planning block",
        notes: "Visible on the daily agenda.",
        color: "work"
      })

    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ ~s(id="home-daily-calendar")
    assert response =~ "Home page planning block"
    assert response =~ "09:30"
  end

  test "GET / uses the app-local date for the daily calendar", %{conn: conn} do
    previous = Application.get_env(:buster_claw, :local_today)
    Application.put_env(:buster_claw, :local_today, ~D[2026-05-26])

    on_exit(fn ->
      if previous do
        Application.put_env(:buster_claw, :local_today, previous)
      else
        Application.delete_env(:buster_claw, :local_today)
      end
    end)

    {:ok, _event} =
      Calendar.create_event(%{
        event_id: "home-local-today",
        date: ~D[2026-05-26],
        title: "Local today event"
      })

    {:ok, _event} =
      Calendar.create_event(%{
        event_id: "home-utc-tomorrow",
        date: ~D[2026-05-27],
        title: "UTC tomorrow event"
      })

    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Local today event"
    refute response =~ "UTC tomorrow event"
  end

  test "GET /chat renders the chat shell", %{conn: conn} do
    conn = get(conn, ~p"/chat")
    response = html_response(conn, 200)

    assert response =~ "Supervised local chat session"
    assert response =~ "Chat"
  end
end
