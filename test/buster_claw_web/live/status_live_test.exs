defmodule BusterClawWeb.StatusLiveTest do
  @moduledoc """
  The work area's shell and the Clock panel's Contacts and Time & Place tabs.
  The chat, the Notify tab and the Explained panel have files of their own
  under `status/` (split 10-16).
  """
  use BusterClawWeb.HomeCase

  alias BusterClaw.Appearance
  alias BusterClaw.Contacts

  test "GET / renders the home shell with the corner widget and chat", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Buster Claw"
    # Browser-style shell: top tab strip + bottom dock (former sidebar).
    assert response =~ ~s(id="tab-strip")
    assert response =~ ~s(phx-hook="TabStrip")
    assert response =~ ~s(id="app-sidebar")
    refute response =~ ~s(id="app-dock")
    # Get Started moved to a Settings sub-tab — the home page no longer carries it.
    refute response =~ ~s(id="home-get-started")
    refute response =~ "Install Claude Code"
    # "Go on duty" is the DOCK's control since 09-13 (THREE_DOORS Phase 2), on
    # every page; the old home-panel version is what must stay gone.
    refute response =~ ~s(id="home-on-duty")
    refute response =~ "./buster-claw shift run"
    # The unattended-shift panel was removed; the chat + prompt pathway replaces it.
    refute response =~ ~s(id="home-shift")
    refute response =~ "Unattended Shift"
    # Corner widget: Contacts / Time & Place / Notify (Calendar moved out of the
    # widget and onto the Home sub-tab row).
    assert response =~ ~s(id="home-corner-widget")
    assert response =~ ~s(id="home-clock")
    assert response =~ "Contacts"
    # Home sub-tabs. Notes and Calendar LEFT on 09-05 for the Workspace page's
    # own rail; asserted as absences here because "the tab row still offers it"
    # is precisely the half of a move that gets forgotten, and a stale button
    # would raise on click (the rail and the guard share one list).
    assert response =~ "Activity"
    refute response =~ ~s(phx-value-tab="notes")
    refute response =~ ~s(phx-value-tab="calendar")
    # Trading moved to a top-level tab (TRADING_TAB_ROADMAP Phase 0); the Home
    # sub-tab row must not offer it.
    refute response =~ ~s(phx-value-tab="trading")
    # The Contacts widget tab is now a comms hub (recent phone activity + contacts
    # with Text/Call/Email); its panel keeps the id and shows empty states here.
    assert response =~ ~s(id="home-contacts-panel")
    assert response =~ "No contacts yet"
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

  # 09-13-26: the widget's Contacts tab no longer adds anyone. The operator wanted
  # one place to add a contact — the Phone tab, where a person is created and
  # marked trusted. Removing a trust entry from the widget still works.
  test "removes a trusted sender from the home panel", %{conn: conn, root: root} do
    contact = "dana@example.org"
    File.write!(Path.join(root, "memory/trusted-email-senders.md"), "# Trusted\n\n- #{contact}\n")

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ contact
    refute html =~ "No trusted senders"

    html =
      view
      |> element(~s(button[phx-value-entry="#{contact}"]))
      |> render_click()

    assert html =~ "No trusted senders"
    refute html =~ contact
  end

  # 10-15: adding a contact came back here when the Phone tab (its only home
  # since 09-13) was removed. Created and trusted in one step.
  test "the home widget adds a contact and trusts them in one step", %{conn: conn, root: root} do
    File.write!(Path.join(root, "memory/trusted-email-senders.md"), "# Trusted\n")
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "select_widget_tab", %{"tab" => "contacts"})

    refute has_element?(view, "#home-add-contact-form")
    view |> element("#home-add-contact-toggle") |> render_click()
    assert has_element?(view, "#home-add-contact-form")

    html =
      view
      |> form("#home-add-contact-form", %{
        "name" => "Dana Printshop",
        "email" => "dana@example.org"
      })
      |> render_submit()

    assert html =~ "Dana Printshop"
    refute has_element?(view, "#home-add-contact-form")
    assert BusterClaw.TrustedSenders.trusted?("dana@example.org")
    [contact] = Contacts.list_contacts()
    assert Contacts.trusted?(contact)

    # A bad entry stays on the form with its reason, and trusts nobody.
    view |> element("#home-add-contact-toggle") |> render_click()

    html =
      view
      |> form("#home-add-contact-form", %{"name" => "Dup", "email" => "dana@example.org"})
      |> render_submit()

    assert html =~ "email"
    assert has_element?(view, "#home-add-contact-form")
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

    # The three tabs became three modules on 08-15 (WIDGET_BACKGROUND Phase 0),
    # and this is what makes that a move rather than a hope. The rail test above
    # already renders every panel — a broken extraction would raise inside
    # `render_click` — but it does so incidentally, while asserting something
    # else. This says out loud that each tab draws ITS OWN panel, so a dispatch
    # wired to the wrong sibling fails here instead of looking fine.
    # WIDGET_BACKGROUND Phase 2. The panel's shader was a literal until 08-15,
    # and `data-daylight` was a literal beside it.
    test "the Time & Place panel follows the surface, and the clock follows the shader",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Default: the sky, with the flag that makes its sun track the clock.
      assert has_element?(
               view,
               ~s(#home-place-panel [data-shader="daycycle"][data-daylight="true"])
             )

      # Pick something else and the panel follows, live — no reload.
      {:ok, _} = Appearance.set_background(:widget, "waves")
      render(view)

      assert has_element?(view, ~s(#home-place-panel [data-shader="waves"]))
      refute has_element?(view, ~s(#home-place-panel [data-shader="daycycle"]))

      # `waves` does not read the clock, so it must not be told the time.
      assert has_element?(view, ~s(#home-place-panel [data-daylight="false"]))

      # `default` is the only way back — daycycle is in no catalog row.
      {:ok, "default"} = Appearance.set_background(:widget, "default")
      render(view)

      assert has_element?(
               view,
               ~s(#home-place-panel [data-shader="daycycle"][data-daylight="true"])
             )
    end

    # The failure D3 exists to prevent, and the reason it is not a detail: before
    # this, `data-daylight` was a literal on the ONE mount that ran daycycle. Any
    # other surface running it would render a sun frozen wherever `lens.x = 0`
    # puts it — a broken-looking shader with no error anywhere.
    test "daycycle carries its clock onto a surface that never had the flag",
         %{conn: conn} do
      # The widget's default is the only way to get daycycle anywhere, so this
      # asserts the derivation rather than a selection: the flag is computed
      # from the shader name, so it is right on whichever surface runs it.
      assert Appearance.needs_daylight?("daycycle")

      for shader <- Appearance.builtin_shaders() do
        refute Appearance.needs_daylight?(shader),
               "#{shader} does not read the clock and must not be handed one"
      end

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, ~s([data-shader="daycycle"][data-daylight="true"]))
      assert has_element?(view, ~s([data-shader="smoke"][data-daylight="false"]))
    end

    test "each widget tab renders its own panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      panels = %{
        "place" => "#home-place-panel",
        "contacts" => "#home-comms-panel",
        "notify" => "#home-notify-panel"
      }

      # All three are ALWAYS in the DOM — the widget hides the other two with a
      # class rather than `:if`-ing them away. That is the opposite of what
      # `PhoneComponent` does, and deliberately so there: its moduledoc records
      # that `:if` tears down `phx-update="ignore"` shader canvases instead of
      # letting them animate unseen. The widget's Time & Place canvas therefore
      # runs whichever tab is showing (WIDGET_BACKGROUND Part I).
      for {_tab, selector} <- panels do
        assert has_element?(view, selector), "#{selector} is not rendered at all"
      end

      # So the claim worth asserting is not "is it rendered" — that is vacuously
      # true — but WHICH ONE is inside the hidden wrapper. Only the wrapper
      # carries `hidden`, so a dispatch wired to the wrong sibling shows up here
      # as the wrong panel being the visible one.
      for {tab, selector} <- panels do
        render_click(view, "select_widget_tab", %{"tab" => tab})

        refute has_element?(view, "div.hidden #{selector}"),
               "selecting #{tab} left #{selector} hidden"

        for {other, other_selector} <- panels, other != tab do
          assert has_element?(view, "div.hidden #{other_selector}"),
                 "selecting #{tab} left #{other}'s panel visible too"
        end
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

  describe "ask about this page" do
    test "?ask=page stages a sentence naming the page, on the Chat sub-tab, and sends nothing",
         %{conn: conn} do
      query =
        URI.encode_query(%{
          "ask" => "page",
          "url" => "https://example.com/a?b=1",
          "title" => "Example Domain"
        })

      {:ok, view, _html} = live(conn, "/?" <> query)

      assert_push_event(view, "bc:chat_prefill", %{text: text})
      assert text =~ "“Example Domain”"
      assert text =~ "https://example.com/a?b=1"
      assert text =~ "Read it with the browser commands"
      assert text =~ "then wait for what I want done with it"
      assert has_element?(view, "#home-composer")
      # Prefill is a client-side write into the textarea; nothing was submitted.
      refute render(view) =~ "Example Domain"
    end

    test "with no title the sentence still reads", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, "/?" <> URI.encode_query(%{"ask" => "page", "url" => "https://example.com/"}))

      assert_push_event(view, "bc:chat_prefill", %{text: text})
      assert text =~ "I have https://example.com/ open in the browser."
    end

    test "a non-http URL or a bare word stages nothing", %{conn: conn} do
      for url <- ["javascript:alert(1)", "example.com", "file:///etc/passwd", ""] do
        {:ok, view, _html} =
          live(conn, "/?" <> URI.encode_query(%{"ask" => "page", "url" => url}))

        refute_push_event(view, "bc:chat_prefill", %{})
      end
    end

    test "an overlong title is cut, not refused", %{conn: conn} do
      title = String.duplicate("x", 500)

      query =
        URI.encode_query(%{"ask" => "page", "url" => "https://example.com/", "title" => title})

      {:ok, view, _html} = live(conn, "/?" <> query)
      assert_push_event(view, "bc:chat_prefill", %{text: text})
      assert text =~ String.duplicate("x", 200)
      refute text =~ String.duplicate("x", 201)
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
      assert has_element?(view, "#workbench-pane-chat[data-active='true']")
    end
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

  describe "work area panels" do
    test "chat is the default view and the calendar is hidden", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#calendar-grid")
      # The active sub-tab carries the primary wash; Chat is active on load.
      assert has_element?(view, "#workbench-pane-chat[data-active='true']")
      refute has_element?(view, "#workbench-pane-calendar[data-active='true']")
    end

    test "the rail and the select_home_tab guard cannot disagree", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Every tab the rail offers must be one the server accepts. This is the
      # test for the bug the single list exists to prevent.
      for {key, _label} <- BusterClawWeb.StatusLive.home_tabs() do
        assert has_element?(view, "#home-tab-#{key}")
        render_click(view, "select_home_tab", %{"tab" => key})
        assert has_element?(view, "#workbench-pane-#{key}[data-active='true']")
      end
    end

    test "the Activity sub-tab shows BC Minutes without an editing surface", %{conn: conn} do
      {:ok, _} = BusterClaw.Journal.append("Handled dispatch #7.", :agent)
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "select_home_tab", %{"tab" => "activity"})

      assert has_element?(view, "#home-activity")
      assert has_element?(view, "#activity-summary")
      assert has_element?(view, "#activity-reading")
      assert has_element?(view, "#workbench-pane-activity[data-active='true']")
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

    test "the work area menu includes every panel, including Clock" do
      expected = [
        {"chat", "Chat"},
        {"workspace", "Workspace"},
        {"notes", "Notes"},
        {"calendar", "Calendar"},
        {"terminal", "Terminal"},
        {"pockets", "Pockets"},
        {"explained", "Explained"},
        {"activity", "Activity"},
        {"clock", "Clock"}
      ]

      assert BusterClawWeb.StatusLive.home_tabs() == expected
    end
  end
end
