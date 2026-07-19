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

    assert has_element?(view, "#phone-contact-history:not([open])")
    assert has_element?(view, "#phone-contact-history-toggle", "Caller history")
    assert has_element?(view, "#phone-contact-history-items", "Voicemail")
  end

  test "contacts: add via form, select shows the shaderface card", %{conn: conn} do
    {:ok, view, html} = live(conn, "/phone")

    assert html =~ "No contacts yet"

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
end
