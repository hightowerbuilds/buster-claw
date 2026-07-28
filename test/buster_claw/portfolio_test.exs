defmodule BusterClaw.PortfolioTest do
  # DataCase: the ledger is the point of this module, so nothing here is
  # meaningful without the repo.
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Portfolio
  alias BusterClaw.Portfolio.Snapshot

  # A stage-1 shaped snapshot: exactly what Trading.parse_snapshot/1 emits, since
  # that is the only thing that ever reaches Portfolio.record/2.
  defp snapshot(accounts), do: %{"accounts" => accounts, "fetched_at" => "2026-07-27T00:00:00Z"}

  defp account(key, label, value, opts \\ []) do
    %{
      "id" => "••••#{key}",
      "last4" => key,
      "label" => label,
      "agentic" => Keyword.get(opts, :agentic, false),
      "holdings_supported" => true,
      "value" => value,
      "cash" => Keyword.get(opts, :cash, 0.0),
      "buying_power" => Keyword.get(opts, :buying_power, 0.0)
    }
  end

  defp day(iso), do: Date.from_iso8601!(iso)

  describe "to_cents/1" do
    test "rounds exactly once and refuses anything that isn't a non-negative number" do
      assert Portfolio.to_cents(102.58) == {:ok, 10_258}
      assert Portfolio.to_cents(0) == {:ok, 0}
      assert Portfolio.to_cents(212.306626) == {:ok, 21_231}

      assert {:error, {:negative_value, _}} = Portfolio.to_cents(-1.0)
      assert {:error, {:non_numeric_value, _}} = Portfolio.to_cents("lots")
      assert {:error, {:non_numeric_value, _}} = Portfolio.to_cents(nil)
    end

    test "a float that would drift in a running total is fixed at the boundary" do
      # 0.1 + 0.2 != 0.3 in float; in cents it is exactly 30.
      {:ok, a} = Portfolio.to_cents(0.1)
      {:ok, b} = Portfolio.to_cents(0.2)
      assert a + b == 30
    end
  end

  describe "record/2" do
    test "writes one row per account with money as cents" do
      snap = snapshot([account("6587", "Agentic", 102.58), account("8262", "Roth IRA", 212.31)])

      assert {:ok, 2} = Portfolio.record(snap, day: day("2026-07-27"))

      assert [agentic, roth] = Portfolio.all_snapshots() |> Enum.sort_by(& &1.account_key)
      assert agentic.account_key == "6587"
      assert agentic.value_cents == 10_258
      assert agentic.label == "Agentic"
      assert agentic.source == "tab_open"
      assert roth.value_cents == 21_231
    end

    test "is idempotent for a day — the last reading wins, no duplicate points" do
      d = day("2026-07-27")

      {:ok, 1} = Portfolio.record(snapshot([account("6587", "Agentic", 102.58)]), day: d)
      {:ok, 1} = Portfolio.record(snapshot([account("6587", "Agentic", 104.00)]), day: d)
      {:ok, 1} = Portfolio.record(snapshot([account("6587", "Agentic", 99.25)]), day: d)

      assert [only] = Portfolio.series("6587")
      assert only.value_cents == 9_925
    end

    test "an account with no last4 is skipped, not filed under a key that won't match" do
      orphan = account("6587", "Agentic", 100.0) |> Map.delete("last4")

      assert {:ok, 0} = Portfolio.record(snapshot([orphan]), day: day("2026-07-27"))
      assert Portfolio.all_snapshots() == []
    end

    test "one bad account does not cost the others their reading" do
      snap =
        snapshot([
          account("6587", "Agentic", "not a number"),
          account("8262", "Roth IRA", 212.31)
        ])

      assert {:ok, 1} = Portfolio.record(snap, day: day("2026-07-27"))
      assert [row] = Portfolio.all_snapshots()
      assert row.account_key == "8262"
    end

    test "an empty snapshot is an error, not a silent no-op" do
      assert {:error, :no_accounts} = Portfolio.record(%{"accounts" => []})
      assert {:error, :no_accounts} = Portfolio.record(%{})
    end

    test "the source is recorded so a pumped day is distinguishable from a viewed one" do
      {:ok, 1} =
        Portfolio.record(snapshot([account("6587", "Agentic", 100.0)]),
          day: day("2026-07-27"),
          source: "daily_pump"
        )

      assert [row] = Portfolio.all_snapshots()
      assert row.source == "daily_pump"
    end
  end

  describe "the order-of-magnitude gate" do
    setup do
      {:ok, 1} =
        Portfolio.record(snapshot([account("6587", "Agentic", 100.0)]), day: day("2026-07-26"))

      :ok
    end

    test "an implausible jump is refused — a gap beats a poisoned row" do
      assert {:ok, 0} =
               Portfolio.record(snapshot([account("6587", "Agentic", 900_000.0)]),
                 day: day("2026-07-27")
               )

      # Yesterday survives untouched; today is simply absent.
      assert [only] = Portfolio.series("6587")
      assert only.captured_on == day("2026-07-26")
    end

    test "an implausible collapse is refused too" do
      # Large-magnitude nonsense in the other direction: a funded account
      # reporting near-zero. Seeded big so the move clears the absolute floor.
      {:ok, 1} =
        Portfolio.record(snapshot([account("9000", "Big", 100_000.0)]), day: day("2026-07-26"))

      assert {:ok, 0} =
               Portfolio.record(snapshot([account("9000", "Big", 1.0)]), day: day("2026-07-27"))

      assert length(Portfolio.series("9000")) == 1
    end

    test "funding a small account is NOT garbage, however large the ratio" do
      # A $500 deposit into a $100 account is 6x — fine. Into a $3 account it is
      # 149x, and a fold-only gate would throw the day away AND suppress the
      # transfer prompt that explains it.
      {:ok, 1} =
        Portfolio.record(snapshot([account("7001", "Tiny", 3.38)]), day: day("2026-07-26"))

      assert {:ok, 1} =
               Portfolio.record(snapshot([account("7001", "Tiny", 503.38)]),
                 day: day("2026-07-27")
               )

      assert [_, funded] = Portfolio.series("7001")
      assert funded.value_cents == 50_338
    end

    test "a units error in a real-money account is still caught" do
      # The garbage mode the gate exists for: cents read as dollars.
      {:ok, 1} =
        Portfolio.record(snapshot([account("7002", "Real", 12_000.0)]), day: day("2026-07-26"))

      assert {:ok, 0} =
               Portfolio.record(snapshot([account("7002", "Real", 1_200_000.0)]),
                 day: day("2026-07-27")
               )

      assert length(Portfolio.series("7002")) == 1
    end

    test "a real day's move is not gated — this is a garbage filter, not a volatility opinion" do
      # A genuine doubling, and a genuine halving, both pass.
      assert {:ok, 1} =
               Portfolio.record(snapshot([account("6587", "Agentic", 200.0)]),
                 day: day("2026-07-27")
               )

      assert {:ok, 1} =
               Portfolio.record(snapshot([account("6587", "Agentic", 50.0)]),
                 day: day("2026-07-28")
               )

      assert length(Portfolio.series("6587")) == 3
    end

    test "re-recording the same day is never gated against its own earlier value" do
      d = day("2026-07-27")
      {:ok, 1} = Portfolio.record(snapshot([account("6587", "Agentic", 100.0)]), day: d)

      # 100 -> 0.50 within the same day would trip the gate if it compared
      # against today's row instead of the previous day's.
      assert {:ok, 1} = Portfolio.record(snapshot([account("6587", "Agentic", 50.0)]), day: d)
      assert [_yesterday, today] = Portfolio.series("6587")
      assert today.value_cents == 5_000
    end

    test "an account's first ever reading has nothing to compare against and is allowed" do
      assert {:ok, 1} =
               Portfolio.record(snapshot([account("9999", "Brand New", 500_000.0)]),
                 day: day("2026-07-27")
               )

      assert [row] = Portfolio.series("9999")
      assert row.value_cents == 50_000_000
    end
  end

  describe "total_series/0" do
    test "sums the accounts on days where all of them reported" do
      for {d, a, b} <- [{"2026-07-26", 100.0, 200.0}, {"2026-07-27", 110.0, 190.0}] do
        {:ok, 2} =
          Portfolio.record(
            snapshot([account("6587", "Agentic", a), account("8262", "Roth IRA", b)]),
            day: day(d)
          )
      end

      assert [first, second] = Portfolio.total_series()
      assert first.day == day("2026-07-26")
      assert first.value_cents == 30_000
      assert first.accounts == 2
      assert second.value_cents == 30_000
    end

    test "a day where one account is missing is a GAP, not a smaller total" do
      {:ok, 2} =
        Portfolio.record(
          snapshot([account("6587", "Agentic", 100.0), account("8262", "Roth IRA", 200.0)]),
          day: day("2026-07-26")
        )

      # The Roth failed to record. Summing what reported would draw a $200 crash
      # that never happened.
      {:ok, 1} =
        Portfolio.record(snapshot([account("6587", "Agentic", 105.0)]), day: day("2026-07-27"))

      assert [only] = Portfolio.total_series()
      assert only.day == day("2026-07-26")
      assert only.value_cents == 30_000
    end

    test "adding a new account today does not retroactively void complete history" do
      {:ok, 1} =
        Portfolio.record(snapshot([account("6587", "Agentic", 100.0)]), day: day("2026-07-25"))

      {:ok, 1} =
        Portfolio.record(snapshot([account("6587", "Agentic", 110.0)]), day: day("2026-07-26"))

      # A second account opens on the 27th. The 25th and 26th were complete for
      # every account that existed then, and must stay on the chart.
      {:ok, 2} =
        Portfolio.record(
          snapshot([account("6587", "Agentic", 120.0), account("8262", "Roth IRA", 50.0)]),
          day: day("2026-07-27")
        )

      assert [d25, d26, d27] = Portfolio.total_series()
      assert d25.value_cents == 10_000
      assert d25.accounts == 1
      assert d26.value_cents == 11_000
      assert d27.value_cents == 17_000
      assert d27.accounts == 2
    end

    test "an empty ledger is an empty series, not a crash" do
      assert Portfolio.total_series() == []
    end
  end

  test "the changeset refuses a negative value even if the gate is bypassed" do
    changeset =
      Snapshot.changeset(%Snapshot{}, %{
        account_key: "6587",
        label: "Agentic",
        captured_on: day("2026-07-27"),
        value_cents: -1,
        source: "tab_open"
      })

    refute changeset.valid?
    assert %{value_cents: _} = errors_on(changeset)
  end

  test "the changeset refuses an unknown source" do
    changeset =
      Snapshot.changeset(%Snapshot{}, %{
        account_key: "6587",
        label: "Agentic",
        captured_on: day("2026-07-27"),
        value_cents: 100,
        source: "vibes"
      })

    refute changeset.valid?
  end
end
