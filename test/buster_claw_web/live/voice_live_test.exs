defmodule BusterClawWeb.VoiceLiveTest do
  use BusterClawWeb.ConnCase, async: true

  # Voice is now a static settings page explaining spoken replies (TTS via the
  # native macOS synthesizer). The microphone/STT feature was demolished 06-28;
  # there is no mic test, device picker, or voice_error handler anymore.
  test "renders the Voice settings page describing spoken replies", %{conn: conn} do
    conn = get(conn, ~p"/voice")
    response = html_response(conn, 200)

    # Lives in the Settings sub-tab system, with Voice active.
    assert response =~ ~s(id="settings-tabs")
    assert response =~ ~s(id="settings-tab-voice")

    # Text-to-speech explainer content.
    assert response =~ "Spoken replies"
    assert response =~ "speech"
    assert response =~ "Voice on / off"

    # No STT remnants: the mic test, device picker, and Mic hook are gone.
    refute response =~ ~s(id="voice-test-mic")
    refute response =~ ~s(phx-hook="Mic")
    refute response =~ ~s(id="voice-devices")
    refute response =~ "Test your microphone"
  end
end
