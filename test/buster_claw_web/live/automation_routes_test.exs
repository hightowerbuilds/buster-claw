defmodule BusterClawWeb.AutomationRoutesTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders routed automation surfaces", %{conn: conn} do
    for {path, text} <- [
          {~p"/analysis", "Analysis"},
          {~p"/calendar", "Calendar"},
          {~p"/gws", "GWS"},
          {~p"/memory", "Memory"},
          {~p"/scheduler", "Scheduler"},
          {~p"/integrations", "Integrations"},
          {~p"/advanced", "Delivery"},
          {~p"/webhooks", "Webhooks"},
          {~p"/hooks", "Hooks"},
          {~p"/delivery", "Delivery"},
          {~p"/mcp", "MCP"}
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ text
    end
  end

  test "advanced surfaces render the shared section tabs", %{conn: conn} do
    for path <- [
          ~p"/advanced",
          ~p"/delivery",
          ~p"/hooks",
          ~p"/webhooks",
          ~p"/integrations",
          ~p"/mcp"
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ ~s(id="advanced-tabs")
      assert html =~ ~s(id="advanced-tab-delivery")
      assert html =~ ~s(id="advanced-tab-hooks")
      assert html =~ ~s(id="advanced-tab-webhooks")
      assert html =~ ~s(id="advanced-tab-integrations")
      assert html =~ ~s(id="advanced-tab-mcp")
    end
  end
end
