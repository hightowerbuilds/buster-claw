defmodule BusterClawWeb.LegacySettingsControllerTest do
  use BusterClawWeb.ConnCase, async: true

  test "a saved command-list URL recovers to Settings", %{conn: conn} do
    conn = get(conn, "/cmd-list?tab=commands")
    assert redirected_to(conn) == ~p"/appearance"
  end
end
