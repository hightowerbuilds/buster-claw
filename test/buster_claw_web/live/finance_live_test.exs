defmodule BusterClawWeb.FinanceLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the dashboard with the lookup form and the not-advice disclaimer", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/finance")

    assert html =~ "Financial Advisor"
    assert html =~ "Not financial advice."
    assert html =~ ~s(phx-submit="lookup")
    assert html =~ ~s(name="symbol")
    # Before any lookup, the empty prompt is shown (no cards).
    assert html =~ "Enter a ticker symbol"
    refute html =~ ~s(<h2 class="font-display text-xl font-black uppercase tracking-tight">Quote)
  end
end
