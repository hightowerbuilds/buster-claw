defmodule BusterClawWeb.StatusLiveTest do
  use BusterClawWeb.ConnCase

  alias BusterClaw.Calendar
  alias BusterClaw.LocalTime
  alias BusterClaw.Orchestration

  test "GET / renders the home shell", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Buster Claw"
    # Browser-style shell: top tab strip + bottom dock (former sidebar).
    assert response =~ ~s(id="tab-strip")
    assert response =~ ~s(phx-hook="TabStrip")
    assert response =~ ~s(id="app-dock")
    assert response =~ ~s(id="home-shift-management")
    assert response =~ "No shift shell open."
    refute response =~ ~s(id="shift-assignment-form")
    refute response =~ ~s(id="shift-start-button")
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

  test "home displays the shell currently on shift", %{conn: conn} do
    {:ok, _shift} =
      Orchestration.start_shift(
        job: "lookout",
        agent_name: "Codex",
        shell: "Terminal 1",
        hours: 12
      )

    {:ok, _assignment} =
      Orchestration.start_shift_assignment(
        role_key: "mail-triage",
        agent_name: "Mail Triage",
        shell: "Email terminal",
        purpose: "Handle incoming email."
      )

    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ ~s(id="home-shift-management")
    assert response =~ ~s(id="shift-shell-open-status")
    assert response =~ ~s(id="shift-active-assignments")
    assert response =~ "Shell open"
    assert response =~ "Lookout"
    assert response =~ "Codex"
    assert response =~ "Terminal 1"
    assert response =~ "Mail Triage"
    assert response =~ "Email terminal"
    refute response =~ ~s(id="shift-assignment-form")
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
end
