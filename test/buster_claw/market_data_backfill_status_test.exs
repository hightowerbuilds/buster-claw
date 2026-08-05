defmodule BusterClaw.MarketDataBackfillStatusTest do
  @moduledoc """
  The distinction that cost an afternoon on 08-04.

  Four benchmarks had zero rows. The deep backfill had run once, failed, and left
  nothing behind but a `Logger` line — so "this symbol has no history yet" and
  "this symbol's fetch died" were the same observable state. The Chart Build
  agent inferred from tea leaves, the operator asked why, and the roadmap written
  in response called a one-sample failure structural.

  None of that was a bug in the fetch. It was the absence of a record.
  """
  # async: false — writes the shared `benchmark_backfill_outcomes` Settings row.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.MarketData

  describe "backfill_status/1" do
    test "a symbol nobody has tried is :never_tried, not a failure" do
      assert MarketData.backfill_status("NVDA") == :never_tried
    end

    test "a symbol whose backfill failed says so, with when and why" do
      :ok = MarketData.record_backfill_outcome("SPY", {:error, :timeout}, ~D[2026-08-04])

      assert {:failed, "2026-08-04", reason} = MarketData.backfill_status("SPY")
      assert reason =~ "timeout"
    end

    # The whole point: these two are the same number of bars and different
    # answers to "why is this chart so short?".
    test "never-tried and failed are distinguishable, which was the bug" do
      :ok = MarketData.record_backfill_outcome("QQQ", {:error, :no_bars}, ~D[2026-08-04])

      refute MarketData.backfill_status("QQQ") == MarketData.backfill_status("DIA")
      assert MarketData.backfill_status("DIA") == :never_tried
    end

    test "a symbol with a usable year is :deep regardless of past failures" do
      :ok = MarketData.record_backfill_outcome("IWM", {:error, :boom}, ~D[2026-08-01])
      seed_bars("IWM", 245)

      assert MarketData.backfill_status("IWM") == :deep
    end

    test "a success is recorded too, so the feed shows work as well as breakage" do
      :ok = MarketData.record_backfill_outcome("DIA", {:ok, 254}, ~D[2026-08-04])

      assert %{"DIA" => %{"outcome" => "ok", "bars" => 254}} = MarketData.backfill_outcomes()
    end

    test "a later outcome replaces an earlier one for the same symbol" do
      :ok = MarketData.record_backfill_outcome("SPY", {:error, :timeout}, ~D[2026-08-03])
      :ok = MarketData.record_backfill_outcome("SPY", {:ok, 254}, ~D[2026-08-04])

      assert %{"SPY" => %{"outcome" => "ok"}} = MarketData.backfill_outcomes()
    end

    # An agent-run failure term can be arbitrarily large. A settings row is not
    # the place to discover that.
    test "a huge failure reason is truncated rather than stored whole" do
      :ok = MarketData.record_backfill_outcome("SPY", {:error, String.duplicate("x", 5_000)})

      {:failed, _on, reason} = MarketData.backfill_status("SPY")
      assert String.length(reason) <= 300
    end

    test "a corrupt outcomes row degrades to :never_tried instead of crashing" do
      BusterClaw.Settings.put("benchmark_backfill_outcomes", "not json")

      assert MarketData.backfill_outcomes() == %{}
      assert MarketData.backfill_status("SPY") == :never_tried
    end
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
end
