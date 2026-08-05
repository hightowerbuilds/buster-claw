defmodule BusterClaw.WatchlistSweepTest do
  @moduledoc """
  The half of the watchlist that makes it more than a note to self: the daily
  sweep and the deep backfill have to actually read it. Until 08-04 a ticker
  added to a list showed "queued" and stayed there forever.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{MarketData, Trading, Watchlist}

  defp watch(symbols) do
    {:ok, _} = Watchlist.create("Tracked")
    for s <- symbols, do: {:ok, _} = Watchlist.add("Tracked", s)
    :ok
  end

  describe "the daily sweep prompt" do
    # The operator's tracked symbols live in this app, not at the broker, so the
    # agent cannot discover them. Named in the prompt or they do not happen.
    test "names the tracked symbols, because the agent cannot discover them" do
      prompt = Trading.market_data_prompt(~D[2026-08-01], ["NVDA", "SPY"])

      assert prompt =~ "NVDA"
      assert prompt =~ "SPY"
      assert prompt =~ "symbols they track"
    end

    test "is unchanged when nothing is tracked" do
      prompt = Trading.market_data_prompt(~D[2026-08-01], [])

      refute prompt =~ "symbols they track"
      assert prompt =~ "the operator's holdings, in ONE pass"
    end

    # The explicit answer to "whose symbols lose when the cap binds".
    test "states that holdings win the ten-symbol cap" do
      prompt = Trading.market_data_prompt(~D[2026-08-01], ["NVDA"])

      assert prompt =~ "HELD symbols first"
      assert prompt =~ "skipped"
    end
  end

  describe "refresh/1 hands the watchlist to the fetcher" do
    test "the tracked symbols reach the fetch" do
      watch(["NVDA", "AMD"])
      test_pid = self()

      Application.put_env(:buster_claw, :trading_market_data_fetcher, fn _start, watched ->
        send(test_pid, {:watched, watched})
        {:ok, %{closes: %{}, quotes: [], indexes: [], earnings: [], errors: [], skipped: []}}
      end)

      on_exit(fn -> Application.delete_env(:buster_claw, :trading_market_data_fetcher) end)

      MarketData.refresh(~D[2026-08-04])

      assert_receive {:watched, watched}
      assert "NVDA" in watched
      assert "AMD" in watched
    end

    # A stub written before watchlists existed must keep working.
    test "an arity-1 fetcher is still honoured" do
      test_pid = self()

      Application.put_env(:buster_claw, :trading_market_data_fetcher, fn _start ->
        send(test_pid, :called)
        {:ok, %{closes: %{}, quotes: [], indexes: [], earnings: [], errors: [], skipped: []}}
      end)

      on_exit(fn -> Application.delete_env(:buster_claw, :trading_market_data_fetcher) end)

      MarketData.refresh(~D[2026-08-04])
      assert_receive :called
    end
  end

  describe "the deep-backfill queue" do
    test "includes tracked symbols after the benchmarks" do
      watch(["NVDA"])
      queue = MarketData.symbols_needing_backfill()

      assert "NVDA" in queue
      # Benchmarks first: each backfill is one agent run a day, so this order is
      # the order the operator's money is spent, and the baseline wins.
      assert Enum.find_index(queue, &(&1 == "SPY")) <
               Enum.find_index(queue, &(&1 == "NVDA"))
    end

    test "a tracked symbol that already has a year drops out of the queue" do
      watch(["NVDA"])
      seed("NVDA", 245)

      refute "NVDA" in MarketData.symbols_needing_backfill()
    end

    test "a symbol watched twice is queued once" do
      {:ok, _} = Watchlist.create("A")
      {:ok, _} = Watchlist.create("B")
      {:ok, _} = Watchlist.add("A", "NVDA")
      {:ok, _} = Watchlist.add("B", "NVDA")

      queue = MarketData.symbols_needing_backfill()
      assert Enum.count(queue, &(&1 == "NVDA")) == 1
    end

    test "with no watchlist it is exactly the benchmarks" do
      assert MarketData.symbols_needing_backfill() == MarketData.benchmark_symbols()
    end
  end

  defp seed(symbol, count) do
    for i <- 1..count do
      %MarketData.Bar{}
      |> MarketData.Bar.changeset(%{
        symbol: symbol,
        bar_on: Date.add(~D[2025-01-01], i),
        interval: "day",
        close_cents: 10_000 + i
      })
      |> Repo.insert!()
    end
  end
end
