defmodule BusterClawWeb.MCPLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders MCP configuration surface", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/mcp")

    assert html =~ "MCP"
    assert html =~ "No MCP servers configured"
  end

  test "creates an MCP server", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcp")

    html =
      view
      |> form("form", %{
        server: %{
          name: "filesystem",
          command: "npx",
          args: ~s({"items":["-y","server"]}),
          env: "{}",
          enabled: "true"
        }
      })
      |> render_submit()

    assert html =~ "filesystem"
    assert html =~ "npx"
  end
end
