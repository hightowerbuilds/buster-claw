defmodule BusterClawWeb.StatusLiveTest do
  # async: false — points the global :workspace_root at a tmp trusted-senders file.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Calendar
  alias BusterClaw.LocalTime

  setup do
    root = Path.join(System.tmp_dir!(), "bc_status_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "memory"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "GET / renders the home shell with the trusted-contacts panel", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Buster Claw"
    # Browser-style shell: top tab strip + bottom dock (former sidebar).
    assert response =~ ~s(id="tab-strip")
    assert response =~ ~s(phx-hook="TabStrip")
    assert response =~ ~s(id="app-dock")
    # Left column: Get Started explainer on top, trusted-contacts manager below.
    assert response =~ ~s(id="home-get-started")
    assert response =~ "Get Started"
    assert response =~ "Go on duty"
    assert response =~ "./buster-claw shift run"
    # Get Started no longer links to the Financial Informant (it moved to Featured Pages).
    refute response =~ ~s(href="/finance")
    assert response =~ ~s(id="home-left-panel")
    assert response =~ "Trusted Contacts"
    assert response =~ "No trusted contacts yet."
    # Featured Pages links to both bundled HTML pages, opened in the in-app browser.
    assert response =~ ~s(id="home-featured-pages")
    assert response =~ "Featured Pages"
    assert response =~ "/browse?url="
    assert response =~ "pages%2FMANUAL.html"
    assert response =~ "pages%2Ffinancial-informant.html"
    assert response =~ "Financial Informant"
    refute response =~ ~s(id="home-shift-management")
    # The Connect-GWS panel was removed from the home page; GWS lives at /gws + /setup.
    refute response =~ ~s(id="home-google-workspace-login")
    refute response =~ ~s(id="home-recent-emails")
    # Advanced was retired; its surviving feature (Integrations) lives under Settings.
    refute response =~ ~s(href="/advanced")
    refute response =~ ~s(href="/webhooks")
    refute response =~ ~s(href="/mcp")
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

  test "lists existing trusted contacts, marking domain wildcards", %{conn: conn, root: root} do
    File.write!(
      Path.join(root, "memory/trusted-email-senders.md"),
      "# Trusted\n\n- alice@example.com\n- *@acme.com\n"
    )

    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "alice@example.com"
    assert response =~ "*@acme.com"
    refute response =~ "No trusted contacts yet."
  end

  test "adds and removes a trusted contact from the home panel", %{conn: conn} do
    # Use an address that does NOT appear in the input placeholder text.
    contact = "dana@example.org"

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "No trusted contacts yet."
    refute html =~ contact

    html =
      view
      |> form(~s(form[phx-submit="add_contact"]), %{"entry" => contact})
      |> render_submit()

    assert html =~ contact
    refute html =~ "No trusted contacts yet."

    html =
      view
      |> element(~s(button[phx-value-entry="#{contact}"]))
      |> render_click()

    assert html =~ "No trusted contacts yet."
    refute html =~ contact
  end

  test "rejects an invalid trusted-contact entry with a flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form(~s(form[phx-submit="add_contact"]), %{"entry" => "not-an-email"})
      |> render_submit()

    assert html =~ "Enter a full email address or a *@domain wildcard."
    assert html =~ "No trusted contacts yet."
  end

  describe "unattended shift panel" do
    test "renders with no shift running and a start control", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(id="home-shift")
      assert html =~ "Unattended Shift"
      assert html =~ "No shift running."
      assert html =~ ~s(phx-click="start_unattended_shift")
    end

    test "starts and stops an unattended shift from the panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> element(~s(button[phx-click="start_unattended_shift"]))
        |> render_click()

      assert html =~ "Unattended shift"
      assert html =~ ~s(phx-click="stop_shift")
      assert BusterClaw.Orchestration.active_shift().unattended == true

      html =
        view
        |> element(~s(button[phx-click="stop_shift"]))
        |> render_click()

      assert html =~ "No shift running."
      refute BusterClaw.Orchestration.shift_active?()
    end

    test "engages and clears the kill switch from the panel", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "clear"

      html =
        view
        |> element(~s(button[phx-click="engage_kill_switch"]))
        |> render_click()

      assert html =~ "ENGAGED"
      assert BusterClaw.Orchestration.kill_switch_engaged?()

      html =
        view
        |> element(~s(button[phx-click="clear_kill_switch"]))
        |> render_click()

      refute html =~ "ENGAGED"
      refute BusterClaw.Orchestration.kill_switch_engaged?()
    end
  end

  test "renders the This Week activity panel", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="home-activity")
    assert html =~ "This Week"
    assert html =~ "Handled"
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
