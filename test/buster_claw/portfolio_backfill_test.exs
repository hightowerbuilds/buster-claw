defmodule BusterClaw.PortfolioBackfillTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Portfolio
  alias BusterClaw.Trading

  defp d(iso), do: Date.from_iso8601!(iso)

  defp account(key, value), do: %{"last4" => key, "label" => "Acct", "value" => value}

  defp record(day, accounts) do
    {:ok, _} = Portfolio.record(%{"accounts" => accounts}, day: d(day))
    :ok
  end

  defp bucket(day, realized, trades),
    do: %{bucket_on: d(day), realized: realized, trades: trades}

  describe "Trading.parse_backfill/1" do
    test "parses the shape the live API actually returns" do
      # Trimmed from the 07-27 probe: monthly buckets, null for months with no
      # closing trades, and a genuinely negative month.
      out = ~s({"buckets": [
        {"bucket_on": "2025-02-28", "realized": null, "trades": 0},
        {"bucket_on": "2025-03-28", "realized": 3.47, "trades": 6},
        {"bucket_on": "2026-02-28", "realized": -1076.54, "trades": 2}
      ]})

      assert {:ok, [a, b, c]} = Trading.parse_backfill(out)
      assert a.realized == nil
      assert a.trades == 0
      assert b.realized == 3.47
      assert c.realized == -1076.54
    end

    test "null and zero stay distinguishable — no trades isn't a zero result" do
      out = ~s({"buckets": [
        {"bucket_on": "2025-01-28", "realized": null, "trades": 0},
        {"bucket_on": "2025-02-28", "realized": 0, "trades": 3}
      ]})

      assert {:ok, [no_trades, flat]} = Trading.parse_backfill(out)
      assert no_trades.realized == nil
      assert no_trades.trades == 0
      assert flat.realized == 0
      assert flat.trades == 3
    end

    test "buckets come back oldest first regardless of input order" do
      out = ~s({"buckets": [
        {"bucket_on": "2026-02-28", "realized": 1.0, "trades": 1},
        {"bucket_on": "2025-03-28", "realized": 2.0, "trades": 1}
      ]})

      assert {:ok, [first, second]} = Trading.parse_backfill(out)
      assert first.bucket_on == d("2025-03-28")
      assert second.bucket_on == d("2026-02-28")
    end

    test "an unparseable bucket is dropped rather than failing the fetch" do
      out = ~s({"buckets": [
        {"bucket_on": "not a date", "realized": 1.0, "trades": 1},
        {"bucket_on": "2025-03-28", "realized": 2.0, "trades": 1}
      ]})

      assert {:ok, [only]} = Trading.parse_backfill(out)
      assert only.bucket_on == d("2025-03-28")
    end

    test "errors and garbage stay distinguishable" do
      assert {:error, {:robinhood, _}} =
               Trading.parse_backfill(~s({"error": "account not found"}))

      assert {:error, :bad_snapshot} = Trading.parse_backfill("no json")
    end

    test "the prompt forbids inventing finer resolution than the API gives" do
      prompt = Trading.backfill_prompt("8262")

      assert prompt =~ "ENDS IN 8262"
      assert prompt =~ "span \"all\""
      assert prompt =~ "OWN granularity"
      assert prompt =~ "Never split a bucket"
      assert prompt =~ "Do not substitute 0 for null"
      assert prompt =~ "Read only"
    end
  end

  describe "store_backfill/2" do
    test "stores signed cents, treating a null month as zero realized" do
      assert 3 =
               Portfolio.store_backfill("8262", [
                 bucket("2025-01-28", nil, 0),
                 bucket("2025-02-28", 48.42, 9),
                 bucket("2025-03-28", -4.03, 4)
               ])

      assert [a, b, c] = Portfolio.realized_points("8262")
      assert a.realized_cents == 0
      assert a.trades == 0
      assert b.realized_cents == 4_842
      assert c.realized_cents == -403
    end

    test "a re-run replaces rather than merges — bucket boundaries can shift" do
      Portfolio.store_backfill("8262", [bucket("2025-01-28", 10.0, 1)])
      Portfolio.store_backfill("8262", [bucket("2025-01-31", 12.0, 2)])

      assert [only] = Portfolio.realized_points("8262")
      assert only.bucket_on == d("2025-01-31")
      assert only.realized_cents == 1_200
    end

    test "one account's backfill doesn't disturb another's" do
      Portfolio.store_backfill("8262", [bucket("2025-01-28", 10.0, 1)])
      Portfolio.store_backfill("6587", [bucket("2025-01-28", 20.0, 1)])

      assert [roth] = Portfolio.realized_points("8262")
      assert [agentic] = Portfolio.realized_points("6587")
      assert roth.realized_cents == 1_000
      assert agentic.realized_cents == 2_000
    end

    test "backfilled?/1 and clear_backfill/1" do
      refute Portfolio.backfilled?("8262")
      Portfolio.store_backfill("8262", [bucket("2025-01-28", 10.0, 1)])
      assert Portfolio.backfilled?("8262")

      assert {:ok, 1} = Portfolio.clear_backfill("8262")
      refute Portfolio.backfilled?("8262")
    end
  end

  describe "cumulative_series/1 — the seam" do
    test "realized history runs first, then recorded history continues from it" do
      Portfolio.store_backfill("8262", [
        bucket("2026-05-28", 100.0, 4),
        bucket("2026-06-28", 50.0, 2)
      ])

      record("2026-07-27", [account("8262", 1_000.0)])
      record("2026-07-28", [account("8262", 1_010.0)])

      assert [a, b, c, e] = Portfolio.cumulative_series("8262")

      assert a.measure == :realized
      assert a.cumulative_cents == 10_000
      assert b.measure == :realized
      assert b.cumulative_cents == 15_000

      # The recorded segment continues the line rather than restarting at zero.
      assert c.measure == :recorded
      assert c.day == d("2026-07-27")
      assert c.cumulative_cents == 15_000
      assert c.gain_cents == nil

      assert e.measure == :recorded
      assert e.cumulative_cents == 16_000
      assert e.gain_cents == 1_000
    end

    test "buckets starting on or after the seam are dropped, never double-counted" do
      Portfolio.store_backfill("8262", [
        bucket("2026-06-28", 50.0, 2),
        # This bucket begins after recording started; its days belong to the
        # recorded segment and counting both would inflate the line.
        bucket("2026-07-28", 900.0, 9)
      ])

      record("2026-07-27", [account("8262", 1_000.0)])
      record("2026-07-28", [account("8262", 1_010.0)])

      series = Portfolio.cumulative_series("8262")
      assert Enum.count(series, &(&1.measure == :realized)) == 1
      assert List.last(series).cumulative_cents == 6_000
    end

    test "with no backfill the series is purely recorded, starting at zero" do
      record("2026-07-27", [account("8262", 1_000.0)])
      record("2026-07-28", [account("8262", 1_010.0)])

      assert [first, second] = Portfolio.cumulative_series("8262")
      assert first.measure == :recorded
      assert first.cumulative_cents == 0
      assert second.cumulative_cents == 1_000
    end

    test "with no recordings the series is purely realized" do
      Portfolio.store_backfill("8262", [
        bucket("2026-05-28", 100.0, 4),
        bucket("2026-06-28", -30.0, 2)
      ])

      assert [a, b] = Portfolio.cumulative_series("8262")
      assert a.cumulative_cents == 10_000
      assert b.cumulative_cents == 7_000
      assert Enum.all?([a, b], &(&1.measure == :realized))
    end

    test "a flow marked in the recorded segment still nets out across the seam" do
      Portfolio.store_backfill("8262", [bucket("2026-06-28", 100.0, 4)])

      record("2026-07-27", [account("8262", 1_000.0)])
      record("2026-07-28", [account("8262", 1_510.0)])

      {:ok, _} =
        Portfolio.put_flow(%{
          account_key: "8262",
          occurred_on: d("2026-07-28"),
          amount_cents: 50_000,
          kind: "deposit",
          source: "manual"
        })

      last = Portfolio.cumulative_series("8262") |> List.last()
      # $100 realized before the seam, $10 earned after, and the $500 deposit
      # contributing nothing.
      assert last.cumulative_cents == 11_000
    end

    test "an empty ledger with no backfill is an empty series" do
      assert Portfolio.cumulative_series("8262") == []
    end
  end

  describe "total_cumulative_series/0" do
    test "merges accounts whose buckets don't align, as a step function" do
      Portfolio.store_backfill("8262", [
        bucket("2026-05-28", 100.0, 4),
        bucket("2026-06-28", 50.0, 2)
      ])

      # Different bucket dates entirely.
      Portfolio.store_backfill("6587", [
        bucket("2026-05-15", 20.0, 1),
        bucket("2026-06-15", 30.0, 1)
      ])

      series = Portfolio.total_cumulative_series()
      assert Enum.all?(series, &(&1.measure == :realized))

      # Four distinct dates, and the running total reaches every account's sum.
      assert length(series) == 4
      assert List.last(series).cumulative_cents == 20_000
    end

    test "the recorded segment continues from the merged realized total" do
      Portfolio.store_backfill("8262", [bucket("2026-06-28", 100.0, 4)])
      Portfolio.store_backfill("6587", [bucket("2026-06-28", 50.0, 2)])

      record("2026-07-27", [account("8262", 1_000.0), account("6587", 500.0)])
      record("2026-07-28", [account("8262", 1_010.0), account("6587", 505.0)])

      series = Portfolio.total_cumulative_series()
      last = List.last(series)

      assert last.measure == :recorded
      # $150 realized across both, plus $15 earned since recording began.
      assert last.cumulative_cents == 16_500
    end

    test "it inherits the completeness rule from the recorded side" do
      record("2026-07-27", [account("8262", 1_000.0), account("6587", 500.0)])
      # 6587 missed the 28th entirely.
      record("2026-07-28", [account("8262", 1_010.0)])

      series = Portfolio.total_cumulative_series()
      assert length(series) == 1
      assert List.first(series).day == d("2026-07-27")
    end
  end

  describe "backfill_coverage/0" do
    test "names the accounts whose history is missing from the total" do
      record("2026-07-27", [account("8262", 1_000.0), account("6587", 500.0)])
      Portfolio.store_backfill("8262", [bucket("2026-06-28", 100.0, 4)])

      assert %{accounts: 2, backfilled: 1, missing: ["6587"]} = Portfolio.backfill_coverage()
    end

    test "full coverage reports nothing missing" do
      record("2026-07-27", [account("8262", 1_000.0)])
      Portfolio.store_backfill("8262", [bucket("2026-06-28", 100.0, 4)])

      assert %{accounts: 1, backfilled: 1, missing: []} = Portfolio.backfill_coverage()
    end

    test "an understated total is still drawn — and the coverage says by whom" do
      # This is the 07-27 failure reproduced: one account's backfill never
      # landed, so the realized segment counts only the other's history.
      record("2026-07-27", [account("8262", 1_000.0), account("8735", 0.0)])
      Portfolio.store_backfill("8262", [bucket("2026-06-28", 100.0, 4)])

      series = Portfolio.total_cumulative_series()
      assert Enum.any?(series, &(&1.measure == :realized))
      # The line exists and is honest about its own incompleteness elsewhere.
      assert %{missing: ["8735"]} = Portfolio.backfill_coverage()
    end
  end

  test "to_signed_cents/1 keeps losses negative and rounds once" do
    assert Portfolio.to_signed_cents(-1_076.54) == -107_654
    assert Portfolio.to_signed_cents(3.47) == 347
    assert Portfolio.to_signed_cents(nil) == 0
    assert Portfolio.to_signed_cents("nope") == 0
  end
end
