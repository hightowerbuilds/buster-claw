defmodule BusterClawWeb.StatusLiveTest do
  # async: false — points the global :workspace_root at a tmp trusted-senders file.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Calendar
  alias BusterClaw.Contacts
  alias BusterClaw.LocalTime
  alias BusterClaw.Telephony

  setup do
    root = Path.join(System.tmp_dir!(), "bc_status_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "memory"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    # The home shell renders an "Install Claude Code" prompt when no agent CLI
    # is detected; force detection so the assertions don't depend on whether
    # the host machine has `claude` on PATH (CI runners don't).
    prev_cli = Application.get_env(:buster_claw, :agent_cli)
    Application.put_env(:buster_claw, :agent_cli, {:claude, "/usr/local/bin/claude"})

    # Entering the Trading tab starts an account-snapshot fetch, which would
    # otherwise spawn a REAL claude run from a test. Default seam: an error the
    # panel renders honestly; individual tests override with richer fetchers.
    prev_fetcher = Application.get_env(:buster_claw, :trading_snapshot_fetcher)

    Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
      {:error, {:robinhood, "disabled in test"}}
    end)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      Application.put_env(:buster_claw, :agent_cli, prev_cli)
      Application.put_env(:buster_claw, :trading_snapshot_fetcher, prev_fetcher)
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
    # Corner widget: Contacts / Time & Place / Notify (Calendar moved out of the
    # widget and onto the Home sub-tab row).
    assert response =~ ~s(id="home-corner-widget")
    assert response =~ ~s(phx-hook="CornerWidget")
    assert response =~ "Contacts"
    # Home sub-tabs: Chat (default) | Calendar | Notes.
    assert response =~ "Calendar"
    assert response =~ "Notes"
    # The Contacts widget tab is now a comms hub (recent phone activity + contacts
    # with Text/Call/Email); its panel keeps the id and shows empty states here.
    assert response =~ ~s(id="home-contacts-panel")
    assert response =~ "No contacts yet."
    assert response =~ "No recent phone activity."
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

  test "the Home Calendar sub-tab renders today's calendar events", %{conn: conn} do
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

    {:ok, view, _html} = live(conn, ~p"/")

    # Chat is the default; the calendar (and its events) appear once the Calendar
    # sub-tab is selected, mounting the embedded CalendarComponent.
    html = render_click(view, "select_home_tab", %{"tab" => "calendar"})

    assert html =~ ~s(id="calendar-grid")
    assert html =~ "Home page planning block"
    assert html =~ "09:30"
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

    # The add input is collapsed behind the Contacts "+ Add" button.
    render_click(view, "toggle_add_contact", %{})

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

    # The add input is collapsed behind the Contacts "+ Add" button.
    render_click(view, "toggle_add_contact", %{})

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

      # Spoken replies (TTS): the Voice on/off toggle in the chat header,
      # default OFF since 07-18 (opt in, not out). The STT mic (Mic hook,
      # listening overlay) was demolished 06-28.
      assert response =~ ~s(id="voice-toggle")
      assert response =~ ~s(phx-hook="VoiceToggle")
      assert response =~ "Voice off"
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

    test "an SVG in a reply becomes a View drawing link that opens the modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      active = active_chat(view)

      svg = ~s(<svg viewBox="0 0 10 10"><circle r="5" /></svg>)

      send(
        view.pid,
        {:agent_chat, active,
         {:message, %{role: :assistant, text: "Here is a circle:\n```svg\n#{svg}\n```"}}}
      )

      html = render(view)
      # The raw block is stripped from the bubble and replaced by a link; there is
      # no persistent side viewer anymore.
      assert html =~ "Here is a circle:"
      refute html =~ "```svg"
      assert html =~ "View drawing"
      refute has_element?(view, "#home-svg-viewer")

      # The link opens the full-screen modal with the (sanitized) drawing.
      html = view |> element(~s(button[phx-click="zoom_svg"])) |> render_click()
      assert html =~ "circle"
    end

    test "an SVG-only reply still shows a View drawing link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      active = active_chat(view)

      send(
        view.pid,
        {:agent_chat, active,
         {:message,
          %{role: :assistant, text: ~s(```svg\n<svg viewBox="0 0 10 10"><rect /></svg>\n```)}}}
      )

      assert render(view) =~ "View drawing"
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
  describe "trading sub-tab" do
    test "renders the tab, the warning banner, and first-run setup", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      # The tab button exists; the trading conversation is NOT a chat-strip tab.
      assert html =~ ~s(phx-value-tab="trading")
      refute html =~ ~s(phx-value-id="trading")

      html = render_click(view, "select_home_tab", %{"tab" => "trading"})
      assert html =~ "real orders execute here"
      assert html =~ "claude mcp login robinhood"
      assert html =~ "#65895"
      # The chat surface renders without the conversation strip.
      assert html =~ ~s(id="home-agent-chat")
      # The chat/account partition is draggable (parameterized SplitResizer).
      assert html =~ ~s(phx-hook="SplitResizer")
      assert html =~ ~s(data-resize-var="--trading-left")
      assert html =~ "data-split-divider"
    end

    test "a trading message renders on-tab; off-tab it sets the unread dot", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # On the Trading tab, its conversation is the active one.
      render_click(view, "select_home_tab", %{"tab" => "trading"})

      send(
        view.pid,
        {:agent_chat, "trading", {:message, %{role: :assistant, text: "AAPL $210.11"}}}
      )

      assert render(view) =~ "AAPL $210.11"

      # Back on Chat: trading messages must not enter the visible transcript,
      # but the Trading tab button gains the unread dot. (In production the Chat
      # process persists the line to the Transcript; this harness only fakes the
      # PubSub side, so persist it by hand for the re-entry assertion below.)
      render_click(view, "select_home_tab", %{"tab" => "chat"})
      BusterClaw.Agent.Transcript.record("trading", :assistant, "Filled 1 VOO")

      send(
        view.pid,
        {:agent_chat, "trading", {:message, %{role: :assistant, text: "Filled 1 VOO"}}}
      )

      html = render(view)
      refute html =~ "Filled 1 VOO"
      assert html =~ ~s(rounded-full bg-warning)

      # ...which clears on entering the tab, where history reloads from the
      # durable transcript.
      html = render_click(view, "select_home_tab", %{"tab" => "trading"})
      refute html =~ ~s(rounded-full bg-warning)
      assert html =~ "Filled 1 VOO"
    end

    test "the account card loads a snapshot via the fetcher seam", %{conn: conn} do
      Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
        {:ok,
         %{
           "account" => "••••6587",
           "value" => 3.38,
           "cash" => 2.38,
           "buying_power" => 2.38,
           "positions" => [
             %{"symbol" => "VOO", "quantity" => 0.01, "value" => 1.0},
             %{"symbol" => "AAPL", "quantity" => 0.002, "value" => 0.5}
           ],
           "orders" => [
             %{
               "symbol" => "VOO",
               "side" => "buy",
               "quantity" => 0.01,
               "price" => 100.0,
               "state" => "filled",
               "placed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
             }
           ],
           "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         }}
      end)

      {:ok, view, _html} = live(conn, ~p"/")
      html = render_click(view, "select_home_tab", %{"tab" => "trading"})
      assert html =~ "trading-account-card"

      html = render_async(view)
      assert html =~ "$3.38"
      assert html =~ "VOO"
      assert html =~ "Buying power"
      assert html =~ "as of"

      # Allocation bars: the largest position reads full-width; the smaller one
      # is proportional (0.5 / 1.0 = 50%).
      assert html =~ "width: 100.0%"
      assert html =~ "width: 50.0%"

      # Trades: side is WRITTEN (buy), with the status chip class, never
      # color-alone.
      assert html =~ "buy"
      assert html =~ "text-success"
      assert html =~ "filled"

      # The snapshot persisted — a fresh cached read has it.
      assert {:ok, %{"value" => 3.38}} = BusterClaw.Trading.cached_snapshot()
    end

    test "a failed refresh keeps the last good snapshot visible", %{conn: conn} do
      good = %{
        "account" => "••••6587",
        "value" => 42.0,
        "cash" => 42.0,
        "buying_power" => 42.0,
        "positions" => [],
        "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      BusterClaw.Trading.store_snapshot(good)

      # Force staleness so entering the tab triggers the (failing) fetcher.
      BusterClaw.Trading.store_snapshot(Map.put(good, "fetched_at", "2020-01-01T00:00:00Z"))

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "trading"})
      html = render_async(view)

      assert html =~ "Refresh failed: disabled in test"
      assert html =~ "$42.00"
    end

    test "leaving the trading tab re-activates the previous conversation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "select_home_tab", %{"tab" => "trading"})
      html = render_click(view, "select_home_tab", %{"tab" => "chat"})

      # The ordinary conversation is active again: its broadcasts render.
      send(view.pid, {:agent_chat, "default", {:message, %{role: :assistant, text: "back home"}}})
      assert render(view) =~ "back home"
      refute html =~ "real orders execute here"
    end
  end

  defp active_chat(_view), do: "default"

  describe "corner widget tabs" do
    test "default to Time & Place and switch to Contacts (Calendar/Get Started have moved)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Get Started and Calendar are no longer corner-widget tabs (Calendar moved
      # to the Home sub-tab row, which uses select_home_tab — scope by handler).
      refute has_element?(
               view,
               ~s(button[phx-click="select_widget_tab"][phx-value-tab="get-started"])
             )

      refute has_element?(
               view,
               ~s(button[phx-click="select_widget_tab"][phx-value-tab="calendar"])
             )

      # Time & Place leads and is selected by default; Contacts follows.
      assert has_element?(view, ~s(button[phx-value-tab="place"][aria-selected="true"]))
      assert has_element?(view, ~s(button[phx-value-tab="contacts"][aria-selected="false"]))

      view |> element(~s(button[phx-value-tab="contacts"])) |> render_click()

      assert has_element?(view, ~s(button[phx-value-tab="contacts"][aria-selected="true"]))
      assert has_element?(view, ~s(button[phx-value-tab="place"][aria-selected="false"]))
    end
  end

  describe "contacts comms hub" do
    test "the Email action prefills the chat and switches to the Chat sub-tab", %{conn: conn} do
      {:ok, contact} = Contacts.create_contact(%{name: "Dana Ops", email: "dana@example.com"})

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "email_contact", %{"id" => to_string(contact.id)})

      assert_push_event(view, "bc:chat_prefill", %{text: text})
      assert text =~ "Please email Dana Ops (dana@example.com) with the following message:"
      # Chat is now the active sub-tab (calendar/notes hidden).
      refute has_element?(view, "#calendar-grid")
      assert has_element?(view, "button[phx-value-tab='chat'].bg-primary")
    end

    test "recent phone activity surfaces in the Contacts widget", %{conn: conn} do
      {:ok, _event} =
        Telephony.record_event(
          %{
            direction: "inbound",
            kind: "sms",
            from_number: "+15035551234",
            to_number: "+13603646763",
            body: "on my way",
            occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          observe: false
        )

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "on my way"
    end

    test "the add-contact input is hidden until the Add button is toggled", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, ~s(form[phx-submit="add_contact"]))
      render_click(view, "toggle_add_contact", %{})
      assert has_element?(view, ~s(form[phx-submit="add_contact"]))
    end
  end

  test "the Home calendar anchors to the app-local date, not UTC", %{conn: conn} do
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

    # An event in the REAL current (UTC) month. The calendar opens on the
    # app-local month (May 2026), so this event's month is never shown — if the
    # grid used UTC "today" instead, this title would render and the May event
    # would not.
    {:ok, _event} =
      Calendar.create_event(%{
        event_id: "home-utc-month",
        date: Date.utc_today(),
        title: "UTC month event"
      })

    {:ok, view, _html} = live(conn, ~p"/")
    html = render_click(view, "select_home_tab", %{"tab" => "calendar"})

    assert html =~ "Local today event"
    refute html =~ "UTC month event"
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
      # The kind switcher offers all three kinds; timer is the default.
      assert html =~ ~s(phx-click="notify_kind")
      assert html =~ "Alarm"
      assert html =~ "Reminder"
      assert html =~ ~s(name="notify[minutes]")
      assert html =~ "No timers set"
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

    test "switching kind swaps the form fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})

      html = render_click(view, "notify_kind", %{"kind" => "alarm"})
      assert html =~ ~s(name="notify[at]")
      refute html =~ ~s(name="notify[minutes]")

      # Reminders are wall-clock scheduled too — same time field, label required.
      html = render_click(view, "notify_kind", %{"kind" => "reminder"})
      assert html =~ ~s(name="notify[at]")
      refute html =~ ~s(name="notify[minutes]")
    end

    test "creating an alarm arms the next local occurrence of that time", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      render_click(view, "notify_kind", %{"kind" => "alarm"})

      html =
        view
        |> form("#notify-form", %{notify: %{kind: "alarm", label: "Wake", at: "07:30"}})
        |> render_submit()

      assert html =~ "Wake"
      assert [%{kind: "alarm", label: "Wake", fire_at: fire_at}] = Notifications.upcoming()

      # In the future, within the next 24h, and on a :30 wall-clock minute
      # (offsets are 15-minute granular, so the minute survives conversion).
      seconds_out = DateTime.diff(fire_at, DateTime.utc_now())
      assert seconds_out > 0
      assert seconds_out <= 86_400
      assert rem(fire_at.minute, 15) == 0
    end

    test "an alarm needs no label — blank defaults to \"Alarm\"", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      render_click(view, "notify_kind", %{"kind" => "alarm"})

      view
      |> form("#notify-form", %{notify: %{kind: "alarm", label: "  ", at: "07:30"}})
      |> render_submit()

      assert [%{kind: "alarm", label: "Alarm"}] = Notifications.upcoming()
    end

    test "a reminder still requires a label", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      render_click(view, "notify_kind", %{"kind" => "reminder"})

      html =
        view
        |> form("#notify-form", %{notify: %{kind: "reminder", label: "  "}})
        |> render_submit()

      assert html =~ "add a label"
      assert Notifications.upcoming() == []
    end

    test "an unparseable alarm time is rejected with an inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      render_click(view, "notify_kind", %{"kind" => "alarm"})

      html =
        view
        |> form("#notify-form", %{notify: %{kind: "alarm", label: "Wake", at: ""}})
        |> render_submit()

      assert html =~ "pick a time"
      assert Notifications.upcoming() == []
    end

    test "creating a reminder schedules its announcement time", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      render_click(view, "notify_kind", %{"kind" => "reminder"})

      view
      |> form("#notify-form", %{notify: %{kind: "reminder", label: "Stretch", at: "18:45"}})
      |> render_submit()

      assert [%{kind: "reminder", label: "Stretch", fire_at: fire_at}] =
               Notifications.upcoming()

      # Armed for the next local occurrence — in the future, within 24h.
      seconds_out = DateTime.diff(fire_at, DateTime.utc_now())
      assert seconds_out > 0
      assert seconds_out <= 86_400
    end

    test "a reminder without a time is rejected inline", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      render_click(view, "notify_kind", %{"kind" => "reminder"})

      html =
        view
        |> form("#notify-form", %{notify: %{kind: "reminder", label: "Stretch", at: ""}})
        |> render_submit()

      assert html =~ "pick a time"
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

      # The hero canvas is keyed by the soonest notification of the SELECTED
      # kind (timer by default) + its fire-at, driven by ShaderTimer.
      assert html =~ ~s(phx-hook="ShaderTimer")
      assert html =~ ~s(id="notify-countdown-#{soonest.id}-#{unix}")
      assert html =~ ~s(data-fire-at="#{unix}")
      assert html =~ "data-timer-canvas"
    end

    test "the countdown and list follow the selected kind", %{conn: conn} do
      {:ok, timer} =
        Notifications.create_notification(%{
          "kind" => "timer",
          "label" => "Tea",
          "fire_at" => DateTime.add(DateTime.utc_now(), 120, :second),
          "status" => "pending"
        })

      {:ok, alarm} =
        Notifications.create_notification(%{
          "kind" => "alarm",
          "label" => "Wake",
          "fire_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "status" => "pending"
        })

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})

      # Assertions scope to the notify panel: the DOCK's status widget also shows
      # upcoming notifications page-wide, so whole-page refutes would false-fail.
      panel = fn -> view |> element("#home-notify-panel") |> render() end

      # Timer kind (default): the timer's countdown and row; the alarm is absent.
      html = panel.()
      assert html =~ ~s(id="notify-countdown-#{timer.id}-#{DateTime.to_unix(timer.fire_at)}")
      assert html =~ "Tea"
      refute html =~ "Wake"

      # Alarm kind: the hero re-keys to the alarm; the timer leaves the column.
      render_click(view, "notify_kind", %{"kind" => "alarm"})
      html = panel.()
      assert html =~ ~s(id="notify-countdown-#{alarm.id}-#{DateTime.to_unix(alarm.fire_at)}")
      assert html =~ "Wake"
      refute html =~ "Tea"

      # Reminder kind: nothing armed — no shader, honest per-kind empty state.
      render_click(view, "notify_kind", %{"kind" => "reminder"})
      html = panel.()
      refute html =~ "notify-countdown-"
      assert html =~ "No reminders set"
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
      # The widget filters by kind — an alarm only shows on the Alarm tab.
      render_click(view, "notify_kind", %{"kind" => "alarm"})
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

  describe "home sub-tabs (chat / calendar / notes)" do
    test "chat is the default view and the calendar is hidden", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#calendar-grid")
      # The active sub-tab carries the primary wash; Chat is active on load.
      assert has_element?(view, "button[phx-value-tab='chat'].bg-primary")
      refute has_element?(view, "button[phx-value-tab='calendar'].bg-primary")
    end

    test "the Calendar sub-tab shows the calendar and hides the chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "select_home_tab", %{"tab" => "calendar"})

      assert has_element?(view, "#calendar-grid")
      assert has_element?(view, "#event-form")
      assert has_element?(view, "button[phx-value-tab='calendar'].bg-primary")

      # ...and switching back to Chat hides the calendar again.
      render_click(view, "select_home_tab", %{"tab" => "chat"})
      refute has_element?(view, "#calendar-grid")
    end

    test "the Notes sub-tab shows the note surface and creates + edits a note",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_click(view, "select_home_tab", %{"tab" => "notes"})
      refute has_element?(view, "#calendar-grid")
      assert html =~ "Select a note"
      assert has_element?(view, "button[phx-value-tab='notes'].bg-primary")

      # Create a note via the component's new-note form.
      view
      |> form("#new-note-form", note: %{title: "Roadmap ideas"})
      |> render_submit()

      assert has_element?(view, "button[phx-value-name='Roadmap ideas']")

      # Editing autosaves and updates the live reading view.
      html =
        view
        |> form("#note-editor-form", %{body: "# Ideas\n\nship notes"})
        |> render_change()

      assert html =~ "ship notes"
      assert %{body: body} = BusterClaw.Notes.get("Roadmap ideas")
      assert body =~ "ship notes"
    end
  end
end
