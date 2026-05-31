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
          {~p"/mcp", "MCP"},
          {~p"/runtime", "Runtime Control"}
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
          ~p"/mcp",
          ~p"/runtime"
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ ~s(id="advanced-tabs")
      assert html =~ ~s(id="advanced-tab-delivery")
      assert html =~ ~s(id="advanced-tab-hooks")
      assert html =~ ~s(id="advanced-tab-webhooks")
      assert html =~ ~s(id="advanced-tab-integrations")
      assert html =~ ~s(id="advanced-tab-mcp")
      assert html =~ ~s(id="advanced-tab-runtime")
    end
  end

  test "library surfaces render the shared section tabs", %{conn: conn} do
    for path <- [~p"/documents", ~p"/sources", ~p"/analysis"] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ ~s(id="library-tabs")
      assert html =~ ~s(id="library-tab-documents")
      assert html =~ ~s(id="library-tab-sources")
      assert html =~ ~s(id="library-tab-analysis")
    end
  end

  test "library surfaces are reached via the library tab row, not the dock", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ ~s(href="/sources")
    refute html =~ ~s(href="/analysis")
    # Documents/Library is no longer in the dock; Workspace took its place.
    refute html =~ ~s(href="/documents")
    assert html =~ ~s(href="/workspace")
  end
end
