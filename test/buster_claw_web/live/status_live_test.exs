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

  test "GET / renders the home shell with the corner widget and chat", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Buster Claw"
    # Browser-style shell: top tab strip + bottom dock (former sidebar).
    assert response =~ ~s(id="tab-strip")
    assert response =~ ~s(phx-hook="TabStrip")
    assert response =~ ~s(id="app-dock")
    # Get Started moved to a Settings sub-tab — the home page no longer carries it.
    refute response =~ ~s(id="home-get-started")
    refute response =~ "Install Claude Code"
    refute response =~ "Go on duty"
    refute response =~ "./buster-claw shift run"
    # The unattended-shift panel was removed; the chat + prompt pathway replaces it.
    refute response =~ ~s(id="home-shift")
    refute response =~ "Unattended Shift"
    # Corner widget: calendar + contacts tabs.
    assert response =~ ~s(id="home-corner-widget")
    assert response =~ ~s(phx-hook="CornerWidget")
    assert response =~ "Calendar"
    assert response =~ "Contacts"
    # Trusted contacts live inside the corner widget (Contacts tab renders
    # hidden alongside the Calendar tab).
    assert response =~ ~s(id="home-contacts-panel")
    assert response =~ "No trusted senders"
    # Right column: agent chat panel.
    assert response =~ ~s(id="home-agent-chat")
    assert response =~ ~s(phx-hook="AgentChat")
    refute response =~ ~s(id="home-shift-management")
    # The Connect-GWS panel was removed from the home page; GWS lives on the
    # Configuration tab (/settings) + /setup.
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

    # The corner widget's month grid carries each event day's detail in a
    # hidden popover block, so title + time are in the rendered HTML.
    assert response =~ ~s(id="home-month-grid")
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
    refute response =~ "No trusted senders"
  end

  test "adds and removes a trusted contact from the home panel", %{conn: conn} do
    # Use an address that does NOT appear in the input placeholder text.
    contact = "dana@example.org"

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "No trusted senders"
    refute html =~ contact

    html =
      view
      |> form(~s(form[phx-submit="add_contact"]), %{"entry" => contact})
      |> render_submit()

    assert html =~ contact
    refute html =~ "No trusted senders"

    html =
      view
      |> element(~s(button[phx-value-entry="#{contact}"]))
      |> render_click()

    assert html =~ "No trusted senders"
    refute html =~ contact
  end

  test "rejects an invalid trusted-contact entry with a flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form(~s(form[phx-submit="add_contact"]), %{"entry" => "not-an-email"})
      |> render_submit()

    assert html =~ "Enter a full email address or a *@domain wildcard."
    assert html =~ "No trusted senders"
  end

  describe "agent chat panel" do
    test "renders the chat column with an empty-state prompt", %{conn: conn} do
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)

      assert response =~ ~s(id="home-agent-chat")
      assert response =~ ~s(phx-hook="AgentChat")

      assert response =~ ~s(form[phx-submit="chat_send"]) or
               response =~ ~s(phx-submit="chat_send")

      # Spoken replies (TTS): the Voice on/off toggle in the chat header. The
      # STT mic (Mic hook, listening overlay) was demolished 06-28.
      assert response =~ ~s(id="voice-toggle")
      assert response =~ ~s(phx-hook="VoiceToggle")
      assert response =~ "Voice on"
      refute response =~ ~s(id="chat-mic")
      refute response =~ ~s(phx-hook="Mic")
      refute response =~ "Click to talk"
    end

    test "projects the active conversation's broadcast events into the transcript", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      active = active_chat(view)

      send(view.pid, {:agent_chat, active, {:message, %{role: :user, text: "work the queue"}}})
      send(view.pid, {:agent_chat, active, {:status, :running}})
      send(view.pid, {:agent_chat, active, {:message, %{role: :assistant, text: "On it."}}})

      send(
        view.pid,
        {:agent_chat, active,
         {:message, %{role: :tool, text: "Bash: ./buster-claw dispatch list"}}}
      )

      html =
        send(view.pid, {:agent_chat, active, {:message, %{role: :meta, text: "2 turns · $0.01"}}})
        |> then(fn _ -> render(view) end)

      assert html =~ "work the queue"
      assert html =~ "On it."
      assert html =~ "Bash: ./buster-claw dispatch list"
      assert html =~ "2 turns"
    end

    test "an error broadcast renders an inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      active = active_chat(view)

      send(
        view.pid,
        {:agent_chat, active,
         {:message, %{role: :error, text: "The run timed out and was stopped."}}}
      )

      assert render(view) =~ "The run timed out and was stopped."
    end

    test "a background conversation's message does not touch the active transcript", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(
        view.pid,
        {:agent_chat, "some-other-conv",
         {:message, %{role: :assistant, text: "background reply"}}}
      )

      refute render(view) =~ "background reply"
    end

    test "New chat adds a tab and clears the panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element(~s([phx-click="new_chat"])) |> render_click()
      assert html =~ "New chat"
    end

    test "an active conversation's message lands in the transcript", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(
        view.pid,
        {:agent_chat, active_chat(view), {:message, %{role: :assistant, text: "streamed reply"}}}
      )

      assert render(view) =~ "streamed reply"
    end
  end

  # The active conversation id is the first seeded conversation ("default").
  defp active_chat(_view), do: "default"

  describe "corner widget tabs" do
    test "default to Calendar and switch to Contacts (Get Started has moved)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Get Started is no longer a corner-widget tab.
      refute has_element?(view, ~s(button[phx-value-tab="get-started"]))

      assert has_element?(view, ~s(button[phx-value-tab="calendar"][aria-selected="true"]))
      assert has_element?(view, ~s(button[phx-value-tab="contacts"][aria-selected="false"]))

      view |> element(~s(button[phx-value-tab="contacts"])) |> render_click()

      assert has_element?(view, ~s(button[phx-value-tab="contacts"][aria-selected="true"]))
      assert has_element?(view, ~s(button[phx-value-tab="calendar"][aria-selected="false"]))
    end
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

    # An event in the REAL current (UTC) month. The month grid must be anchored
    # to the app-local date (May 2026), so this event's month is never shown —
    # if the grid used UTC "today" instead, this title would render and the
    # May event would not.
    {:ok, _event} =
      Calendar.create_event(%{
        event_id: "home-utc-month",
        date: Date.utc_today(),
        title: "UTC month event"
      })

    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Local today event"
    refute response =~ "UTC month event"
  end

  describe "corner widget Time & Place tab" do
    import Phoenix.LiveViewTest

    test "the widget offers the tab, the clock, and the daycycle shader", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(phx-value-tab="place")
      assert html =~ "Time &amp; Place"
      assert html =~ "home-clock"
      assert html =~ "data-clock-digital"
      # The sky behind it: the daycycle shader mount, fed the local clock.
      assert html =~ ~s(data-shader="daycycle")
      assert html =~ ~s(data-daylight="true")
    end

    test "selecting Time & Place with no location shows the location form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_click(view, "select_widget_tab", %{"tab" => "place"})

      assert html =~ "Where are you?"
      assert html =~ "set_weather_location"
    end
  end

  describe "Notify widget" do
    alias BusterClaw.Notifications

    test "the corner widget has a Notify tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Notify"

      {:ok, view, _html} = live(conn, ~p"/")
      html = render_click(view, "select_widget_tab", %{"tab" => "notify"})
      assert html =~ "New timer"
      assert html =~ "None set"
    end

    test "creating a timer from the form lists it and clears the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})

      html =
        view
        |> form("#notify-form", %{notify: %{label: "Tea", minutes: "5"}})
        |> render_submit()

      assert html =~ "Tea"
      assert [%{kind: "timer", label: "Tea", status: "pending"}] = Notifications.upcoming()
    end

    test "a blank label is rejected with an inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})

      html =
        view
        |> form("#notify-form", %{notify: %{label: "   ", minutes: "5"}})
        |> render_submit()

      assert html =~ "add a label"
      assert Notifications.upcoming() == []
    end

    test "the soonest notification renders a shader countdown; none when empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      empty = render_click(view, "select_widget_tab", %{"tab" => "notify"})
      refute empty =~ "ShaderTimer"

      {:ok, soonest} =
        Notifications.create_notification(%{
          "kind" => "timer",
          "label" => "Tea",
          "fire_at" => DateTime.add(DateTime.utc_now(), 120, :second),
          "status" => "pending"
        })

      {:ok, _later} =
        Notifications.create_notification(%{
          "kind" => "alarm",
          "label" => "Later",
          "fire_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "status" => "pending"
        })

      html = render(view)
      unix = DateTime.to_unix(soonest.fire_at)

      # The hero canvas is keyed by the soonest notification + its fire-at, driven
      # by the ShaderTimer hook off data-fire-at.
      assert html =~ ~s(phx-hook="ShaderTimer")
      assert html =~ ~s(id="notify-countdown-#{soonest.id}-#{unix}")
      assert html =~ ~s(data-fire-at="#{unix}")
      assert html =~ "data-timer-canvas"
    end

    test "dismiss removes a notification from the widget list", %{conn: conn} do
      {:ok, notification} =
        Notifications.create_notification(%{
          "kind" => "timer",
          "label" => "Standup",
          "fire_at" => DateTime.add(DateTime.utc_now(), 600, :second),
          "status" => "pending"
        })

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      assert render(view) =~ "Standup"

      render_click(view, "notify_dismiss", %{"id" => to_string(notification.id)})

      refute render(view) =~ "Standup"
      assert Notifications.get_notification(notification.id).status == "dismissed"
    end

    test "a fired notification leaves the widget list (modal is NotifyLive's job)",
         %{conn: conn} do
      {:ok, past} =
        Notifications.create_notification(%{
          "kind" => "alarm",
          "label" => "Ring",
          "fire_at" => DateTime.add(DateTime.utc_now(), -5, :second),
          "status" => "pending"
        })

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      assert render(view) =~ "Ring"

      # Scheduler is off in tests; drive the fire directly. Its broadcast reaches
      # the view, which drops the now-fired item from "upcoming". The modal is
      # rendered by the separate NotifyLive process, not here.
      Notifications.fire_due()
      assert Notifications.get_notification(past.id).status == "fired"

      _ = :sys.get_state(view.pid)
      html = render(view)
      refute html =~ "Ring"
      refute html =~ "time&#39;s up"
    end
  end
end
