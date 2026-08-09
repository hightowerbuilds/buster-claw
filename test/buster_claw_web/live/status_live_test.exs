defmodule BusterClawWeb.StatusLiveTest do
  # async: false — points the global :workspace_root at a tmp trusted-senders file.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Agent.Attachments
  alias BusterClaw.Appearance
  alias BusterClaw.Calendar
  alias BusterClaw.ChatSkin
  alias BusterClaw.Commands
  alias BusterClaw.Contacts
  alias BusterClaw.LocalTime
  alias BusterClaw.ModelPolicy
  alias BusterClaw.Settings
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

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      Application.put_env(:buster_claw, :agent_cli, prev_cli)
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
    # Home sub-tabs include the operator notebook and the far-right Activity record.
    assert response =~ "Calendar"
    assert response =~ "Notes"
    assert response =~ "Activity"
    # Trading moved to a top-level tab (TRADING_TAB_ROADMAP Phase 0); the Home
    # sub-tab row must not offer it.
    refute response =~ ~s(phx-value-tab="trading")
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

  # Outbound telephony isn't wired, so these two buttons are inert. They carried a
  # `title` only — a hover tooltip, which leaves the accessible name empty (the
  # icons are decorative) and the "not built" state unreachable without a mouse.
  # Same standing obligation as the phone keypad: gating was declined, so the
  # disclosure has to hold up in place. See LAUNCH_ROADMAP G-37.
  test "inert Text/Call contact actions announce that they are not available", %{conn: conn} do
    {:ok, _contact} = Contacts.create_contact(%{name: "Dana Printshop", phone: "+15035550142"})

    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "select_widget_tab", %{"tab" => "contacts"})

    assert has_element?(view, ~s(button[aria-label="Text Dana Printshop — not available yet"]))
    assert has_element?(view, ~s(button[aria-label="Call Dana Printshop — not available yet"]))

    # Disabled in fact, not only in styling.
    assert has_element?(view, ~s(button[aria-label^="Text Dana"][disabled]))
    assert has_element?(view, ~s(button[aria-label^="Call Dana"][disabled]))
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
    test "does not render a resize bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#home-agent-chat [data-resize-handle]")
    end

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

    # A scene differs from a drawing in the one way that matters to the reader:
    # it renders INLINE. These pin that difference, because a scene that quietly
    # degraded into a "View drawing" link would still pass every other test.
    test "a scene3d block in a reply renders an inline card", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      active = active_chat(view)

      scene = ~s({"nodes": [{"kind": "box", "size": [1,1,1], "label": "Ingest"}]})

      send(
        view.pid,
        {:agent_chat, active,
         {:message, %{role: :assistant, text: "See the scene:\n```scene3d\n#{scene}\n```"}}}
      )

      html = render(view)
      assert html =~ "See the scene:"
      refute html =~ "```scene3d"
      # The JSON must not leak into the bubble, and the SVG must be inline —
      # not behind a link.
      refute html =~ ~s("kind")
      assert html =~ "3D scene"
      assert html =~ "<svg"
      assert html =~ "Ingest"
      assert has_element?(view, ~s(button[phx-click="zoom_svg"] svg))
    end

    test "a malformed scene3d block costs the message nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      active = active_chat(view)

      send(
        view.pid,
        {:agent_chat, active,
         {:message,
          %{role: :assistant, text: "Still here.\n```scene3d\n{\"kind\": \"teapot\"}\n```"}}}
      )

      html = render(view)
      # The text survives, the block is stripped, and no card appears. The
      # failure is silent on purpose — see `extract_scenes/1`.
      assert html =~ "Still here."
      refute html =~ "```scene3d"
      refute html =~ "teapot"
      refute html =~ "3D scene"
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

  describe "chat skin" do
    test "the panel mounts wearing the stored skin", %{conn: conn} do
      ChatSkin.set("slack")

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-chat-skin="slack")
    end

    test "a stored skin that no longer exists mounts as the default", %{conn: conn} do
      Settings.put(ChatSkin.setting_key(), "vaporwave")

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-chat-skin="#{ChatSkin.default()}")
    end

    test "changing the skin restyles messages already on screen", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ ~s(data-chat-skin="#{ChatSkin.default()}")

      # Put a message in the transcript first. This is the case the whole design
      # exists for: the transcript is a stream, so this node will not be
      # re-rendered by the skin change and has to restyle from CSS alone.
      send(
        view.pid,
        {:agent_chat, active_chat(view), {:message, %{role: :assistant, text: "already here"}}}
      )

      assert render(view) =~ "already here"

      # The real path — Settings write plus broadcast — not a hand-rolled send.
      assert {:ok, "minimal"} = ChatSkin.set("minimal")

      html = render(view)

      assert html =~ ~s(data-chat-skin="minimal")
      # Still there, and untouched: the switch cost no stream ops, which is why
      # it applies to old messages instead of only new ones.
      assert html =~ "already here"
    end
  end

  # The active conversation id is the first seeded conversation ("default").

  defp active_chat(_view), do: "default"

  # The Phone component debounces its reload by 250ms and routes it back through
  # the host, so the render lands a couple of scheduler hops after the broadcast.
  # Polling beats a fixed sleep: it passes as soon as it is true, and it fails for
  # the right reason (the relay is broken) rather than for a slow machine.
  defp eventually(fun, remaining_ms \\ 2_000) do
    cond do
      fun.() -> true
      remaining_ms <= 0 -> false
      true -> (Process.sleep(25) || :ok) && eventually(fun, remaining_ms - 25)
    end
  end

  describe "corner widget tabs" do
    # The rail renders from HomeWidget.widget_tab_keys/0 and StatusLive's guard
    # reads the same list. They were two literals in two files, in different
    # orders, until 08-08 — the third instance of the shape that shipped Phone
    # as a home tab the guard had never heard of. This walks every key the rail
    # actually offers, so a fourth tab cannot arrive as a dead button.
    test "every tab the widget rail offers is a tab the guard opens", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for key <- BusterClawWeb.HomeWidget.widget_tab_keys() do
        assert has_element?(
                 view,
                 ~s(button[phx-click="select_widget_tab"][phx-value-tab="#{key}"])
               ),
               "the widget rail does not render a button for #{key}"

        render_click(view, "select_widget_tab", %{"tab" => key})

        assert has_element?(view, ~s(button[phx-value-tab="#{key}"][aria-selected="true"])),
               "clicking #{key} did not select it — the guard and the rail disagree"
      end
    end

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

  describe "Home sub-tabs" do
    test "chat is the default view and the calendar is hidden", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#calendar-grid")
      # The active sub-tab carries the primary wash; Chat is active on load.
      assert has_element?(view, "button[phx-value-tab='chat'].bg-primary")
      refute has_element?(view, "button[phx-value-tab='calendar'].bg-primary")
    end

    # Phone left the dock on 08-08 and became a Home sub-tab. These assert the
    # move itself — the Message Machine's own behavior stays covered by
    # `PhoneLiveTest` against `/phone`, since both surfaces render one component.
    test "the Phone sub-tab shows the Message Machine and hides the chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "select_home_tab", %{"tab" => "phone"})

      assert has_element?(view, "#home-phone-root")
      assert has_element?(view, "#phone-keypad-stage")
      assert has_element?(view, "button[phx-value-tab='phone'].bg-primary")

      render_click(view, "select_home_tab", %{"tab" => "chat"})
      refute has_element?(view, "#home-phone-root")
    end

    test "Phone is gone from the dock but still reachable directly", %{conn: conn} do
      {:ok, _view, home} = live(conn, ~p"/")

      # Assert on the rendered dock rather than the item list: the dock is what a
      # user sees, and it survives however the list is built.
      refute home =~ ~s(<a href="/phone")

      # The route survives for deep links and split panes, exactly as /calendar
      # did when it moved — and the tab strip can still name it.
      {:ok, _view, html} = live(conn, ~p"/phone")
      assert html =~ "phone-keypad-stage"
      assert html =~ ~s(&quot;/phone&quot;:&quot;Phone&quot;)
    end

    test "the rail and the select_home_tab guard cannot disagree", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Every tab the rail offers must be one the server accepts. This is the
      # test for the bug the single list exists to prevent.
      for {key, _label} <- BusterClawWeb.StatusLive.home_tabs() do
        assert has_element?(view, "button[phx-value-tab='#{key}']")
        render_click(view, "select_home_tab", %{"tab" => key})
        assert has_element?(view, "button[phx-value-tab='#{key}'].bg-primary")
      end
    end

    # The host half of the component contract: a LiveComponent has no process, so
    # if StatusLive stops relaying, the sub-tab silently goes stale while /phone
    # stays live. This is the assertion that catches that.
    test "a telephony broadcast reaches the sub-tab, not just the widget", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "phone"})

      refute render(view) =~ "(503) 555-0142"

      {:ok, _event} =
        BusterClaw.Telephony.record_event(%{
          direction: "inbound",
          kind: "voicemail",
          from_number: "+15035550142",
          to_number: "+18445550100",
          occurred_at: DateTime.utc_now(:second)
        })

      # The component debounces its reload by 250ms and asks the host to ping it
      # back; both hops have to work for this to land.
      assert eventually(fn -> render(view) =~ "(503) 555-0142" end)
    end

    test "the Calendar sub-tab shows the calendar and hides the chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "select_home_tab", %{"tab" => "calendar"})

      assert has_element?(view, "#calendar-grid")
      # The event form lives in a modal now — closed until Add Events opens it.
      assert has_element?(view, "#calendar-add-events")
      refute has_element?(view, "#event-form")
      assert has_element?(view, "button[phx-value-tab='calendar'].bg-primary")

      # ...and switching back to Chat hides the calendar again.
      render_click(view, "select_home_tab", %{"tab" => "chat"})
      refute has_element?(view, "#calendar-grid")
    end

    test "the Notes sub-tab creates, edits, previews, and saves a Markdown file",
         %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "select_home_tab", %{"tab" => "notes"})
      refute has_element?(view, "#calendar-grid")
      assert has_element?(view, "#home-notes")
      assert has_element?(view, "#notes-empty-state")
      assert has_element?(view, "button[phx-value-tab='notes'].bg-primary")

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Remote access"}})
      |> render_submit()

      assert has_element?(view, "#notes-editor-pane")
      assert has_element?(view, "#note-editor")
      assert has_element?(view, "#note-preview")

      view
      |> form("#note-editor-form", %{
        "editor" => %{"body" => "# Remote access\n\n- Keep Phoenix on loopback"}
      })
      |> render_change()

      assert has_element?(view, ~s(#note-save-status[data-state="saved"]))
      assert has_element?(view, "#note-preview h1")

      assert File.read!(Path.join([root, "notes", "Remote access.md"])) =~
               "Keep Phoenix on loopback"
    end

    test "the Notes editor preserves a draft when the file changes on disk",
         %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "notes"})

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Shared draft"}})
      |> render_submit()

      path = Path.join([root, "notes", "Shared draft.md"])
      File.write!(path, "newer disk version")

      view
      |> form("#note-editor-form", %{"editor" => %{"body" => "my unsaved draft"}})
      |> render_change()

      assert has_element?(view, ~s(#note-save-status[data-state="conflict"]))
      assert has_element?(view, "#note-conflict")
      assert has_element?(view, "#reload-note-button")
      assert has_element?(view, "#overwrite-note-button")
      assert File.read!(path) == "newer disk version"
    end

    test "the Notes rail files a note into a folder and moves it back out",
         %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "notes"})

      # The folder form is behind its toggle until asked for.
      refute has_element?(view, "#new-folder-form")
      view |> element("#new-folder-button") |> render_click()

      view
      |> form("#new-folder-form", %{"folder" => %{"name" => "Projects"}})
      |> render_submit()

      refute has_element?(view, "#new-folder-form")
      assert File.dir?(Path.join([root, "notes", "Projects"]))

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Launch", "folder" => "Projects"}})
      |> render_submit()

      assert File.exists?(Path.join([root, "notes", "Projects", "Launch.md"]))
      assert has_element?(view, ~s([data-note-heading="Projects"]))
      assert has_element?(view, ~s(button[phx-value-path="Projects/Launch.md"]))

      # Rename and move in one submission: the file lands under its new name at
      # the vault root and nothing is left behind at the old path.
      view |> element("#rename-note-button") |> render_click()

      view
      |> form("#rename-note-form", %{"rename" => %{"title" => "Launch plan", "folder" => ""}})
      |> render_submit()

      assert File.exists?(Path.join([root, "notes", "Launch plan.md"]))
      refute File.exists?(Path.join([root, "notes", "Projects", "Launch.md"]))
      refute has_element?(view, ~s([data-note-heading="Projects"]))
      assert has_element?(view, ~s(button[phx-value-path="Launch plan.md"]))
    end

    test "the Notes editor reports Unsaved, saves on demand, and reconciles with disk",
         %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "notes"})

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Field notes"}})
      |> render_submit()

      path = Path.join([root, "notes", "Field notes.md"])

      # "Saving…" is CSS keyed to `#notes-editor-pane:has(form[data-note-editor]
      # .phx-change-loading)`. Nothing else asserts that anchor, and losing it
      # would drop one save state silently.
      assert has_element?(view, "#notes-editor-pane form[data-note-editor]")
      assert has_element?(view, "#note-save-status [data-note-saving]")

      # The hook's clean -> dirty announcement, which is the only reason the chip
      # can say Unsaved during the 700ms the server hears nothing.
      view |> element("#notes-editor-pane") |> render_hook("note_dirty", %{})
      assert has_element?(view, ~s(#note-save-status[data-state="unsaved"]))

      # ⌘S submits the same form the debounce would have.
      view
      |> form("#note-editor-form", %{"editor" => %{"body" => "# Field notes\n"}})
      |> render_submit()

      assert has_element?(view, ~s(#note-save-status[data-state="saved"]))
      assert File.read!(path) == "# Field notes\n"

      # Clean editor, changed file: adopt disk silently. Refusing to show the
      # newer file would be the surprising half of this.
      File.write!(path, "# From another editor\n")
      view |> element("#notes-editor-pane") |> render_hook("check_revision", %{})

      assert has_element?(view, ~s(#note-save-status[data-state="saved"]))
      assert view |> element("#note-editor") |> render() =~ "From another editor"

      # Draft in flight, changed file: the same fact becomes a conflict, and the
      # newer bytes stay on disk.
      view |> element("#notes-editor-pane") |> render_hook("note_dirty", %{})
      File.write!(path, "# From a third editor\n")
      view |> element("#notes-editor-pane") |> render_hook("check_revision", %{})

      assert has_element?(view, ~s(#note-save-status[data-state="conflict"]))
      assert has_element?(view, "#copy-draft-button")
      assert File.read!(path) == "# From a third editor\n"

      # Autosave has stopped: a further keystroke updates the draft only.
      view
      |> form("#note-editor-form", %{"editor" => %{"body" => "still typing"}})
      |> render_change()

      assert has_element?(view, ~s(#note-save-status[data-state="conflict"]))
      assert File.read!(path) == "# From a third editor\n"
    end

    test "the preview toggle swaps the pane on narrow windows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "notes"})

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Toggle me"}})
      |> render_submit()

      assert has_element?(view, "#note-preview.hidden")
      refute has_element?(view, "#note-editor-form.hidden")

      view |> element("#toggle-preview-button") |> render_click()

      assert has_element?(view, "#note-editor-form.hidden")
      refute has_element?(view, "#note-preview.hidden")
    end

    test "a Markdown file too large to edit is listed but never opened",
         %{conn: conn, root: root} do
      File.mkdir_p!(Path.join(root, "notes"))
      File.write!(Path.join([root, "notes", "Huge.md"]), String.duplicate("x", 1_000_001))

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "notes"})

      assert has_element?(view, ~s(button[phx-value-path="Huge.md"]))
      view |> element(~s(button[phx-value-path="Huge.md"])) |> render_click()

      assert has_element?(view, "#notes-unsupported")
      refute has_element?(view, "#note-editor")
      refute render(view) =~ "xxxxxxxxxx"

      view |> element("#unsupported-back-button") |> render_click()
      assert has_element?(view, "#notes-empty-state")
    end

    test "the Notes rail searches bodies and shows a snippet", %{conn: conn, root: root} do
      File.mkdir_p!(Path.join(root, "notes"))
      File.write!(Path.join([root, "notes", "Tunnel.md"]), "Keep Phoenix on loopback.\n")
      File.write!(Path.join([root, "notes", "Groceries.md"]), "Oat milk.\n")

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "notes"})

      assert has_element?(view, ~s(button[phx-value-path="Groceries.md"]))

      view
      |> form("#notes-search-form", %{"search" => %{"query" => "loopback"}})
      |> render_change()

      assert has_element?(view, ~s(button[phx-value-path="Tunnel.md"]))
      refute has_element?(view, ~s(button[phx-value-path="Groceries.md"]))
      assert render(view) =~ "Keep Phoenix on loopback."

      view
      |> form("#notes-search-form", %{"search" => %{"query" => "zzz no match"}})
      |> render_change()

      assert render(view) =~ "No notes match."

      view
      |> form("#notes-search-form", %{"search" => %{"query" => ""}})
      |> render_change()

      assert has_element?(view, ~s(button[phx-value-path="Groceries.md"]))
    end

    test "the switcher jumps to a note by keyboard", %{conn: conn, root: root} do
      File.mkdir_p!(Path.join(root, "notes"))
      File.write!(Path.join([root, "notes", "Alpha.md"]), "first\n")
      File.write!(Path.join([root, "notes", "Beta.md"]), "second\n")

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "notes"})

      refute has_element?(view, "#note-switcher")
      view |> element("#home-notes") |> render_hook("open_switcher", %{})

      assert has_element?(view, "#note-switcher")
      assert has_element?(view, ~s(#note-switcher-input[aria-activedescendant]))
      assert has_element?(view, ~s(li[role="option"][aria-selected="true"]), "Alpha")

      # Arrow down moves the selection; Enter opens whatever it landed on.
      view |> element("#home-notes") |> render_hook("switcher_move", %{"dir" => "down"})
      assert has_element?(view, ~s(li[role="option"][aria-selected="true"]), "Beta")

      view |> element("#home-notes") |> render_hook("switcher_select", %{})
      refute has_element?(view, "#note-switcher")
      assert has_element?(view, "#notes-editor-pane")
      assert render(view) =~ "Beta.md"

      # Escape closes without touching the note.
      view |> element("#home-notes") |> render_hook("open_switcher", %{})
      view |> element("#home-notes") |> render_hook("close_switcher", %{})
      refute has_element?(view, "#note-switcher")
      assert has_element?(view, "#notes-editor-pane")
    end

    test "wiki links open notes, offer to create missing ones, and list backlinks",
         %{conn: conn, root: root} do
      File.mkdir_p!(Path.join(root, "notes"))
      File.write!(Path.join([root, "notes", "Remote access.md"]), "# Remote access\n")

      File.write!(
        Path.join([root, "notes", "Launch.md"]),
        "See [[Remote access]] and [[Ghost]].\n"
      )

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "notes"})
      view |> element(~s(button[phx-value-path="Launch.md"])) |> render_click()

      html = render(view)
      assert html =~ ~s(href="#note/Remote+access.md")
      assert html =~ ~s(href="#note-new/Ghost")

      # A known link opens the note it names...
      view
      |> element("#notes-editor-pane")
      |> render_hook("open_link", %{"path" => "Remote access.md"})

      assert render(view) =~ "Remote access.md"
      # ...and the note it came from is listed as a backlink.
      assert has_element?(view, "#note-backlinks")
      assert has_element?(view, ~s(#note-backlinks button[phx-value-path="Launch.md"]))

      # A missing link creates the note rather than dead-ending.
      view
      |> element("#notes-editor-pane")
      |> render_hook("create_link", %{"title" => "Ghost"})

      assert File.exists?(Path.join([root, "notes", "Ghost.md"]))
      assert has_element?(view, ~s(button[phx-value-path="Ghost.md"]))
    end

    test "a wiki link inside a code fence is left as text", %{conn: conn, root: root} do
      File.mkdir_p!(Path.join(root, "notes"))
      File.write!(Path.join([root, "notes", "Syntax.md"]), "```\n[[Fenced]]\n```\n")

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "notes"})
      view |> element(~s(button[phx-value-path="Syntax.md"])) |> render_click()

      html = render(view)
      assert html =~ "[[Fenced]]"
      refute html =~ "#note-new/Fenced"
    end

    test "the new-note chord reveals the rail by clearing the selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "notes"})

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Open one"}})
      |> render_submit()

      assert has_element?(view, "#notes-editor-pane")

      view |> element("#home-notes") |> render_hook("new_note", %{})

      refute has_element?(view, "#notes-editor-pane")
      assert has_element?(view, "#new-note-title")
    end

    test "an agent's note command reaches an open Notes rail without a tab switch",
         %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "notes"})

      refute has_element?(view, ~s(button[phx-value-path="Agent note.md"]))

      {:ok, _created} =
        Commands.call("note_create", %{"title" => "Agent note", "body" => "from the terminal\n"})

      assert has_element?(view, ~s(button[phx-value-path="Agent note.md"]))
      assert File.exists?(Path.join([root, "notes", "Agent note.md"]))
    end

    test "an agent edit colliding with an open draft preserves both versions",
         %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "notes"})

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Shared"}})
      |> render_submit()

      # The operator is mid-sentence: a draft the server knows about but has not
      # saved (exactly the window `phx-debounce` opens).
      view |> element("#notes-editor-pane") |> render_hook("note_dirty", %{})
      assert has_element?(view, ~s(#note-save-status[data-state="unsaved"]))

      {:ok, read} = Commands.call("note_read", %{"path" => "Shared.md"})

      {:ok, _saved} =
        Commands.call("note_save", %{
          "path" => "Shared.md",
          "body" => "the agent's version\n",
          "revision" => read.revision
        })

      # The broadcast reaches the open panel: conflict, not a silent swap.
      assert has_element?(view, ~s(#note-save-status[data-state="conflict"]))
      assert has_element?(view, "#note-conflict")
      assert has_element?(view, "#copy-draft-button")
      assert File.read!(Path.join([root, "notes", "Shared.md"])) == "the agent's version\n"
    end

    test "the Activity sub-tab shows BC Minutes without an editing surface", %{conn: conn} do
      {:ok, _} = BusterClaw.Journal.append("Handled dispatch #7.", :agent)
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "select_home_tab", %{"tab" => "activity"})

      assert has_element?(view, "#home-activity")
      assert has_element?(view, "#activity-summary")
      assert has_element?(view, "#activity-reading")
      assert has_element?(view, "button[phx-value-tab='activity'].bg-primary")
      refute has_element?(view, "#journal-composer-form")
      refute has_element?(view, "#note-editor-form")
      assert render(view) =~ "Handled dispatch #7."
    end

    test "agent journal appends update an open Activity tab live", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "activity"})

      # An agent entry lands via the command surface; the broadcast should reach
      # the mounted LiveView and refresh BC Minutes without any user action.
      {:ok, _} = BusterClaw.Journal.append("Saved launch review.", :agent)

      _ = :sys.get_state(view.pid)
      assert render(view) =~ "Saved launch review."
    end

    test "Activity is the far-right Home tab" do
      expected = [
        {"chat", "Chat"},
        {"notes", "Notes"},
        {"calendar", "Calendar"},
        {"phone", "Phone"},
        {"studio", "Studio"},
        {"explore", "Explore"},
        {"activity", "Activity"}
      ]

      assert BusterClawWeb.StatusLive.home_tabs() == expected
    end

    test "the Explore sub-tab opens on Intro with a launcher tile per sub-tab",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_click(view, "select_home_tab", %{"tab" => "explore"})

      assert has_element?(view, "button[phx-value-tab='explore'].bg-primary")
      assert has_element?(view, "#home-explore")
      # Intro is the default sub-tab and carries the what-this-is copy.
      assert has_element?(
               view,
               "#home-explore button[phx-value-tab='intro'][aria-selected='true']"
             )

      assert html =~ "Learn the machine."

      # The 3-step onboarding moved here from the retired Settings Get Started
      # tab (08-02) — steps only, no quick-chat starters. It's a native
      # <details> collapsible, CLOSED by default (no `open` attribute).
      assert has_element?(view, "details#explore-get-started")
      refute has_element?(view, "details#explore-get-started[open]")

      # Step order: install a supported harness → chat → communications.
      assert [_, one, two, three] =
               String.split(html, ~r/<h3[^>]*>/) |> Enum.take(4)

      assert one =~ "Install a supported agent CLI"
      assert one =~ "Codex or OpenCode"
      assert one =~ "recommended one"
      assert two =~ "Chat with Buster Claw"
      assert three =~ "Set up communications"
      assert three =~ "Advanced setup"
      assert three =~ "still synced and archived"
      assert three =~ "trusted senders become Dispatch work"
      refute html =~ "Quick chat"

      # Every non-Intro sub-tab has a launcher tile (rail button + grid tile
      # both carry phx-value-tab, so each key appears at least twice).
      for key <- BusterClawWeb.ExplorePanel.tab_keys(), key != "intro" do
        tiles =
          view
          |> render()
          |> then(&Regex.scan(~r/phx-value-tab="#{key}"/, &1))

        assert length(tiles) >= 2, "expected a rail button AND a tile for #{key}"
      end
    end

    test "the site tiles open tabs that carry the copy and the external link",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explore"})

      # busterclaw.lol: planned asset model, without claiming vending is live.
      html = render_click(view, "select_explore_tab", %{"tab" => "site"})
      assert html =~ "planned"
      assert html =~ "Until number vending opens"
      refute html =~ "The number is the one thing you buy"
      assert html =~ "/browse?url=https%3A%2F%2Fbusterclaw.lol"

      html = render_click(view, "select_explore_tab", %{"tab" => "ntf"})
      assert html =~ "Notes That Float"
      assert html =~ "creative-writing and journaling app"
      assert html =~ "spatial, 3D view"
      assert html =~ "not Buster Claw&#39;s operator notebook"
      assert html =~ "/browse?url=https%3A%2F%2Fnotesthatfloat.com"
    end

    test "the BusterPhone tab separates recording a message from enqueueing it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explore"})

      html = render_click(view, "select_explore_tab", %{"tab" => "phone"})

      assert html =~ "BusterPhone — an answering machine that can act"
      assert html =~ ~s(href="/phone")

      # The spine of the tutorial: the archive comes before the trust decision,
      # so a stranger is always recorded and never work.
      assert html =~ "ARCHIVED + PLAYABLE"
      assert html =~ "THEN THE TRUST DECISION"

      # The two rules are DIFFERENT, and the roadmap's 08-04 audit exists because
      # the copy once collapsed them. Each rule is anchored so this asserts the
      # right cell rather than the word "PIN" appearing anywhere on the page.
      sms_rule = view |> element("[data-phone-sms-rule]") |> render()
      assert sms_rule =~ "trusted list"
      assert sms_rule =~ "No PIN involved"

      voicemail_rule = view |> element("[data-phone-voicemail-rule]") |> render()
      assert voicemail_rule =~ "trusted"
      assert voicemail_rule =~ "PIN-verified"
      assert voicemail_rule =~ "Two factors"

      # The five cycles.
      assert html =~ "Check the machine"
      assert html =~ "Reading is not hearing"
      assert html =~ "Decide who can give orders"
      assert html =~ "The message that answers itself"
      assert html =~ "Texting back"

      # Setup is described honestly: the operator's own Twilio and relay, and no
      # store to buy a number from yet (the busterclaw.lol tab says the same).
      assert html =~ "SUPABASE_SERVICE_ROLE_KEY"
      assert html =~ "There is no one-click"
      assert html =~ "planned work, not a store you can visit"

      # A contract with catalog metadata, not just frozen prose. Reads that an
      # untrusted voicemail-triage run may make are safe; the two POLICY reads are
      # not; every write that decides who may drive the queue is gated.
      catalog = Map.new(Commands.list_commands(), &{&1.name, &1})

      for name <- ~w(phone_list phone_get phone_stats) do
        entry = Map.fetch!(catalog, name)
        assert entry.type == :read
        assert entry.tier == :safe, "#{name} must stay safe — a triage run reads it"
      end

      for name <- ~w(phone_trusted_list phone_pin_list) do
        entry = Map.fetch!(catalog, name)
        assert entry.type == :read

        assert entry.tier == :restricted,
               "#{name} is policy data, not operational data — caller ID is spoofable"
      end

      for name <- ~w(phone_trusted_add phone_trusted_remove phone_pin_set
                     phone_pin_remove sms_send) do
        entry = Map.fetch!(catalog, name)
        assert entry.type == :mutate
        assert entry.tier == :restricted
        assert Map.get(entry, :gated, false), "#{name} must stay gated"
      end

      # phone_mark_heard is the one mutation that is deliberately NOT gated: it is
      # cheap and local. What protects the blinking light is that reading does not
      # clear it — so `phone_get` must stay a separate verb.
      mark_heard = Map.fetch!(catalog, "phone_mark_heard")
      assert mark_heard.type == :mutate
      refute Map.get(mark_heard, :gated, false)
      assert html =~ "It deliberately does not"

      # Same contract as the other tutorials: every command named must exist.
      for cmd <- ~w(phone_stats phone_list phone_get phone_mark_heard
                    phone_trusted_add phone_trusted_remove phone_trusted_list
                    phone_pin_set phone_pin_remove phone_pin_list sms_send) do
        assert html =~ "<code>#{cmd}</code>"

        assert Commands.command_type(cmd) != nil,
               "tutorial names #{cmd}, which is not in the command catalog"
      end

      refute html =~ "Tutorial in the works"
    end

    test "the Shaders tab teaches the file contract and that selection is yours alone",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explore"})

      html = render_click(view, "select_explore_tab", %{"tab" => "shaders"})

      assert html =~ "Shaders &amp; Backgrounds"
      assert html =~ ~s(href="/appearance")
      assert has_element?(view, "#explore-shader-catalog")
      assert has_element?(view, "#explore-shader-contract")

      # The catalog is rendered FROM Appearance, so it cannot describe a set of
      # built-ins or a pool size the module no longer has.
      for shader <- Appearance.builtin_shaders() do
        assert html =~ shader, "the Shaders tutorial does not name the #{shader} built-in"
      end

      assert html =~ "up to #{Appearance.max_images()} slots"

      # The claim the whole tab rests on: nothing on the command surface selects a
      # background, so an agent can propose a shader and never apply one. This is
      # the assertion that turns that from prose into a contract — add an
      # appearance/shader command later and this fails, as it should.
      selectors =
        Enum.filter(Commands.list_commands(), fn command ->
          String.starts_with?(command.name, "shader") or
            String.starts_with?(command.name, "appearance") or
            String.starts_with?(command.name, "background")
        end)

      assert selectors == [],
             "the Shaders tutorial says no command can select a background, but found: " <>
               Enum.map_join(selectors, ", ", & &1.name)

      assert html =~ "no commands on this"

      # The file contract, each part of it load-bearing.
      assert html =~ "fs_main"
      assert html =~ "64 KB"
      assert html =~ "shaderface"
      assert html =~ "never offered or honored"

      # Corrected 08-08 against the implementation: the catalog is click, and
      # there is no palette-coloured fallback — the layer simply does not paint.
      assert html =~ "a single click"
      refute html =~ "drag"
      assert html =~ "stays solid"

      refute html =~ "Tutorial in the works"
    end

    test "every Explore demo declares its contract and offers the two safe actions",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explore"})

      # The four fact rows are required attrs on `<.example>`, so a demo missing
      # one is a compile warning rather than a passing test. What this asserts is
      # the other half: that the rows actually REACH the page, on every tab that
      # has demos, and that the two safe actions ride along with each prompt.
      tabs = ~w(models shaders phone browser cmd gws)

      for tab <- tabs do
        html = render_click(view, "select_explore_tab", %{"tab" => tab})

        facts = Regex.scan(~r/data-demo-facts/, html)
        assert facts != [], "the #{tab} tutorial has no worked demos"

        for field <- ~w(needs touches confirm result) do
          rows = Regex.scan(~r/data-demo-#{field}/, html)

          assert length(rows) == length(facts),
                 "the #{tab} tutorial has #{length(facts)} demos but " <>
                   "#{length(rows)} #{field} rows"
        end

        # Copy prompt is always available; nothing on an Explore tab submits.
        assert html =~ "Copy prompt",
               "the #{tab} tutorial has no copyable prompt"

        refute html =~ ~s(phx-click="send"),
               "an Explore tutorial must never offer to submit anything"
      end
    end

    test "Try in Chat prefills the composer and does not submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explore"})
      render_click(view, "select_explore_tab", %{"tab" => "cmd"})

      # Clicking the button on a real tutorial prompt: it switches to Chat and
      # pushes the prefill event. Prefill only — the hook fills the input and the
      # operator presses send, which is what keeps opening a tutorial from ever
      # running a mutation.
      view
      |> element(~s([data-demo-try-in-chat][phx-value-text^="Save that plan"]))
      |> render_click()

      assert_push_event(view, "bc:chat_prefill", %{text: text})
      assert text =~ "Save that plan as a document"
      assert has_element?(view, "button[phx-value-tab='chat'].bg-primary")

      # A forged or oversized payload is refused rather than crashing the page —
      # same posture as the sub-tab whitelist beside it.
      render_click(view, "explore_try_in_chat", %{"text" => String.duplicate("x", 3000)})
      render_click(view, "explore_try_in_chat", %{})
      assert has_element?(view, "#home-agent-chat")
    end

    test "the GWS unattended cycle does not offer to paste an email into Chat",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explore"})

      html = render_click(view, "select_explore_tab", %{"tab" => "gws"})

      # That cycle's prompt is mail from a trusted sender, and the lesson is that
      # the trigger is the mail — offering "Try in Chat" on it would teach the
      # wrong mechanism. Every other prompt on the tab keeps the button.
      assert html =~ "You email — from your phone, hours later"

      prompts = Regex.scan(~r/data-demo-prompt/, html)
      buttons = Regex.scan(~r/data-demo-try-in-chat/, html)

      assert length(buttons) == length(prompts) - 1,
             "exactly one GWS prompt (the email) should omit Try in Chat — " <>
               "#{length(prompts)} prompts, #{length(buttons)} buttons"
    end

    test "the Models tab teaches the shape: unset, per surface, and the floor",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explore"})

      html = render_click(view, "select_explore_tab", %{"tab" => "models"})

      assert html =~ "Models — whose model, whose bill, and which surface"
      assert html =~ "ASKED PER SURFACE, FIRST MATCH WINS"

      # Fact 1: the CLI is the operator's, and so is the bill.
      assert html =~ "holds no Claude API key"
      assert html =~ "<code>claude</code>, <code>codex</code>"

      # Fact 2: unset means the flag is omitted, not that a default is missing.
      assert html =~ "--model"

      # Fact 3: the surface list is rendered FROM `ModelPolicy`, so it cannot
      # describe a surface set the policy no longer has. Assert every key lands
      # as its own token rather than as prose that happens to contain the word.
      for surface <- ModelPolicy.surface_keys() do
        assert html =~ ">#{surface}</span>",
               "the Models tutorial does not render the #{surface} surface"
      end

      # Fact 4: floors and claude-only pins render FROM the policy, so a surface
      # that declares one gets its badge without this tutorial being rewritten.
      # Both maps are empty since the trading stack left on 08-08 — these loops
      # are deliberately vacuous today and become real the moment one is
      # declared, which is the property worth keeping.
      for {_surface, floor} <- ModelPolicy.floors() do
        assert html =~ "floor: #{floor}"
      end

      for {surface, _reason} <- ModelPolicy.claude_only() do
        assert has_element?(
                 view,
                 "[data-model-surface='#{surface}'] [data-claude-only]"
               )
      end

      # Fact 5: where to change it — Settings, and the command.
      assert html =~ ~s(href="/settings")
      assert html =~ "<code>model_policy</code>"

      assert BusterClaw.Commands.command_type("model_policy") != nil,
             "the Models tutorial names model_policy, which is not in the command catalog"

      # The deferred Phase 4 items are named as absent, not implied as present.
      assert html =~ "no per-conversation model picker"
      assert html =~ "no per-surface or per-day total"
      assert html =~ "<code>codex</code>"

      # And the claim that replaced a FALSE one must not drift back. Every
      # harness does report what a run cost — claude's `result` event carries
      # `total_cost_usd`, measured 08-03. The tutorial said the opposite for
      # half a day because the roadmap said it and nobody ran the command.
      refute html =~ "does not report spend"

      refute html =~ "Tutorial in the works"
    end

    test "the Gmail/GWS tab is a real tutorial: prompts, real commands, no stub line",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explore"})

      html = render_click(view, "select_explore_tab", %{"tab" => "gws"})

      # The six cycles, prompt-first.
      assert html =~ "The morning brief"
      assert html =~ "Draft, don&#39;t send"
      assert html =~ "Remember the schedule"
      assert html =~ "The unattended cycle"
      assert html =~ "Make the files, not just the mail"
      assert html =~ "Send the file, not a link"
      assert html =~ "You type"

      # The explanation covers both connection paths and distinguishes archiving
      # ordinary mail from trusting a sender to create agent work.
      assert html =~ "bundled button when this build provides it"
      assert html =~ "Advanced setup"
      assert html =~ "Other mail is still synced and archived"

      # The security explanation is a contract with catalog metadata, not just
      # frozen prose. These three outbound paths use three different controls.
      catalog = Map.new(Commands.list_commands(), &{&1.name, &1})
      gmail_send = Map.fetch!(catalog, "gmail_send")
      drive_share = Map.fetch!(catalog, "drive_share")
      dispatch_reply = Map.fetch!(catalog, "dispatch_reply")

      assert gmail_send.type == :mutate
      assert gmail_send.tier == :restricted
      assert gmail_send.gated
      assert gmail_send.args["confirm_send"].required

      assert drive_share.type == :mutate
      assert drive_share.tier == :restricted
      refute Map.get(drive_share, :gated, false)
      assert drive_share.args["confirm_share"].required

      assert dispatch_reply.type == :mutate
      assert dispatch_reply.tier == :restricted
      refute Map.get(dispatch_reply, :gated, false)
      refute Map.has_key?(dispatch_reply.args, "confirm_send")

      assert html =~ "not a policy-gated command"
      assert html =~ "has no separate"
      refute html =~ "anything outbound — a send, a share — is gated"

      # Every command the copy names must exist in the catalog — the tutorial
      # is a contract with the command surface, enforced here so a rename
      # can't silently strand the docs.
      for cmd <- ~w(gmail_sync gmail_search gmail_read gmail_draft_create gmail_send
                    google_calendar_sync notify_create dispatch_reply
                    sheets_create sheets_append_values docs_create slides_create
                    slides_batch_update drive_folder_create drive_update drive_upload
                    drive_share drive_export) do
        assert html =~ "<code>#{cmd}</code>"

        assert BusterClaw.Commands.command_type(cmd) != nil,
               "tutorial names #{cmd}, which is not in the command catalog"
      end

      # Graduated from stub status: no placeholder line.
      refute html =~ "Tutorial in the works"
    end

    test "the Command List tab is the atlas: renamed, diagrammed, real commands",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explore"})

      html = render_click(view, "select_explore_tab", %{"tab" => "cmd"})

      # Renamed from "Cmd & Promptship" (operator, 08-02).
      assert html =~ "Command List"
      refute html =~ "Promptship"

      # The taxonomy is rendered from the catalog's three independent axes.
      assert has_element?(view, "#explore-command-taxonomy")
      assert has_element?(view, "#explore-command-operation-types")
      assert has_element?(view, "#explore-command-trust-tiers")
      assert has_element?(view, "#explore-command-policy-flags")

      commands = Commands.list_commands()
      types = Enum.frequencies_by(commands, & &1.type)
      tiers = Enum.frequencies_by(commands, & &1.tier)
      gated = Enum.count(commands, &Map.get(&1, :gated, false))

      assert element(view, "#explore-command-total") |> render() =~ to_string(length(commands))
      assert html =~ "#{Map.fetch!(types, :read)} read"
      assert html =~ "#{Map.fetch!(types, :trigger)} trigger"
      assert html =~ "#{Map.fetch!(types, :mutate)} mutate"
      assert html =~ "#{Map.fetch!(tiers, :safe)} safe"
      assert html =~ "#{Map.fetch!(tiers, :restricted)} restricted"
      assert html =~ "#{gated} commands are additionally"
      assert html =~ "Gated is a flag, not a third"
      refute html =~ "every tab, every feature"
      refute html =~ "nothing leaves the machine"

      # The funnel SVG uses the same corrected audit boundary.
      assert html =~ "SENTINEL AUDIT FEED"
      assert html =~ "MUTATES + TRIGGERS"
      assert html =~ ~s(role="img")

      # The six examples. Cycle 2 was "The market at a glance" until 08-08, when
      # the operator took trading out of what Explore teaches. The finance_*
      # commands still exist and are still on /cmd-list — the atlas simply stopped
      # leading a first-time user there, so this asserts the market cycle is GONE
      # rather than merely that the notebook one is present.
      assert html =~ "Capture the day"
      assert html =~ "The notebook and the vault"
      assert html =~ "The phone desk"
      assert html =~ "Web errands, hands off the wheel"
      assert html =~ "The queue is the desk"
      assert html =~ "It learns your routines"

      refute html =~ "The market at a glance"

      for cmd <- ~w(finance_quote finance_news finance_fundamentals finance_filings) do
        refute html =~ "<code>#{cmd}</code>",
               "the atlas should no longer teach #{cmd} — trading is out (08-08)"
      end

      # Same contract as the GWS tutorial: every named command must exist.
      for cmd <- ~w(document_save journal_append notify_create
                    note_search note_read note_save note_create note_list
                    phone_list phone_mark_heard sms_send
                    web_search browser_fetch bookmark_add
                    dispatch_enqueue dispatch_list dispatch_claim dispatch_done
                    memory_search
                    skill_analyze skill_suggestions skill_suggestion_approve) do
        assert html =~ "<code>#{cmd}</code>"

        assert BusterClaw.Commands.command_type(cmd) != nil,
               "tutorial names #{cmd}, which is not in the command catalog"
      end

      # The replacement cycle's own claim is a contract too: the note verbs are
      # restricted precisely because note titles are the operator's private
      # writing, so `note_list` being safe-tier would falsify the copy.
      catalog = Map.new(Commands.list_commands(), &{&1.name, &1})

      for name <- ~w(note_list note_read note_search note_create note_save) do
        assert Map.fetch!(catalog, name).tier == :restricted,
               "#{name} must stay restricted — the tutorial says even listing isn't safe-tier"
      end

      assert Map.fetch!(catalog, "note_save").args["revision"].required,
             "the tutorial teaches note_save's revision guard; it must stay required"

      refute html =~ "Tutorial in the works"
    end

    test "the BrowserControl tab teaches the three surfaces and the payment gate",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explore"})

      html = render_click(view, "select_explore_tab", %{"tab" => "browser"})

      # The three-surfaces diagram and its load-bearing labels.
      assert html =~ "YOUR LIVE TAB"
      assert html =~ "SANDBOX TAB"
      assert html =~ "AGENT WINDOW"

      # The five cycles.
      assert html =~ "Read over my shoulder"
      assert html =~ "Do the clicking"
      assert html =~ "A fresh tab that forgets"
      assert html =~ "Turn a routine into a check"
      assert html =~ "The long errand — Agent Mode"

      # The posture the closeout roadmap owns: stated, verbatim enough to find.
      # Decided 08-03 — the agent may now file the receipt, but still never pays,
      # and the tutorial must say which of the two of you confirmed.
      assert html =~ "The agent never pays and never holds a card."
      refute html =~ "cannot confirm a purchase"
      assert html =~ "agent_run_confirm_purchase"
      assert html =~ "which of you said so"
      assert html =~ "Ordinary reads do not each create a feed"
      refute html =~ "every read and every click lands"

      # Same contract as the other tutorials: every named command must exist.
      for cmd <- ~w(browser_current browser_read browser_capture_page
                    browser_screenshot browser_find_elements browser_click
                    browser_fill browser_open_tab browser_wait browser_extract
                    browser_flow browser_check_save browser_check_run
                    browser_check_list browser_control_probe
                    agent_run_start agent_run_navigate agent_run_act
                    agent_run_cart agent_run_resume agent_run_finish
                    agent_run_stop) do
        assert html =~ "<code>#{cmd}</code>"

        assert BusterClaw.Commands.command_type(cmd) != nil,
               "tutorial names #{cmd}, which is not in the command catalog"
      end

      refute html =~ "Tutorial in the works"
    end

    # The Trading tutorial left Explore on 08-08 with the surface it taught.

    test "an unknown Explore sub-tab key is refused, not crashed on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explore"})

      # The rail's whitelist is ExplorePanel.tab_keys/0; a forged key leaves the
      # current sub-tab in place.
      render_click(view, "select_explore_tab", %{"tab" => "../../etc"})

      assert has_element?(
               view,
               "#home-explore button[phx-value-tab='intro'][aria-selected='true']"
             )
    end

    test "the Explore sub-tab selection survives a glance at Chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # The assign lives in StatusLive, not the `:if`-discarded panel — so an
      # open tutorial must still be open after a round-trip through Chat.
      render_click(view, "select_home_tab", %{"tab" => "explore"})
      render_click(view, "select_explore_tab", %{"tab" => "browser"})
      render_click(view, "select_home_tab", %{"tab" => "chat"})
      refute has_element?(view, "#home-explore")

      render_click(view, "select_home_tab", %{"tab" => "explore"})

      assert has_element?(
               view,
               "#home-explore button[phx-value-tab='browser'][aria-selected='true']"
             )
    end
  end

  # A 1×1 PNG. Real magic bytes on purpose: `Attachments.classify/2` sniffs the
  # head and ignores every claim, so a fake payload would stage as `:binary` and
  # every thumbnail assertion below would pass for the wrong reason.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  describe "chat attachments" do
    setup do
      root = Path.join(System.tmp_dir!(), "bc_attach_#{System.unique_integer([:positive])}")
      prev = Application.get_env(:buster_claw, :attachments_root)
      Application.put_env(:buster_claw, :attachments_root, root)

      on_exit(fn ->
        Application.put_env(:buster_claw, :attachments_root, prev)
        File.rm_rf(root)
      end)

      {:ok, attach_root: root}
    end

    test "a dropped path is staged and chipped with its filename", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_hook(view, "attach_paths", %{"paths" => [write_file("shot.png", @png)]})

      assert html =~ "shot.png"
      assert has_element?(view, "[data-attach-chips]")
      # The chip carries a thumbnail, not just a name — the whole point of
      # showing it before the send is that the user can see WHICH image.
      assert html =~ "data:image/png;base64,"
    end

    test "a refusal from the hook is surfaced with its reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        render_hook(view, "attach_error", %{
          "reason" => "too_large",
          "filename" => "enormous.psd"
        })

      assert html =~ "enormous.psd"
      assert html =~ "too large"
      assert has_element?(view, "[data-attach-error]")
    end

    test "a refusal from the store is surfaced too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # A directory is not a file. The store refuses it (`:not_regular`) and the
      # composer has to say so — a drop that silently does nothing is the false
      # affordance this feature exists to remove.
      html = render_hook(view, "attach_paths", %{"paths" => [System.tmp_dir!()]})

      assert has_element?(view, "[data-attach-error]")
      assert html =~ "cannot be attached" or html =~ "could not be attached"
      refute has_element?(view, "[data-attach-chips]")
    end

    test "an attachment can be removed before it is sent", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_hook(view, "attach_paths", %{"paths" => [write_file("notes.md", "# hello\n")]})

      assert has_element?(view, "[data-attach-chip]")

      html =
        view
        |> element(~s([data-attach-chips] button[phx-click="remove_attachment"]))
        |> render_click()

      refute html =~ "notes.md"
      refute has_element?(view, "[data-attach-chips]")
      # Removed from the staging directory too — a file the user cancelled has
      # no reason to sit on disk until the conversation is deleted.
      assert Attachments.list(active_chat(view)) == []
    end

    test "a refused attachment blocks the send until it is dismissed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_hook(view, "attach_error", %{"reason" => "too_large", "filename" => "huge.png"})

      html = view |> form("#home-composer", %{"message" => "look at this"}) |> render_submit()

      # Nothing went. Silently sending a message whose image did not make it is
      # the failure this gate exists for, and the banner has to say so.
      assert html =~ "Nothing was sent"
      refute html =~ ~s(class="ic-drop-in)

      html =
        view
        |> element(~s([data-attach-error] button[phx-click="dismiss_attach_error"]))
        |> render_click()

      refute html =~ "Nothing was sent"
      refute has_element?(view, "[data-attach-error]")
    end

    test "sending clears the composer's chips", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      conv = active_chat(view)
      start_fake_chat(conv)

      render_hook(view, "attach_paths", %{"paths" => [write_file("shot.png", @png)]})
      assert has_element?(view, "[data-attach-chip]")

      view |> form("#home-composer", %{"message" => "what is this?"}) |> render_submit()

      refute has_element?(view, "[data-attach-chips]")
      # The echo arrives over PubSub, a hop after the submit returns.
      html = render(view)
      # The message itself still shows what rode with it...
      assert html =~ "what is this?"
      assert has_element?(view, "[data-attach-image]")
      # ...and the raw citation fence never reaches the reader.
      refute html =~ "```attachments"
    end

    test "an attachment-only message is a real message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      start_fake_chat(active_chat(view))

      render_hook(view, "attach_paths", %{"paths" => [write_file("shot.png", @png)]})
      view |> form("#home-composer", %{"message" => ""}) |> render_submit()

      assert has_element?(view, "[data-attach-image]")
      refute render(view) =~ "```attachments"
    end

    test "a user message with an image shows a thumbnail that opens the modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      conv = active_chat(view)
      {:ok, att} = stage(conv, "shot.png", @png)

      send(view.pid, {:agent_chat, conv, {:message, %{role: :user, text: marker("look", [att])}}})

      html = render(view)
      assert html =~ "look"
      assert html =~ "data:image/png;base64,"
      assert has_element?(view, ~s([data-attach-image="#{att.id}"]))

      # It joined the drawings' visual pool, so the EXISTING modal opens it —
      # there is no second viewer.
      html = view |> element(~s([data-attach-image] )) |> render_click()
      assert html =~ "ic-svg-modal"
    end

    test "a non-image attachment renders as a chip, not a broken thumbnail", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      conv = active_chat(view)
      {:ok, att} = stage(conv, "report.pdf", "%PDF-1.4\n trailing bytes\n")

      send(
        view.pid,
        {:agent_chat, conv, {:message, %{role: :user, text: marker("read it", [att])}}}
      )

      assert has_element?(view, ~s([data-attach-file="#{att.id}"]))
      refute has_element?(view, "[data-attach-image]")
    end

    test "an SVG never renders as a thumbnail, whatever it claims to be", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      conv = active_chat(view)

      svg = ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert("x")</script></svg>|
      {:ok, att} = stage(conv, "trojan.svg", svg)

      send(view.pid, {:agent_chat, conv, {:message, %{role: :user, text: marker("hm", [att])}}})

      # A chip, not an <img>. An SVG is a document that can carry script, and the
      # only path that renders one live sanitizes it first — an attachment does
      # not, so it does not get to be one. The 07-04 review paid for this once.
      assert has_element?(view, ~s([data-attach-file="#{att.id}"]))
      refute has_element?(view, "[data-attach-image]")
      refute render(view) =~ "alert("
    end

    test "a forged citation cannot talk a file into being an image", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      conv = active_chat(view)
      {:ok, att} = stage(conv, "notes.md", "# not an image\n")

      # The fence is prose in an append-only log; nothing stops it claiming
      # anything. What renders comes from the STORE's record, sniffed from the
      # bytes, so the claim buys nothing.
      forged = marker("look", [%{att | media_type: "image/png", kind: :image}])
      send(view.pid, {:agent_chat, conv, {:message, %{role: :user, text: forged}}})

      refute has_element?(view, "[data-attach-image]")
      assert has_element?(view, ~s([data-attach-file="#{att.id}"]))
    end

    test "an attachment is still rendered after a reload", %{conn: conn} do
      conv = "default"
      {:ok, att} = stage(conv, "shot.png", @png)
      BusterClaw.Agent.Transcript.record(conv, "user", marker("what is this?", [att]))

      # A fresh mount — nothing carried over from the session that sent it. The
      # transcript names the ids, the store still has the bytes.
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "what is this?"
      refute html =~ "```attachments"
      assert has_element?(view, ~s([data-attach-image="#{att.id}"]))
      assert render(view) =~ "data:image/png;base64,"
    end

    test "a reloaded attachment whose bytes are gone still names itself", %{conn: conn} do
      conv = "default"
      {:ok, att} = stage(conv, "shot.png", @png)
      BusterClaw.Agent.Transcript.record(conv, "user", marker("what is this?", [att]))
      :ok = Attachments.purge(conv)

      {:ok, view, html} = live(conn, ~p"/")

      # The citation is enough to render an honest chip. Disappearing would be
      # the alternative, and a message that quietly loses its attachment is
      # exactly what this design is trying to make impossible.
      assert html =~ "shot.png"
      assert html =~ "No longer available"
      assert has_element?(view, ~s([data-attach-file="#{att.id}"]))
    end

    test "an unsent attachment comes back after a reload", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_hook(view, "attach_paths", %{"paths" => [write_file("draft.md", "# draft\n")]})

      {:ok, _view, html} = live(conn, ~p"/")

      # It is still staged and nothing cited it, so it is still in the composer
      # rather than an orphan on disk that nothing on screen admits to.
      assert html =~ "draft.md"
      assert html =~ "data-attach-chips"
    end

    test "closing a conversation purges its attachments and nobody else's", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      conv = active_chat(view)
      {:ok, _} = stage(conv, "mine.png", @png)

      other = "bystander"
      {:ok, _} = stage(other, "theirs.png", @png)

      view |> element(~s([role="tab"] span[phx-click="close_chat"])) |> render_click()

      assert Attachments.list(conv) == []
      assert [%{filename: "theirs.png"}] = Attachments.list(other)
    end
  end

  # --- attachment helpers ----------------------------------------------------

  defp write_file(name, contents) do
    dir = Path.join(System.tmp_dir!(), "bc_drop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, contents)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  defp stage(conv, name, contents) do
    Attachments.stage(
      conv,
      %{filename: name, media_type: MIME.from_path(name), source: :upload},
      {:bytes, contents}
    )
  end

  # The citation fence exactly as the composer writes it, so these tests pin the
  # format the transcript actually carries rather than a test-only shape.
  defp marker(text, attachments),
    do: BusterClawWeb.Status.ChatAttachments.marker(text, attachments)

  # A conversation process with a spawner that starts nothing, so a submit
  # succeeds (and echoes the user message back over PubSub) without a CLI.
  defp start_fake_chat(conv_id) do
    {:ok, pid} =
      BusterClaw.Agent.Chat.start_link(
        conv_id: conv_id,
        spawner: fn _prompt, _opts -> {:ok, make_ref()} end,
        transport_mod: BusterClaw.Agent.FakePersistentTransport,
        persist: false,
        audit: false
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end
end
