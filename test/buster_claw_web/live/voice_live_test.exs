defmodule BusterClawWeb.VoiceLiveTest do
  use BusterClawWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # The prose half of the Voice page: the explainer and the voice picker's
  # markup, both of which are the same on every machine. The engine panel is not
  # tested here — it reports on a binary that may or may not be installed, so it
  # needs application env under control and lives in `voice_live_engine_test.exs`
  # with `async: false`.
  #
  # The microphone/STT feature was demolished 06-28; there is no mic test, device
  # picker, or voice_error handler anymore. (Speech *input* is a separate
  # question — see the Voice roadmap — and is not this page.)
  test "renders the Vox surface describing spoken replies, with no settings rail", %{conn: conn} do
    # A LIVE mount rather than a static `get`, because Vox2B became a sidebar on
    # 09-05: one tab renders at a time, so the assertions below have to open the
    # ones they are about. The static render still proves the rail's absence, but
    # it can no longer prove the presence of anything behind a tab.
    {:ok, view, response} = live(conn, ~p"/voice")

    # It LEFT the Settings sub-tab system on 09-05 — the surface is the homepage's
    # Vox2B sub-tab now, and this route is a deep-link/split-pane door onto the
    # same component. Asserted as an absence rather than deleted: a settings rail
    # reappearing here would highlight nothing (Voice is not one of its tabs) and
    # claim membership of a section this page no longer belongs to.
    refute response =~ ~s(id="settings-tabs")
    refute response =~ ~s(id="settings-tab-voice")

    # Text-to-speech explainer content — the `say(1)` half, which is its own tab
    # because it is a different engine from everything else here.
    reading = open_tab(view, "reading")
    assert reading =~ "Spoken replies"
    assert reading =~ "speech"
    assert reading =~ "Voice on / off"

    # The sixteen chime rows are REAL inputs, not `<template>` contents. Written
    # after the 09-05 restyle put them in a CSS grid and reached for `<template>`
    # as the `:for` wrapper: template contents are inert, so the rows rendered
    # invisible and the inputs never submitted — and every string assertion in
    # this file still passed, because the markup was in the HTML either way.
    alerts = open_tab(view, "alerts")
    assert alerts =~ ~s(name="lines[timer]")

    refute alerts =~ "<template",
           "a <template> in this surface makes its contents inert — invisible " <>
             "controls that never submit, with the markup still present in the HTML"

    # No STT remnants: the mic test, device picker, and Mic hook are gone.
    refute response =~ ~s(id="voice-test-mic")
    refute response =~ ~s(phx-hook="Mic")
    refute response =~ ~s(id="voice-devices")
    refute response =~ "Test your microphone"
  end

  defp open_tab(view, tab) do
    view |> element("button[phx-value-tab='#{tab}']") |> render_click()
  end
end
