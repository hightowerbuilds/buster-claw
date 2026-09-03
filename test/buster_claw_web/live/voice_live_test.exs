defmodule BusterClawWeb.VoiceLiveTest do
  use BusterClawWeb.ConnCase, async: true

  # The prose half of the Voice page: the explainer and the voice picker's
  # markup, both of which are the same on every machine. The engine panel is not
  # tested here — it reports on a binary that may or may not be installed, so it
  # needs application env under control and lives in `voice_live_engine_test.exs`
  # with `async: false`.
  #
  # The microphone/STT feature was demolished 06-28; there is no mic test, device
  # picker, or voice_error handler anymore. (Speech *input* is a separate
  # question — see the Voice roadmap — and is not this page.)
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
