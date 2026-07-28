defmodule BusterClaw.MarketDataTest do
  # async: false — stubs the market-data fetcher seam in the global app env.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.MarketData
  alias BusterClaw.MarketData.Bar

  setup do
    prev = Application.get_env(:buster_claw, :trading_market_data_fetcher)
    on_exit(fn -> Application.put_env(:buster_claw, :trading_market_data_fetcher, prev) end)
    :ok
  end

  defp d(iso), do: Date.from_iso8601!(iso)

  defp closes(map) do
    Map.new(map, fn {symbol, pairs} ->
      {symbol, Enum.map(pairs, fn {day, close} -> %{bar_on: d(day), close: close} end)}
    end)
  end

  defp parsed(closes_map, extra \\ %{}) do
    Map.merge(
      %{closes: closes(closes_map), quotes: [], indexes: [], skipped: [], errors: []},
      extra
    )
  end

  describe "store_bars/1" do
    test "writes cents, and a second identical store adds no rows" do
      {2, ["GOOGL"]} =
        MarketData.store_bars(
          closes(%{"GOOGL" => [{"2026-07-24", 347.52}, {"2026-07-27", 349.0}]})
        )

      assert [a, b] = MarketData.bars("GOOGL")
      assert a.close_cents == 34_752
      assert b.close_cents == 34_900

      # The done-when: a re-run the same day writes nothing new.
      {2, _} =
        MarketData.store_bars(
          closes(%{"GOOGL" => [{"2026-07-24", 347.52}, {"2026-07-27", 349.0}]})
        )

      assert length(MarketData.bars("GOOGL")) == 2
    end

    test "a closes re-write never nulls chart-tier OHLC on the same row" do
      # Phase 4 will fill OHLC onto a row the closes tier owns. Tonight's sweep
      # must not erase it.
      %Bar{}
      |> Bar.changeset(%{
        symbol: "GOOGL",
        bar_on: d("2026-07-24"),
        close_cents: 34_752,
        open_cents: 34_000,
        high_cents: 35_000,
        low_cents: 33_900,
        volume: 1_000_000
      })
      |> Repo.insert!()

      MarketData.store_bars(closes(%{"GOOGL" => [{"2026-07-24", 347.60}]}))

      assert [bar] = MarketData.bars("GOOGL")
      assert bar.close_cents == 34_760
      assert bar.open_cents == 34_000
      assert bar.volume == 1_000_000
    end

    test "a non-positive close is refused, and costs only its own row" do
      {1, ["QXO"]} =
        MarketData.store_bars(closes(%{"QXO" => [{"2026-07-24", 0.0}, {"2026-07-25", 14.26}]}))

      assert [only] = MarketData.bars("QXO")
      assert only.close_cents == 1_426
    end
  end

  describe "bars/2 and freshness" do
    test "the trailing window returns the newest N, oldest first" do
      MarketData.store_bars(
        closes(%{"GOOGL" => [{"2026-07-23", 1.0}, {"2026-07-24", 2.0}, {"2026-07-27", 3.0}]})
      )

      assert [a, b] = MarketData.bars("GOOGL", 2)
      assert a.bar_on == d("2026-07-24")
      assert b.bar_on == d("2026-07-27")
    end

    test "fresh? means a close exists for the most recent trading day" do
      refute MarketData.fresh?(d("2026-07-28"))

      # Tuesday the 28th is itself a trading day, so freshness on Tuesday means
      # Tuesday's own close — a Monday close does not satisfy it.
      MarketData.store_bars(closes(%{"GOOGL" => [{"2026-07-27", 1.0}]}))
      assert MarketData.fresh?(d("2026-07-27"))
      refute MarketData.fresh?(d("2026-07-28"))

      # A Saturday asks for Friday's close.
      MarketData.store_bars(closes(%{"GOOGL" => [{"2026-07-24", 1.0}]}))
      assert MarketData.fresh?(d("2026-07-25"))
    end

    test "refresh_start reaches back ~90 days empty, else overlaps the newest bar" do
      assert MarketData.refresh_start(d("2026-07-28")) == d("2026-04-29")

      MarketData.store_bars(closes(%{"GOOGL" => [{"2026-07-24", 1.0}]}))
      assert MarketData.refresh_start(d("2026-07-28")) == d("2026-07-19")
    end
  end

  describe "refresh/1" do
    test "stores bars and the quotes blob from one sweep" do
      Application.put_env(:buster_claw, :trading_market_data_fetcher, fn _start ->
        {:ok,
         parsed(%{"GOOGL" => [{"2026-07-24", 347.52}], "QXO" => [{"2026-07-24", 14.26}]}, %{
           quotes: [%{"symbol" => "GOOGL", "name" => nil, "price" => 349.1, "change_pct" => 0.4}],
           indexes: [
             %{"symbol" => "SPX", "name" => "S&P 500", "price" => 6100.0, "change_pct" => -0.2}
           ]
         })}
      end)

      assert {:ok, %{bars: 2, symbols: ["GOOGL", "QXO"]}} = MarketData.refresh(d("2026-07-28"))

      assert MarketData.known_symbols() == ["GOOGL", "QXO"]
      assert {:ok, blob} = MarketData.cached_quotes()
      assert [%{"symbol" => "SPX", "price" => 6100.0}] = blob["indexes"]
      assert {:ok, _at, _} = DateTime.from_iso8601(blob["fetched_at"])
    end

    test "latches the attempt even when the fetch fails" do
      Application.put_env(:buster_claw, :trading_market_data_fetcher, fn _start ->
        {:error, {:robinhood, "down"}}
      end)

      refute MarketData.attempted_on?(d("2026-07-28"))
      assert {:error, _} = MarketData.refresh(d("2026-07-28"))

      # The latch is per-attempt, not per-success: the Recorder re-ticks every
      # ~30 minutes, and without this a failing sweep would re-spend a real
      # agent run on every tick until midnight.
      assert MarketData.attempted_on?(d("2026-07-28"))
      assert MarketData.known_symbols() == []
    end

    test "a failed section costs its section, not the sweep" do
      Application.put_env(:buster_claw, :trading_market_data_fetcher, fn _start ->
        {:ok, parsed(%{"GOOGL" => [{"2026-07-24", 347.52}]}, %{errors: ["index quotes failed"]})}
      end)

      assert {:ok, %{bars: 1}} = MarketData.refresh(d("2026-07-28"))
      assert MarketData.known_symbols() == ["GOOGL"]
    end
  end

  describe "index_summary/0" do
    defp store_indexes(indexes) do
      MarketData.store_quotes(%{quotes: [], indexes: indexes})
    end

    test ":none without a blob or without indexes" do
      assert MarketData.index_summary() == :none
      store_indexes([])
      assert MarketData.index_summary() == :none
    end

    test "a given change_pct is passed through untouched" do
      store_indexes([
        %{
          "symbol" => "SPX",
          "name" => "S&P 500",
          "price" => 7413.18,
          "prev_close" => nil,
          "change_pct" => 0.5
        }
      ])

      assert {:ok, %{indexes: [chip], stale?: false}} = MarketData.index_summary()
      assert chip.label == "S&P 500"
      assert chip.change_pct == 0.5
    end

    test "absent change_pct is OUR division over price and prev_close" do
      # The 07-28 live sweep: the index tool hands over no change_pct. Two
      # tool-sourced numbers, our arithmetic.
      store_indexes([
        %{
          "symbol" => "SPX",
          "name" => "",
          "price" => 7413.18,
          "prev_close" => 7400.0,
          "change_pct" => nil
        }
      ])

      assert {:ok, %{indexes: [chip]}} = MarketData.index_summary()
      # Empty name falls back to the symbol.
      assert chip.label == "SPX"
      assert_in_delta chip.change_pct, 0.1781, 0.001
    end

    test "neither given nor derivable is nil — a dash, never a zero" do
      store_indexes([
        %{
          "symbol" => "NDX",
          "name" => nil,
          "price" => 28_039.21,
          "prev_close" => nil,
          "change_pct" => nil
        }
      ])

      assert {:ok, %{indexes: [chip]}} = MarketData.index_summary()
      assert chip.change_pct == nil
    end
  end

  describe "quotes blob" do
    test "round-trips and knows staleness" do
      assert MarketData.cached_quotes() == :none

      MarketData.store_quotes(%{quotes: [], indexes: []})
      assert {:ok, blob} = MarketData.cached_quotes()
      refute MarketData.quotes_stale?(blob)

      old = Map.put(blob, "fetched_at", "2020-01-01T00:00:00Z")
      assert MarketData.quotes_stale?(old)
      assert MarketData.quotes_stale?(%{})
    end
  end
end
