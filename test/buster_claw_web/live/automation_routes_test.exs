defmodule BusterClawWeb.AutomationRoutesTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders routed automation surfaces", %{conn: conn} do
    for {path, text} <- [
          {~p"/calendar", "Calendar"},
          {~p"/gws", "GWS"},
          {~p"/memory", "Memory"},
          {~p"/scheduler", "Scheduler"},
          {~p"/integrations", "Integrations"},
          {~p"/advanced", "Delivery"},
          {~p"/webhooks", "Webhooks"},
          {~p"/hooks", "Hooks"},
          {~p"/delivery", "Delivery"}
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
          ~p"/integrations"
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ ~s(id="advanced-tabs")
      assert html =~ ~s(id="advanced-tab-delivery")
      assert html =~ ~s(id="advanced-tab-hooks")
      assert html =~ ~s(id="advanced-tab-webhooks")
      assert html =~ ~s(id="advanced-tab-integrations")
    end
  end

  test "cut surfaces are no longer in the dock", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ ~s(href="/sources")
    refute html =~ ~s(href="/analysis")
    refute html =~ ~s(href="/documents")
    refute html =~ ~s(href="/chat")
    assert html =~ ~s(href="/workspace")
  end
end
