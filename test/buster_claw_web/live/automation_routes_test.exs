defmodule BusterClawWeb.AutomationRoutesTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders routed automation surfaces", %{conn: conn} do
    for {path, text} <- [
          {~p"/analysis", "Analysis"},
          {~p"/calendar", "Calendar"},
          {~p"/memory", "Memory"},
          {~p"/scheduler", "Scheduler"},
          {~p"/webhooks", "Webhooks"},
          {~p"/hooks", "Hooks"},
          {~p"/delivery", "Delivery"},
          {~p"/mcp", "MCP"}
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ text
    end
  end
end
