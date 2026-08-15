defmodule BusterClawWeb.PhoneLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Contacts
  alias BusterClaw.Pockets
  alias BusterClaw.Pockets.Faces
  alias BusterClaw.Telephony

  defp record!(attrs) do
    defaults = %{
      direction: "inbound",
      kind: "voicemail",
      from_number: "+15035550142",
      to_number: "+18445550100",
      occurred_at: DateTime.utc_now(:second)
    }

    {:ok, event} = Telephony.record_event(Map.merge(defaults, attrs), observe: false)
    event
  end

  defp select_tab(view, key) do
    view |> element("button[role=tab][phx-value-tab=#{key}]") |> render_click()
    view
  end

  @ours "+18445550100"
  @operator "+15033412655"

  # Voice is off in test, which is the state most of this file asserts against.
  # Turning it on has to happen BEFORE `live/2` — readiness is read at mount, so
  # a switch flipped afterwards describes a tab nobody is looking at.
  defp enable_voice(_context) do
    previous = Application.get_env(:buster_claw, :twilio)

    Application.put_env(:buster_claw, :twilio, %{
      account_sid: "AC_test",
      auth_token: "tok",
      phone_number: @ours,
      operator_number: @operator,
      voice_enabled: true
    })

    on_exit(fn -> Application.put_env(:buster_claw, :twilio, previous) end)
  end

  defp dial(view, digits) do
    for key <- String.graphemes(digits) do
      view |> element("#phone-dial-key-#{key}") |> render_click()
    end

    view
  end

  test "renders the empty machine", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/phone")

    assert html =~ "Message machine"
    assert html =~ "The machine is listening"
  end

  test "lists a voicemail and marks it heard on select", %{conn: conn} do
    event =
      record!(%{
        transcript: "Your order is ready for pickup.",
        recording_path: "raw/2026-07-11/voicemail-demo-1.m4a",
        duration_seconds: 9
      })

    assert Telephony.unheard_count() == 1

    {:ok, view, html} = live(conn, "/phone")

    assert html =~ "(503) 555-0142"
    assert html =~ "Your order is ready for pickup."

    detail =
      view
      |> element("button[phx-click=select_event][phx-value-id='#{event.id}']")
      |> render_click()

    assert detail =~ "/phone/recording?path=raw%2F2026-07-11%2Fvoicemail-demo-1.m4a"
    assert detail =~ "Transcript"
    assert has_element?(view, "#phone-event-player")
    refute has_element?(view, "#phone-keypad-stage")
    assert Telephony.unheard_count() == 0

    view |> element("#phone-close-detail") |> render_click()

    assert has_element?(view, "#phone-keypad-stage")
    refute has_element?(view, "#phone-message-detail")
  end

  test "groups texts into threads and opens one", %{conn: conn} do
    record!(%{
      kind: "sms",
      body: "Is the workbench still for sale?",
      occurred_at: DateTime.add(DateTime.utc_now(:second), -300)
    })

    record!(%{
      kind: "sms",
      direction: "outbound",
      from_number: "+18445550100",
      to_number: "+15035550142",
      body: "It is. Evenings work best."
    })

    {:ok, view, _html} = live(conn, "/phone")

    html =
      view
      |> element("button[phx-click=filter][phx-value-kind=sms]")
      |> render_click()

    assert html =~ "It is. Evenings work best."

    thread =
      view
      |> element("button[phx-click=select_thread][phx-value-number='+15035550142']")
      |> render_click()

    assert thread =~ "Is the workbench still for sale?"
    assert thread =~ "Buster"
  end

  test "shows a voicemail's cost in the log, the total, and the breakdown", %{conn: conn} do
    # $0.24 total (call 0.0085 + rec 0.0025 + txt 0.23), fully priced.
    event =
      record!(%{
        recording_path: "raw/2026-07-11/vm.m4a",
        duration_seconds: 30,
        cost_micros: 240_000,
        cost_currency: "USD",
        cost_synced_at: DateTime.utc_now(:second),
        metadata: %{
          "cost_breakdown" => %{"call" => 8500, "recording" => 2500, "transcription" => 229_000}
        }
      })

    {:ok, view, html} = live(conn, "/phone")

    # The per-message chip and the header total both render the formatted cost.
    assert html =~ "$0.24"

    # The detail breakdown keeps sub-cent precision ($0.0085), not a rounded $0.01.
    detail =
      view
      |> element("button[phx-value-id='#{event.id}']")
      |> render_click()

    assert detail =~ "$0.0085"
    assert detail =~ "call $0.0085"
  end

  test "an unpriced voicemail reads 'pricing…' in the detail, no total chip", %{conn: conn} do
    event = record!(%{recording_path: "raw/2026-07-11/vm2.m4a", duration_seconds: 12})

    {:ok, view, _html} = live(conn, "/phone")

    detail =
      view
      |> element("button[phx-value-id='#{event.id}']")
      |> render_click()

    assert detail =~ "pricing…"
  end

  test "playback panel rests on the functional keypad", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/phone")

    assert has_element?(view, "#phone-keypad-stage")
    assert has_element?(view, "#phone-keypad-playback[data-shader=keypad]")
    assert has_element?(view, "#phone-keypad-controls")
    assert has_element?(view, "#phone-dial-key-1")
    assert has_element?(view, "#phone-dial-key-0")
    refute has_element?(view, "#phone-contact-actions")
    refute has_element?(view, "#phone-message-detail")
  end

  # LAUNCH_ROADMAP G-37 closed by *labelling in place*: the keypad had to say on
  # screen what it did, because gating it behind Labs was declined. On 08-15 the
  # obligation narrowed rather than lifted — the keypad dials now, but calling is
  # off until the operator sets the voice switch, so the line has to say WHY and
  # name the fix. A disabled control whose reason lives in a `title` is the same
  # G-37 failure wearing a different hat.
  test "the keypad says on screen why calling is off, and names the fix", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/phone")

    assert has_element?(view, "#phone-keypad-purpose", "Searches your contacts")
    assert has_element?(view, "#phone-keypad-purpose", "calling off")
    assert has_element?(view, "#phone-keypad-purpose", "BUSTER_CLAW_VOICE_ENABLED")

    # Not just the accessible name: the disclosure has to survive as visible text.
    refute view |> element("#phone-keypad-purpose") |> render() =~ "sr-only"

    # And the claim it replaced must not survive anywhere — it became false the
    # hour `phone_call` shipped, and a stale disclosure is worse than none.
    refute render(view) =~ "outbound calling isn't built"
  end

  # The other half of the same obligation, and the half a disclosure line cannot
  # carry on its own: the button has to actually be inert. A live control beside
  # a paragraph explaining why it will fail is worse than either alone.
  test "with the switch off the Call button is disabled and carries no click",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/phone")
    dial(view, "5035550142")

    assert has_element?(view, "#phone-dial-call[disabled]")

    # Not merely styled as disabled: there is no event to send. A `disabled`
    # attribute is a browser courtesy, and this component is reachable over a
    # socket by anything that can speak to it.
    refute has_element?(view, "#phone-dial-call[phx-click]")

    # So the switch is re-read in the handler too, and the event refuses on its
    # own — sent straight down the socket, past the button that isn't there.
    html =
      view
      |> with_target("#phone-root")
      |> render_click("call_prompt", %{"number" => "+15035550142"})

    assert html =~ "BUSTER_CLAW_VOICE_ENABLED"
    refute has_element?(view, "#phone-call-confirm")
  end

  test "keypad searches contacts by number and supports correction", %{conn: conn} do
    {:ok, contact} =
      Contacts.create_contact(%{name: "Dana Printshop", phone: "+15035550142"})

    {:ok, view, _html} = live(conn, "/phone")

    view |> element("#phone-dial-key-5") |> render_click()
    view |> element("#phone-dial-key-0") |> render_click()
    view |> element("#phone-dial-key-3") |> render_click()

    assert has_element?(view, "#phone-dialed-number", "503")
    assert has_element?(view, "#phone-dial-match[phx-value-id='#{contact.id}']", "Dana Printshop")

    view |> element("#phone-dial-backspace") |> render_click()
    assert has_element?(view, "#phone-dialed-number", "50")

    view |> element("#phone-dial-clear") |> render_click()
    assert has_element?(view, "#phone-dialed-number", "Enter a number")
    refute has_element?(view, "#phone-dial-match")
  end

  test "selected contact shows pending actions and collapsed caller history", %{conn: conn} do
    {:ok, contact} =
      Contacts.create_contact(%{name: "Dana Printshop", phone: "+15035550142"})

    record!(%{
      from_number: contact.phone,
      transcript: "Call me after lunch.",
      recording_path: "raw/2026-07-11/voicemail-dana.m4a"
    })

    {:ok, view, _html} = live(conn, "/phone")

    view |> element("#phone-dial-key-5") |> render_click()
    view |> element("#phone-dial-key-0") |> render_click()
    view |> element("#phone-dial-key-3") |> render_click()
    view |> element("#phone-dial-match") |> render_click()

    assert has_element?(view, "#phone-dialed-number", "(503) 555-0142")
    assert has_element?(view, "#phone-contact-actions")
    assert has_element?(view, "#phone-contact-text[disabled]")
    # Call is disabled here for a *different* reason than Text: the voice switch
    # is off in test, not because the feature is unbuilt. That is the whole A2P
    # story in two buttons — texting waits on a registration at Twilio, calling
    # never needed one.
    assert has_element?(view, "#phone-contact-call[disabled]")
    refute has_element?(view, "#phone-dial-match")

    # Caller history rides with the contact, so it is on the Contacts tab. The
    # selection made from the keypad above carries across — the tabs are two
    # views of one component's state, not two components.
    select_tab(view, "contacts")

    assert has_element?(view, "#phone-contact-history:not([open])")
    assert has_element?(view, "#phone-contact-history-toggle", "Caller history")
    assert has_element?(view, "#phone-contact-history-items", "Voicemail")
  end

  test "contacts: add via form, select shows the shaderface card", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/phone")

    assert render(select_tab(view, "contacts")) =~ "No contacts yet"

    view |> element("button[phx-click=toggle_add_contact]") |> render_click()

    card =
      view
      |> element("form[phx-submit=add_contact]")
      |> render_submit(%{"name" => "Dana", "phone" => "(503) 555-0142", "email" => ""})

    # Saving lands on the face card: ShaderFace mount + normalized number +
    # generative face selected by default.
    assert card =~ "Dana"
    assert card =~ "data-face-canvas"
    assert card =~ "(503) 555-0142"
    assert card =~ "Generative"
  end

  test "contact names replace raw numbers in the log", %{conn: conn} do
    {:ok, _} = Contacts.create_contact(%{name: "Dana Printshop", phone: "+15035550142"})

    record!(%{
      transcript: "Poster order is ready.",
      recording_path: "raw/2026-07-11/voicemail-demo-1.m4a"
    })

    {:ok, view, html} = live(conn, "/phone")

    assert html =~ "Dana Printshop"
    # The log's clip header carries the name, not the raw number (which still
    # legitimately appears in the contacts list on the right).
    assert has_element?(view, "button[phx-click=select_event]", "Dana Printshop")
    refute has_element?(view, "button[phx-click=select_event]", "(503) 555-0142")
  end

  test "recording route refuses path escapes", %{conn: conn} do
    conn = get(conn, "/phone/recording", %{"path" => "../../etc/passwd"})
    assert conn.status == 404
  end

  describe "the sub-tab rail" do
    # THE DRIFT TEST. On 08-08 the homepage's Phone tab shipped as a rail button
    # the server refused: the rail offered it, the guard had never heard of it,
    # and the click raised. This walks the registry and clicks EVERY button it
    # produces, so a key that reaches the rail without reaching the guard fails
    # here rather than under the operator's cursor.
    #
    # It is deliberately written over `Registry.tabs()` rather than over a
    # literal `["messages", "contacts"]`: a literal would have to be updated by
    # the same person who added the tab, which is the failure mode itself.
    test "every tab the registry renders is one the guard accepts", %{conn: conn} do
      {:ok, view, html} = live(conn, "/phone")

      for tab <- BusterClawWeb.Phone.Registry.tabs() do
        assert html =~ ~s(phx-value-tab="#{tab.key}"),
               "#{tab.key} is in the registry but the rail did not render it"

        rendered = render(select_tab(view, tab.key))

        assert rendered =~ ~s(data-phone-tab="#{tab.key}"),
               "the rail offers #{tab.key} but clicking it showed no panel"
      end
    end

    test "Messages is the tab a fresh mount lands on", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/phone")

      assert html =~ ~s(data-phone-tab="messages")
      refute html =~ ~s(data-phone-tab="contacts")
    end

    test "the rail marks exactly one tab selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/phone")

      assert has_element?(view, "button[phx-value-tab=messages][aria-selected=true]")
      assert has_element?(view, "button[phx-value-tab=contacts][aria-selected=false]")

      select_tab(view, "contacts")

      assert has_element?(view, "button[phx-value-tab=messages][aria-selected=false]")
      assert has_element?(view, "button[phx-value-tab=contacts][aria-selected=true]")
    end

    test "each tab shows its own panel and hides the other's", %{conn: conn} do
      {:ok, _} = Contacts.create_contact(%{name: "Dana Printshop", phone: "+15035550142"})
      {:ok, view, html} = live(conn, "/phone")

      # Messages: the log and the keypad, no contact list.
      assert html =~ "Message machine"
      refute has_element?(view, "button[phx-click=toggle_add_contact]")

      contacts = render(select_tab(view, "contacts"))

      assert contacts =~ "Dana Printshop"
      assert has_element?(view, "button[phx-click=toggle_add_contact]")
      refute has_element?(view, "#phone-dial-key-5")
    end
  end

  describe "contact faces" do
    test "a face picked from the Pocket is served from the Pocket URL", %{conn: conn} do
      {:ok, contact} =
        Contacts.create_contact(%{name: "Dana Printshop", phone: "+15035550142"})

      Faces.ensure()

      File.write!(
        Path.join(
          Pockets.pocket_dir(Faces.pocket_name()),
          "ember.wgsl"
        ),
        "@fragment fn fs_main() -> @location(0) vec4<f32> { return vec4<f32>(1.0); }"
      )

      {:ok, _} = Contacts.update_contact(contact, %{face_shader: "ember"})

      {:ok, view, _html} = live(conn, "/phone")
      html = render(select_tab(view, "contacts"))
      assert html =~ "Dana Printshop"

      card =
        view
        |> element("button[phx-click=select_contact][phx-value-id='#{contact.id}']")
        |> render_click()

      assert card =~ "/pockets/contact-faces/ember.wgsl"
    end

    test "the Pocket's wgsl is served as text/plain with nosniff", %{conn: conn} do
      Faces.ensure()

      File.write!(
        Path.join(
          Pockets.pocket_dir(Faces.pocket_name()),
          "ember.wgsl"
        ),
        "@fragment fn fs_main() -> @location(0) vec4<f32> { return vec4<f32>(1.0); }"
      )

      conn = get(conn, "/pockets/contact-faces/ember.wgsl")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
      # `text/plain` is only safe BECAUSE of this header — without it a browser
      # is free to sniff operator-supplied bytes into a document.
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "a contact with no face still gets one", %{conn: conn} do
      {:ok, contact} =
        Contacts.create_contact(%{name: "Dana Printshop", phone: "+15035550142"})

      {:ok, view, _html} = live(conn, "/phone")
      select_tab(view, "contacts")

      card =
        view
        |> element("button[phx-click=select_contact][phx-value-id='#{contact.id}']")
        |> render_click()

      # The generative fallback: a canvas, a seed, and NO source URL to fetch.
      assert card =~ "data-face-canvas"
      assert card =~ "data-seed"
      refute card =~ "data-shader-source"
      assert card =~ "Generative"
    end
  end

  # OUTBOUND_VOICE Phase 4. What these can prove without a network is more than it
  # looks: every refusal below is raised by `Telephony`/`Twilio`, not by the
  # component, so a passing refusal is itself proof that the button is wired to
  # the real path. The accepted case belongs to `telephony/call_test.exs`, which
  # can stub Twilio; here it would place an actual call.
  describe "the Call button" do
    setup :enable_voice

    test "is live once the switch is on, and says what pressing it does", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/phone")
      dial(view, "5035550142")

      assert has_element?(view, "#phone-dial-call:not([disabled])")
      assert has_element?(view, "#phone-keypad-purpose", "Call rings your phone first")
      refute has_element?(view, "#phone-keypad-purpose", "calling off")
    end

    test "confirms before the first ring, naming all three surprising facts",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/phone")
      dial(view, "5035550142")

      confirm = view |> element("#phone-dial-call") |> render_click()

      # Who is dialled, that YOUR phone rings first, and what they will see.
      assert confirm =~ "(503) 555-0142"
      assert confirm =~ "Your own phone rings first"
      assert confirm =~ "(844) 555-0100"

      # And nothing has happened yet.
      assert Telephony.list_events() == []

      view |> element("#phone-call-cancel") |> render_click()
      refute has_element?(view, "#phone-call-confirm")
    end

    test "editing the number abandons the pending call", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/phone")
      dial(view, "5035550142")
      view |> element("#phone-dial-call") |> render_click()

      assert has_element?(view, "#phone-call-confirm")

      view |> element("#phone-dial-backspace") |> render_click()

      # A confirmation that survives a digit being typed is a confirmation for a
      # number the operator is no longer looking at.
      refute has_element?(view, "#phone-call-confirm")
    end

    test "refuses our own number, in words rather than a tag", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/phone")
      dial(view, "8445550100")

      view |> element("#phone-dial-call") |> render_click()
      html = view |> element("#phone-call-confirm-place") |> render_click()

      assert html =~ "this app&#39;s own number"
      refute has_element?(view, "#phone-call-confirm")
      assert Telephony.list_events() == []
    end

    test "a number that replied STOP cannot be called from the keypad either",
         %{conn: conn} do
      record!(%{
        kind: "sms",
        direction: "inbound",
        from_number: "+15035550142",
        to_number: @ours,
        body: "STOP"
      })

      {:ok, view, _html} = live(conn, "/phone")
      dial(view, "5035550142")

      view |> element("#phone-dial-call") |> render_click()
      html = view |> element("#phone-call-confirm-place") |> render_click()

      # The opt-out list is the SMS one on purpose — voice has no STOP, and it is
      # the same human. A button that ignored it would be the loophole.
      assert html =~ "replied STOP"
    end

    test "a selected contact's Call button dials their stored number", %{conn: conn} do
      {:ok, contact} = Contacts.create_contact(%{name: "Dana Printshop", phone: "+15035550142"})

      {:ok, view, _html} = live(conn, "/phone")
      dial(view, "503")
      view |> element("#phone-dial-match") |> render_click()

      assert has_element?(view, "#phone-contact-call:not([disabled])")
      confirm = view |> element("#phone-contact-call") |> render_click()

      # The stored E.164 number, not the national digits on the display.
      assert confirm =~ "(503) 555-0142"
      assert contact.phone == "+15035550142"
    end
  end
end
