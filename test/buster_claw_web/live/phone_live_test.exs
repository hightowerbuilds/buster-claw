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
    assert Telephony.unheard_count() == 0
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

  test "playback panel rests on a placeholder with nothing selected", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/phone")

    # The retired rotary dial is gone; the resting state prompts a selection.
    assert html =~ "Select a message to play it here"
    refute html =~ "rotary-dial"
    refute html =~ "data-rotor"
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
