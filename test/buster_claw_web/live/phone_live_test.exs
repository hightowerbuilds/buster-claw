defmodule BusterClawWeb.PhoneLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

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

  test "rotary dial registers digits and hangs up", %{conn: conn} do
    {:ok, view, html} = live(conn, "/phone")

    # The dial is the Playback panel's resting state.
    assert html =~ "rotary-dial"
    assert html =~ "data-rotor"

    for digit <- ~w(5 0 3) do
      view
      |> element("#rotary-dial")
      |> render_hook("dial_digit", %{"digit" => digit})
    end

    assert render(view) =~ "503"

    refute view
           |> element("button[phx-click=dial_clear]")
           |> render_click() =~ "503"
  end

  test "contacts: add via form, select shows the shaderface card", %{conn: conn} do
    {:ok, view, html} = live(conn, "/phone")

    assert html =~ "No contacts yet"

    view |> element("button[phx-click=toggle_add_contact]") |> render_click()

    card =
      view
      |> element("form[phx-submit=add_contact]")
      |> render_submit(%{"name" => "Dana", "number" => "(503) 555-0142"})

    # Saving lands on the face card: ShaderFace mount + normalized number +
    # generative face selected by default.
    assert card =~ "Dana"
    assert card =~ "data-face-canvas"
    assert card =~ "(503) 555-0142"
    assert card =~ "Generative"
  end

  test "contact names replace raw numbers in the log", %{conn: conn} do
    {:ok, _} = Telephony.create_contact(%{name: "Dana Printshop", number: "+15035550142"})

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
