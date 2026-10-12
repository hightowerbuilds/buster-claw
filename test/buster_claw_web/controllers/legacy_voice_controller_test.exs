defmodule BusterClawWeb.LegacyVoiceControllerTest do
  use BusterClawWeb.ConnCase, async: true

  test "old speech bookmarks open the surviving native speech preferences", %{conn: conn} do
    assert conn |> get("/voice?tab=reading") |> redirected_to() == ~p"/settings?tab=speech"
  end

  test "removed synthesis media has no route", %{conn: conn} do
    assert get(conn, "/voice-audio/old-clip.wav").status == 404
  end
end
