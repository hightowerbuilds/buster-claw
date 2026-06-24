defmodule BusterClawWeb.VoiceLiveTest do
  use BusterClawWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the Voice settings page with a mic test", %{conn: conn} do
    conn = get(conn, ~p"/voice")
    response = html_response(conn, 200)

    # Lives in the Settings sub-tab system, with Voice active.
    assert response =~ ~s(id="settings-tabs")
    assert response =~ ~s(id="settings-tab-voice")

    # The mic test reuses the reusable Mic hook + listening overlay.
    assert response =~ ~s(id="voice-test-mic")
    assert response =~ ~s(phx-hook="Mic")
    assert response =~ ~s(data-voice-test-input)
    assert response =~ "ic-voice-bars"
    assert response =~ "Test your microphone"

    # Device picker: populated client-side by the VoiceDevices hook.
    assert response =~ ~s(id="voice-devices")
    assert response =~ ~s(phx-hook="VoiceDevices")
    assert response =~ ~s(data-voice-device-select)
    assert response =~ ~s(data-voice-device-refresh)
  end

  test "a client voice_error surfaces as a flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/voice")

    html = render_hook(view, "voice_error", %{"message" => "Microphone access denied — enable it."})
    assert html =~ "Microphone access denied — enable it."
  end
end
