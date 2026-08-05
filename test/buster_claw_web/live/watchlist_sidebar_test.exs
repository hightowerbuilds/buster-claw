defmodule BusterClawWeb.WatchlistSidebarTest do
  @moduledoc """
  The left rail. Its job is not "show a list" — it is to answer, beside every
  symbol, the question that cost an afternoon on 08-04: why is this chart short?
  """
  # async: false — writes the shared `watchlists` Settings row.
  use BusterClawWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias BusterClaw.Watchlist

  # Open by default: the rail carries the Chart Build symbol lookup, and a search
  # box nobody can see is not a search box.
  test "starts open, and the bumper collapses it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/trading")
    assert render(view) =~ "Watchlists"

    render_click(view, "watchlist_toggle", %{})
    refute render(view) =~ "Watchlists"

    render_click(view, "watchlist_toggle", %{})
    assert render(view) =~ "Watchlists"
  end

  test "creates a list, adds a ticker, and removes it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/trading")
    render_submit(view, "watchlist_create", %{"name" => "Semis"})
    assert Watchlist.names() == ["Semis"]

    render_submit(view, "watchlist_add", %{"name" => "Semis", "symbol" => "nvda"})
    assert Watchlist.list("Semis") == ["NVDA"]
    assert render(view) =~ "NVDA"

    render_click(view, "watchlist_remove", %{"name" => "Semis", "symbol" => "NVDA"})
    assert Watchlist.list("Semis") == []
  end

  test "a bad ticker flashes instead of storing junk", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/trading")
    render_submit(view, "watchlist_create", %{"name" => "Semis"})

    html = render_submit(view, "watchlist_add", %{"name" => "Semis", "symbol" => "not a ticker"})

    assert html =~ "does not look like a ticker"
    assert Watchlist.list("Semis") == []
  end

  # The whole point of the rail: "6 bars" and "the fetch failed" must not look
  # the same, and "nothing has happened yet" is a third thing again.
  test "each symbol shows why its history is as short as it is", %{conn: conn} do
    {:ok, _} = Watchlist.create("Mixed")
    {:ok, _} = Watchlist.add("Mixed", "SPY")
    {:ok, _} = Watchlist.add("Mixed", "HOOD")
    {:ok, _} = Watchlist.add("Mixed", "QQQ")
    {:ok, _} = Watchlist.add("Mixed", "NVDA")

    seed_bars("SPY", 245)
    seed_bars("HOOD", 6)
    :ok = BusterClaw.MarketData.record_backfill_outcome("QQQ", {:error, :boom}, ~D[2026-08-04])

    {:ok, view, _html} = live(conn, ~p"/trading")
    html = render(view)

    assert html =~ "year"
    assert html =~ "6 bars"
    assert html =~ "failed"
    assert html =~ "queued"
  end

  test "deleting a list stops the watching and keeps the bars", %{conn: conn} do
    {:ok, _} = Watchlist.create("Semis")
    {:ok, _} = Watchlist.add("Semis", "HOOD")
    seed_bars("HOOD", 6)

    {:ok, view, _html} = live(conn, ~p"/trading")
    render_click(view, "watchlist_delete", %{"name" => "Semis"})

    assert Watchlist.names() == []
    assert length(BusterClaw.MarketData.bars("HOOD")) == 6
  end

  defp seed_bars(symbol, count) do
    for i <- 1..count do
      %BusterClaw.MarketData.Bar{}
      |> BusterClaw.MarketData.Bar.changeset(%{
        symbol: symbol,
        bar_on: Date.add(~D[2025-08-04], i),
        interval: "day",
        close_cents: 10_000 + i
      })
      |> BusterClaw.Repo.insert!()
    end
  end

  # The operator's actual ask: ticker things in one rail — search a symbol, and
  # the lists you keep. NOT the Robinhood account UI, which still owns the tab.
  describe "the symbol lookup shares the rail" do
    test "Chart Build renders the lookup inside the rail, not in a side column",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/trading")
      render_click(view, "trading_new_tab_menu", %{})
      render_click(view, "trading_new_tab", %{"kind" => "chartbuild"})

      html = render(view)
      assert html =~ "Public data only"
      assert html =~ "Watchlists"
    end

    test "collapsing the rail takes the lookup with it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/trading")
      render_click(view, "trading_new_tab_menu", %{})
      render_click(view, "trading_new_tab", %{"kind" => "chartbuild"})
      assert render(view) =~ "Public data only"

      render_click(view, "watchlist_toggle", %{})
      refute render(view) =~ "Public data only"
    end

    # The account UI is emphatically NOT in the rail — that was a misread on
    # 08-04, moved and reverted the same evening.
    test "the Robinhood account card still owns the tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/trading")
      assert has_element?(view, "#trading-account-card")

      render_click(view, "watchlist_toggle", %{})

      assert has_element?(view, "#trading-account-card"),
             "collapsing the rail must not hide the account UI"
    end
  end
end
