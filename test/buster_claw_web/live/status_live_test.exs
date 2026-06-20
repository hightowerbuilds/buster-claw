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
    # Get Started now points users at the chat pathway, not the terminal/shift one.
    assert response =~ "Chat with Buster Claw"
    assert response =~ "Install Claude Code"
    refute response =~ "Go on duty"
    refute response =~ "./buster-claw shift run"
    # The unattended-shift panel was removed; the chat + prompt pathway replaces it.
    refute response =~ ~s(id="home-shift")
    refute response =~ "Unattended Shift"
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

  describe "agent chat panel" do
    test "renders the chat column with an empty-state prompt", %{conn: conn} do
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)

      assert response =~ ~s(id="home-agent-chat")
      assert response =~ ~s(phx-hook="AgentChat")
      assert response =~ "Talk to Buster Claw"
      assert response =~ ~s(form[phx-submit="chat_send"]) or response =~ ~s(phx-submit="chat_send")
    end

    test "projects broadcast events into the transcript", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:agent_chat, {:message, %{role: :user, text: "work the queue"}}})
      send(view.pid, {:agent_chat, {:status, :running}})
      send(view.pid, {:agent_chat, {:message, %{role: :assistant, text: "On it."}}})
      send(view.pid, {:agent_chat, {:message, %{role: :tool, text: "Bash: ./buster-claw dispatch list"}}})

      html =
        send(view.pid, {:agent_chat, {:message, %{role: :meta, text: "2 turns · $0.01"}}})
        |> then(fn _ -> render(view) end)

      assert html =~ "work the queue"
      assert html =~ "On it."
      assert html =~ "Bash: ./buster-claw dispatch list"
      assert html =~ "2 turns"
    end

    test "an error broadcast renders an inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {:agent_chat, {:message, %{role: :error, text: "The run timed out and was stopped."}}})
      assert render(view) =~ "The run timed out and was stopped."
    end
  end

  test "Get Started offers quick-chat prompts", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Quick chat"
    assert response =~ ~s(phx-click="quick_chat")
    assert response =~ "Please read through the introduction and BusterClawWorkspace"
    assert response =~ "Sentinel security layer"
    assert response =~ "overview of everything you can do across my Google Workspace"
  end

  describe "Pages tab bookmarks" do
    test "lists in-app browser bookmarks, links into the Browser, and removes them",
         %{conn: conn, root: root} do
      File.write!(
        Path.join(root, ".browser-bookmarks.json"),
        Jason.encode!([
          %{"url" => "https://example.com", "label" => "Example", "at" => "2026-06-20T00:00:00Z"}
        ])
      )

      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ ~s(id="home-bookmarks")
      assert html =~ "Example"
      assert html =~ "https://example.com"
      # The link opens the in-app Browser at that page.
      assert html =~ "/browse?url=https"

      html =
        view
        |> element(~s(button[phx-value-url="https://example.com"]))
        |> render_click()

      refute html =~ "https://example.com"
      assert html =~ "No bookmarks yet."
    end
  end

  describe "home left-column tabs" do
    test "default to Get Started and switch tabs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s(button[phx-value-tab="get-started"][aria-selected="true"]))
      assert has_element?(view, ~s(button[phx-value-tab="calendar"][aria-selected="false"]))

      view |> element(~s(button[phx-value-tab="calendar"])) |> render_click()

      assert has_element?(view, ~s(button[phx-value-tab="calendar"][aria-selected="true"]))
      assert has_element?(view, ~s(button[phx-value-tab="get-started"][aria-selected="false"]))

      # Activity tab carries the audit-trail activity panel.
      html = view |> element(~s(button[phx-value-tab="activity"])) |> render_click()
      assert has_element?(view, ~s(button[phx-value-tab="activity"][aria-selected="true"]))
      assert html =~ "Activity"
      assert html =~ "Commands"
    end
  end

  test "renders the audit-trail Activity panel with a granularity toggle", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="home-activity")
    assert html =~ "Activity"
    # Audit-trail metrics.
    assert html =~ "Runs"
    assert html =~ "Commands"
    assert html =~ "Handled"
    # Granularity toggle defaults to weekly.
    assert has_element?(view, ~s(button[phx-value-grain="week"][aria-pressed="true"]))
    assert has_element?(view, ~s(button[phx-value-grain="month"]))

    html = view |> element(~s(button[phx-value-grain="month"])) |> render_click()
    assert html =~ "Last 12 months"
    assert has_element?(view, ~s(button[phx-value-grain="month"][aria-pressed="true"]))
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
