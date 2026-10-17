defmodule BusterClawWeb.LegacySettingsControllerTest do
  use BusterClawWeb.ConnCase, async: true

  test "a saved command-list URL recovers to Settings", %{conn: conn} do
    conn = get(conn, "/cmd-list?tab=commands")
    assert redirected_to(conn) == ~p"/appearance"
  end

  # The tab strip reopens the last Settings subpage at boot; Integrations was
  # deleted 10-17 and a remembered tab hit "no route found" the same morning.
  test "a remembered Integrations tab recovers to Settings", %{conn: conn} do
    conn = get(conn, "/integrations")
    assert redirected_to(conn) == ~p"/appearance"
  end
end
