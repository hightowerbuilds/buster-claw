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

  # Every id and every `phx-click` that BusterPhone deleted when it became
  # intake-only (`PHONE_INTAKE_ROADMAP`, 08-18). Named once, asserted absent from
  # both sub-tabs below, so a control that originates something cannot grow back
  # onto this surface without turning a test red. Deleting the assertions that
  # used to press these buttons is only half the job — the other half is this.
  # Every one of these was read out of the deleted markup at `HEAD~`, not guessed:
  # an absence-assertion over a name that never existed is scenery that reads like
  # a guard.
  @gone_ids ~w(phone-keypad-controls phone-keypad-purpose
               phone-dial-key-0 phone-dial-key-1 phone-dial-key-5
               phone-dial-key-star phone-dial-key-hash
               phone-dial-backspace phone-dial-clear phone-dial-call
               phone-dial-match phone-dial-no-match phone-dialed-number
               phone-call-action phone-call-confirm phone-call-confirm-place
               phone-call-cancel phone-call-error phone-call-notice
               phone-contact-actions phone-contact-call phone-contact-text)

  # The six `handle_event/3` clauses `phone_component.ex` lost. `select_contact`
  # is deliberately NOT here — the dial-match button used it too, but the contact
  # list still does, and it originates nothing.
  @gone_events ~w(dial_key dial_backspace dial_clear
                  call_prompt call_confirm call_cancel)

  defp refute_outbound_surface(view, html) do
    for id <- @gone_ids do
      refute has_element?(view, "##{id}"),
             "##{id} is back — BusterPhone is intake-only and originates nothing"
    end

    for event <- @gone_events do
      refute html =~ ~s(phx-click="#{event}"),
             "#{event} is back on the phone surface — BusterPhone originates nothing"
    end

    # The keypad's DTMF hook played a tone per press. Nothing else uses it, so its
    # presence anywhere on this surface means keys came back.
    refute html =~ ~s(phx-hook="Dtmf")
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

  # The Playback panel still sits on the `keypad` WGSL shader — the shader is the
  # backdrop and the two ids below name the shader region, not a control. What is
  # gone is everything that was pressable on it.
  test "playback rests on the keypad shader, and nothing on it originates", %{conn: conn} do
    {:ok, view, html} = live(conn, "/phone")

    assert has_element?(view, "#phone-keypad-stage")
    assert has_element?(view, "#phone-keypad-playback[data-shader=keypad]")
    refute has_element?(view, "#phone-message-detail")

    # The idle stage is not blank: the keypad left and the panel had to say what
    # it is waiting for. A shader with no words on it is the decorative state
    # LAUNCH_ROADMAP G-37 refused.
    assert has_element?(view, "#phone-playback-idle", "Pick a voicemail or a thread")

    refute_outbound_surface(view, html)
  end

  # This replaces two tests that pressed the keypad's Call button and read the
  # disclosure line beside it. Both were the G-37 obligation in its 08-15 shape:
  # a control that could originate had to say on screen why it would refuse.
  # Deleting the control retires the obligation, so what is asserted now is the
  # inverse — the surface has nothing to disclose *about*, on either sub-tab, and
  # the disclosures it used to carry are gone rather than stranded.
  test "neither sub-tab carries a control that sends or dials", %{conn: conn} do
    {:ok, _contact} = Contacts.create_contact(%{name: "Dana Printshop", phone: "+15035550142"})
    {:ok, view, html} = live(conn, "/phone")

    refute_outbound_surface(view, html)

    # The two disclosures the deleted buttons carried, both of which lived on the
    # Messages tab. Each was true of a control that no longer exists, and a stale
    # disclosure is worse than none — it explains a limit on something a reader
    # cannot find, which is how a page teaches that the feature is merely off.
    refute html =~ "BUSTER_CLAW_VOICE_ENABLED"
    refute html =~ "outbound calling isn&#39;t built"

    contacts = render(select_tab(view, "contacts"))
    assert contacts =~ "Dana Printshop"
    refute_outbound_surface(view, contacts)
  end

  test "caller history hangs off the selected contact, collapsed", %{conn: conn} do
    {:ok, contact} =
      Contacts.create_contact(%{name: "Dana Printshop", phone: "+15035550142"})

    record!(%{
      from_number: contact.phone,
      transcript: "Call me after lunch.",
      recording_path: "raw/2026-07-11/voicemail-dana.m4a"
    })

    {:ok, view, _html} = live(conn, "/phone")

    # Selection is the contact list now. It used to be reachable from the keypad
    # too — dial three digits, get a match, press it — and that second route left
    # with the keypad, so this is the only one.
    select_tab(view, "contacts")

    card =
      view
      |> element("button[phx-click=select_contact][phx-value-id='#{contact.id}']")
      |> render_click()

    assert card =~ "(503) 555-0142"

    assert has_element?(view, "#phone-contact-history:not([open])")
    assert has_element?(view, "#phone-contact-history-toggle", "Caller history")
    assert has_element?(view, "#phone-contact-history-items", "Voicemail")

    # A selected contact used to grow a Text and a Call button here. Selecting one
    # is now purely a read: a face, a number, the trust switch, and this history.
    refute_outbound_surface(view, card)
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

      # Messages: the log and the Playback panel, no contact list.
      assert html =~ "Message machine"
      assert has_element?(view, "#phone-keypad-stage")
      refute has_element?(view, "button[phx-click=toggle_add_contact]")

      contacts = render(select_tab(view, "contacts"))

      assert contacts =~ "Dana Printshop"
      assert has_element?(view, "button[phx-click=toggle_add_contact]")
      # Contacts gets the whole panel, so Playback's shader stage is torn down
      # rather than animating unseen. This used to assert on a dial key; the key
      # is gone, and a refute on a deleted id proves nothing about the switch.
      refute has_element?(view, "#phone-keypad-stage")
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

  # This replaces the six-test "the Call button" block that `OUTBOUND_VOICE`
  # Phase 4 added. Every one of those tests turned the voice switch ON before
  # mount and then asserted the keypad came alive — a Call button, a confirm
  # step, a self-dial refusal, a STOP refusal.
  #
  # The claim they collectively guarded was "the switch is what decides". The
  # claim that replaced it is `PHONE_INTAKE_ROADMAP`'s central one — **deleted,
  # not disabled** — and the only honest way to test that is to flip the same
  # switch on and prove it buys nothing. A surface that came back when the
  # config said so would mean the deletion was really a default.
  describe "with every telephony switch turned on" do
    setup do
      previous = Application.get_env(:buster_claw, :twilio)

      # Deliberately includes the two kill switches this roadmap deleted. They
      # are inert keys now; the point is that setting them is inert too.
      Application.put_env(:buster_claw, :twilio, %{
        account_sid: "AC_test",
        auth_token: "tok",
        phone_number: "+18445550100",
        operator_number: "+15033412655",
        voice_enabled: true,
        sms_enabled: true,
        messaging_service_sid: "MG_test"
      })

      on_exit(fn -> Application.put_env(:buster_claw, :twilio, previous) end)
    end

    test "the phone tab still originates nothing", %{conn: conn} do
      {:ok, _contact} = Contacts.create_contact(%{name: "Dana Printshop", phone: "+15035550142"})
      {:ok, view, html} = live(conn, "/phone")

      # Configured, credentialed, both switches on — and the surface is the same
      # intake surface it is with nothing set.
      assert has_element?(view, "#phone-keypad-stage")
      assert has_element?(view, "#phone-playback-idle")
      refute_outbound_surface(view, html)

      contacts = render(select_tab(view, "contacts"))
      assert contacts =~ "Dana Printshop"
      refute_outbound_surface(view, contacts)
    end

    test "and no ledger row appears from merely looking at it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/phone")

      select_tab(view, "contacts")
      select_tab(view, "messages")

      # The old block leaned on this too, as its proof that a confirm step had
      # not yet placed anything. Here it is the whole assertion: there is no path
      # through this tab that writes an outbound row, switches or no switches.
      assert Telephony.list_events() == []
    end
  end
end
