defmodule BusterClawWeb.PhoneLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Contacts
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

  # The keypad looks like a dialer and isn't one. That was disclosed only in the
  # container's aria-label, so a sighted user had no way to know — the exact
  # "decorative control that reads as finished" case LAUNCH_ROADMAP G-37 names.
  # Gating it behind Labs was declined, so honest labelling in place is the
  # standing obligation and this test is what keeps it.
  test "the keypad says on screen that it only searches contacts", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/phone")

    assert has_element?(view, "#phone-keypad-purpose", "Searches your contacts")
    assert has_element?(view, "#phone-keypad-purpose", "outbound calling isn't built")

    # Not just the accessible name: the disclosure has to survive as visible text.
    refute view |> element("#phone-keypad-purpose") |> render() =~ "sr-only"
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

      BusterClaw.Pockets.Faces.ensure()

      File.write!(
        Path.join(
          BusterClaw.Pockets.pocket_dir(BusterClaw.Pockets.Faces.pocket_name()),
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
      BusterClaw.Pockets.Faces.ensure()

      File.write!(
        Path.join(
          BusterClaw.Pockets.pocket_dir(BusterClaw.Pockets.Faces.pocket_name()),
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
end
