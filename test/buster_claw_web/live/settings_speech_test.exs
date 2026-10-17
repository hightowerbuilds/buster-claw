defmodule BusterClawWeb.SettingsSpeechTest do
  use BusterClawWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "Speech exposes the native picker and an honest browser fallback", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings?tab=speech")

    assert has_element?(view, "#settings-tab-speech[aria-current='page']")

    assert has_element?(
             view,
             "#settings-speech-picker[phx-hook='VoicePicker'][phx-update='ignore']"
           )

    assert has_element?(view, "#settings-speech-voice[data-voice-select]")
    assert has_element?(view, "#settings-speech-rate[data-voice-rate][min='100'][max='400']")
    assert has_element?(view, "#settings-speech-audition[data-voice-audition]")
    assert has_element?(view, "#settings-speech-reset[data-voice-reset]")
    assert has_element?(view, "#settings-speech-picker [data-voice-unavailable]", "desktop app")
    refute has_element?(view, "[phx-hook='VoiceRecorder']")
  end

  test "the Speech tab opens Speech and stale Home selections recover to Chat", %{conn: conn} do
    {:ok, settings, _html} = live(conn, ~p"/settings")

    {:ok, speech, _html} =
      settings |> element("#settings-tab-speech") |> render_click() |> follow_redirect(conn)

    assert has_element?(speech, "#settings-speech-picker")

    {:ok, home, _html} = live(conn, ~p"/")
    render_click(home, "select_home_tab", %{"tab" => "phone"})
    render_click(home, "select_home_tab", %{"tab" => "vox"})
    assert has_element?(home, "#workbench-pane-chat[data-active='true']")
    refute has_element?(home, "#home-tab-vox")
    refute has_element?(home, "#home-vox")
  end
end
