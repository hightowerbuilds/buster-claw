defmodule BusterClaw.ChartBuilderCoverageTest do
  @moduledoc """
  The snapshot handed to Chart Build truncates each symbol's bars. Until 08-04 it
  said nothing about that, so the model read a 90-bar preview as the whole cache
  and reported it as such — true for a symbol holding 65 bars, FALSE for one
  holding 254, and indistinguishable from the outside.

  That is the bug this covers: not what the model draws, but what it can honestly
  claim about what it was given.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{ChartBuilder, MarketData, Watchlist}

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

  describe "coverage" do
    test "states the real depth beside the truncated preview" do
      seed("DEEP", 254)
      data = ChartBuilder.cached_data()

      cov = data.coverage["DEEP"]
      assert cov.cached_bars == 254
      assert cov.truncated, "254 bars cannot fit a 90-bar preview"
      assert cov.included_bars < cov.cached_bars
      assert cov.first_cached == "2025-01-02"
    end

    test "a symbol that fits is not marked truncated" do
      seed("SMALL", 6)
      cov = ChartBuilder.cached_data().coverage["SMALL"]

      assert cov.cached_bars == 6
      assert cov.included_bars == 6
      refute cov.truncated
    end

    # The distinction the whole feature turns on: "that is all the cache holds"
    # is true of one of these and false of the other, and only coverage says so.
    test "deep and shallow symbols are distinguishable from the snapshot alone" do
      seed("DEEP", 254)
      seed("SMALL", 6)
      cov = ChartBuilder.cached_data().coverage

      assert cov["DEEP"].truncated
      refute cov["SMALL"].truncated
    end
  end

  describe "watchlist in the snapshot" do
    test "a watched symbol with no bars is visible as queued, not missing" do
      {:ok, _} = Watchlist.create("Semis")
      {:ok, _} = Watchlist.add("Semis", "NVDA")

      data = ChartBuilder.cached_data()

      assert "NVDA" in data.watchlist
      # No bars yet, so it is not chartable — but the model can now tell the
      # operator it is queued rather than untracked.
      refute "NVDA" in data.cached_market_symbols
    end

    test "an empty watchlist is an empty list, not absent" do
      assert ChartBuilder.cached_data().watchlist == []
    end
  end

  describe "the prompt" do
    test "names coverage, the datareq escape hatch, and the watchlist gesture" do
      prompt = ChartBuilder.chat_opts() |> Keyword.fetch!(:append_system_prompt)

      assert prompt =~ "CACHED_DATA.coverage"
      assert prompt =~ ~s({"source": "market")
      assert prompt =~ "left rail"
      assert prompt =~ "index each to 100"
    end

    test "the drawable list carries each symbol's depth, not just its name" do
      seed("DEEP", 254)
      prompt = ChartBuilder.chat_opts() |> Keyword.fetch!(:append_system_prompt)

      # Names alone let the model promise a year of a symbol holding six days.
      assert prompt =~ "DEEP (254 bars)"
    end
  end
end
