defmodule BusterClaw.PortfolioFlowsTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Portfolio
  alias BusterClaw.Portfolio.Flow

  defp d(iso), do: Date.from_iso8601!(iso)

  defp account(key, value, label \\ "Acct") do
    %{"id" => "••••#{key}", "last4" => key, "label" => label, "value" => value}
  end

  defp record(day, accounts) do
    {:ok, _} = Portfolio.record(%{"accounts" => accounts}, day: d(day))
    :ok
  end

  defp deposit(key, day, dollars, note \\ nil) do
    Portfolio.put_flow(%{
      account_key: key,
      occurred_on: d(day),
      amount_cents: round(dollars * 100),
      kind: "deposit",
      note: note,
      source: "manual"
    })
  end

  describe "put_flow/1 sign discipline" do
    test "a withdrawal filed as positive is refused" do
      assert {:error, changeset} =
               Portfolio.put_flow(%{
                 account_key: "6587",
                 occurred_on: d("2026-07-27"),
                 amount_cents: 50_000,
                 kind: "withdrawal",
                 source: "manual"
               })

      assert %{amount_cents: [msg]} = errors_on(changeset)
      assert msg =~ "negative"
    end

    test "a deposit filed as negative is refused" do
      assert {:error, changeset} =
               Portfolio.put_flow(%{
                 account_key: "6587",
                 occurred_on: d("2026-07-27"),
                 amount_cents: -50_000,
                 kind: "deposit",
                 source: "manual"
               })

      assert %{amount_cents: [msg]} = errors_on(changeset)
      assert msg =~ "positive"
    end

    test "not_a_transfer must be exactly zero" do
      assert {:error, _} =
               Portfolio.put_flow(%{
                 account_key: "6587",
                 occurred_on: d("2026-07-27"),
                 amount_cents: 100,
                 kind: "not_a_transfer",
                 source: "manual"
               })

      assert {:ok, %Flow{amount_cents: 0}} =
               Portfolio.put_flow(%{
                 account_key: "6587",
                 occurred_on: d("2026-07-27"),
                 amount_cents: 0,
                 kind: "not_a_transfer",
                 source: "manual"
               })
    end

    test "re-answering a day replaces the flow instead of stacking a second" do
      {:ok, _} = deposit("6587", "2026-07-27", 500.0)
      {:ok, _} = deposit("6587", "2026-07-27", 300.0)

      assert [only] = Portfolio.flows("6587")
      assert only.amount_cents == 30_000
    end
  end

  describe "gain_series/1" do
    test "the first reading has no gain — there is nothing to measure against" do
      record("2026-07-27", [account("6587", 100.0)])

      assert [first] = Portfolio.gain_series("6587")
      assert first.gain_cents == nil
      assert first.cumulative_cents == 0
      assert first.value_cents == 10_000
    end

    test "day-over-day gain and a running cumulative" do
      record("2026-07-27", [account("6587", 100.0)])
      record("2026-07-28", [account("6587", 110.0)])
      record("2026-07-29", [account("6587", 105.0)])

      assert [a, b, c] = Portfolio.gain_series("6587")
      assert a.gain_cents == nil
      assert b.gain_cents == 1_000
      assert b.cumulative_cents == 1_000
      assert c.gain_cents == -500
      assert c.cumulative_cents == 500
    end

    test "a deposit is removed from gain while the value still steps up" do
      record("2026-07-27", [account("6587", 100.0)])
      # $500 in, plus $10 of real market gain.
      record("2026-07-28", [account("6587", 610.0)])

      # Before marking it, the deposit reads as performance.
      assert [_, unmarked] = Portfolio.gain_series("6587")
      assert unmarked.gain_cents == 51_000

      {:ok, _} = deposit("6587", "2026-07-28", 500.0)

      assert [_, marked] = Portfolio.gain_series("6587")
      # The $10 that was actually earned, and only that.
      assert marked.gain_cents == 1_000
      assert marked.flow_cents == 50_000
      # The value line is untouched — the account really does hold $610.
      assert marked.value_cents == 61_000
    end

    test "a withdrawal is added back, so taking money out isn't a loss" do
      record("2026-07-27", [account("6587", 600.0)])
      record("2026-07-28", [account("6587", 105.0)])

      {:ok, _} =
        Portfolio.put_flow(%{
          account_key: "6587",
          occurred_on: d("2026-07-28"),
          amount_cents: -50_000,
          kind: "withdrawal",
          source: "manual"
        })

      assert [_, marked] = Portfolio.gain_series("6587")
      assert marked.gain_cents == 500
    end

    test "not_a_transfer leaves the gain exactly as it was" do
      record("2026-07-27", [account("6587", 100.0)])
      record("2026-07-28", [account("6587", 150.0)])

      {:ok, _} =
        Portfolio.put_flow(%{
          account_key: "6587",
          occurred_on: d("2026-07-28"),
          amount_cents: 0,
          kind: "not_a_transfer",
          source: "manual"
        })

      assert [_, marked] = Portfolio.gain_series("6587")
      assert marked.gain_cents == 5_000
    end

    test "a flow inside a recording gap is subtracted exactly once" do
      record("2026-07-27", [account("6587", 100.0)])
      # The 28th was never recorded; the deposit landed that day.
      record("2026-07-29", [account("6587", 610.0)])

      {:ok, _} = deposit("6587", "2026-07-28", 500.0)

      assert [_, after_gap] = Portfolio.gain_series("6587")
      # Spans 27th -> 29th and still nets out the deposit once.
      assert after_gap.gain_cents == 1_000
    end

    test "a flow before the first reading never leaks into the series" do
      {:ok, _} = deposit("6587", "2026-07-01", 500.0)

      record("2026-07-27", [account("6587", 600.0)])
      record("2026-07-28", [account("6587", 610.0)])

      assert [first, second] = Portfolio.gain_series("6587")
      assert first.gain_cents == nil
      # The old deposit is already inside the opening balance; subtracting it
      # here would invent a $500 loss.
      assert second.gain_cents == 1_000
    end

    test "cumulative gain is unaffected by deposits across many days" do
      record("2026-07-27", [account("6587", 100.0)])
      record("2026-07-28", [account("6587", 601.0)])
      record("2026-07-29", [account("6587", 1_102.0)])

      {:ok, _} = deposit("6587", "2026-07-28", 500.0)
      {:ok, _} = deposit("6587", "2026-07-29", 500.0)

      assert [_, b, c] = Portfolio.gain_series("6587")
      assert b.gain_cents == 100
      assert c.gain_cents == 100
      # $2 earned across a thousand dollars of transfers.
      assert c.cumulative_cents == 200
    end

    test "an empty ledger is an empty series" do
      assert Portfolio.gain_series("6587") == []
    end
  end

  describe "total_gain_series/0" do
    test "sums accounts and nets out flows from any of them" do
      record("2026-07-27", [account("6587", 100.0), account("8262", 200.0)])
      record("2026-07-28", [account("6587", 105.0), account("8262", 700.0)])

      # $500 went into the Roth. Real earnings: $5 in the first account
      # (100 -> 105) and nothing in the Roth once the deposit is netted out.
      {:ok, _} = deposit("8262", "2026-07-28", 500.0)

      assert [first, second] = Portfolio.total_gain_series()
      assert first.value_cents == 30_000
      assert second.value_cents == 80_500
      assert second.gain_cents == 500
    end

    test "a newly opened account's balance is a flow, not performance" do
      record("2026-07-27", [account("6587", 100.0)])
      # A second account appears, holding $900 it did not earn here.
      record("2026-07-28", [account("6587", 110.0), account("8262", 900.0)])

      assert [_first, second] = Portfolio.total_gain_series()
      assert second.value_cents == 101_000
      # Only the $10 the first account actually made.
      assert second.gain_cents == 1_000
    end

    test "an account entering on the very first day is not double-counted" do
      # Nothing precedes the first point, so its gain is nil and the entering
      # balance has nothing to be subtracted from.
      record("2026-07-27", [account("6587", 100.0), account("8262", 900.0)])
      record("2026-07-28", [account("6587", 110.0), account("8262", 900.0)])

      assert [first, second] = Portfolio.total_gain_series()
      assert first.gain_cents == nil
      assert second.gain_cents == 1_000
    end

    test "an entering account and a marked deposit on the same day both net out" do
      record("2026-07-27", [account("6587", 100.0)])
      record("2026-07-28", [account("6587", 610.0), account("8262", 900.0)])

      {:ok, _} = deposit("6587", "2026-07-28", 500.0)

      assert [_, second] = Portfolio.total_gain_series()
      # $900 entering + $500 deposited, leaving the $10 genuinely earned.
      assert second.gain_cents == 1_000
    end

    test "it inherits the completeness rule — an incomplete day is skipped" do
      record("2026-07-27", [account("6587", 100.0), account("8262", 200.0)])
      # The Roth failed to record on the 28th.
      record("2026-07-28", [account("6587", 105.0)])
      record("2026-07-29", [account("6587", 110.0), account("8262", 210.0)])

      assert [first, second] = Portfolio.total_gain_series()
      assert first.day == d("2026-07-27")
      assert second.day == d("2026-07-29")
      # The gain spans the skipped day rather than measuring against a phantom.
      assert second.gain_cents == 2_000
    end
  end

  describe "anomalies/1" do
    test "a large unexplained move is flagged" do
      record("2026-07-27", [account("6587", 100.0)])
      record("2026-07-28", [account("6587", 610.0)])

      assert [flagged] = Portfolio.anomalies("6587")
      assert flagged.day == d("2026-07-28")
      assert flagged.gain_cents == 51_000
    end

    test "marking the day clears it — the prompt does not nag forever" do
      record("2026-07-27", [account("6587", 100.0)])
      record("2026-07-28", [account("6587", 610.0)])

      {:ok, _} = deposit("6587", "2026-07-28", 500.0)
      assert Portfolio.anomalies("6587") == []
    end

    test "answering 'no, that was the market' also clears it" do
      record("2026-07-27", [account("6587", 100.0)])
      record("2026-07-28", [account("6587", 610.0)])

      {:ok, _} =
        Portfolio.put_flow(%{
          account_key: "6587",
          occurred_on: d("2026-07-28"),
          amount_cents: 0,
          kind: "not_a_transfer",
          source: "manual"
        })

      assert Portfolio.anomalies("6587") == []
    end

    test "ordinary movement is not flagged" do
      record("2026-07-27", [account("6587", 10_000.0)])
      # A 2% day on a $10k account.
      record("2026-07-28", [account("6587", 10_200.0)])

      assert Portfolio.anomalies("6587") == []
    end

    test "a big percentage on a tiny balance stays below the absolute floor" do
      record("2026-07-27", [account("6587", 10.0)])
      # Tripled, but only $20 — noise, not a transfer.
      record("2026-07-28", [account("6587", 30.0)])

      assert Portfolio.anomalies("6587") == []
    end

    test "a large withdrawal is flagged too, not just a deposit" do
      record("2026-07-27", [account("6587", 1_000.0)])
      record("2026-07-28", [account("6587", 200.0)])

      assert [flagged] = Portfolio.anomalies("6587")
      assert flagged.gain_cents == -80_000
    end

    test "latest_anomaly returns the most recent one" do
      record("2026-07-27", [account("6587", 100.0)])
      record("2026-07-28", [account("6587", 610.0)])
      record("2026-07-29", [account("6587", 2_000.0)])

      assert Portfolio.latest_anomaly("6587").day == d("2026-07-29")
    end

    test "the documented blind spot: a small deposit into a large account" do
      record("2026-07-27", [account("6587", 200_000.0)])
      # A real $1,000 deposit — 0.5%, invisible to any ratio test.
      record("2026-07-28", [account("6587", 201_000.0)])

      assert Portfolio.anomalies("6587") == []

      # Which is exactly why marking a day directly must not require the prompt.
      {:ok, _} = deposit("6587", "2026-07-28", 1_000.0)
      assert [_, marked] = Portfolio.gain_series("6587")
      assert marked.gain_cents == 0
    end
  end

  test "delete_flow/2 returns a day to unaccounted-for" do
    record("2026-07-27", [account("6587", 100.0)])
    record("2026-07-28", [account("6587", 610.0)])
    {:ok, _} = deposit("6587", "2026-07-28", 500.0)

    assert Portfolio.anomalies("6587") == []
    assert {:ok, 1} = Portfolio.delete_flow("6587", d("2026-07-28"))
    assert [_] = Portfolio.anomalies("6587")
  end
end
