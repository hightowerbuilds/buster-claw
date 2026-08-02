defmodule BusterClawWeb.TradingViewTest do
  @moduledoc """
  The Trading dashboard's view model, tested without a LiveView process.

  These are the assertions that used to be reachable only by rendering the
  whole page: what a panel is allowed to CLAIM about its data (the state
  classifiers) and how a number READS once it gets there (the formatters).
  """
  use ExUnit.Case, async: true

  alias BusterClaw.DataState
  alias BusterClawWeb.TradingView

  defp iso(minutes_ago) do
    DateTime.utc_now()
    |> DateTime.add(-minutes_ago * 60, :second)
    |> DateTime.to_iso8601()
  end

  describe "money formatting" do
    test "renders two decimals and an em dash for anything unnumeric" do
      assert TradingView.money(1234.5) == "$1234.50"
      assert TradingView.money(0) == "$0.00"
      assert TradingView.money(nil) == "—"
      assert TradingView.money("12") == "—"
    end

    test "signed_money writes the sign rather than relying on color" do
      assert TradingView.signed_money(1250) == "+$12.50"
      assert TradingView.signed_money(-1250) == "-$12.50"
      assert TradingView.signed_money(0) == "+$0.00"
      assert TradingView.signed_money(nil) == "—"
    end

    test "money_cents converts integer cents" do
      assert TradingView.money_cents(1999) == "$19.99"
      assert TradingView.money_cents(nil) == "—"
    end

    test "signed_pct and its parenthetical suffix" do
      assert TradingView.signed_pct(1.4) == "+1.40%"
      assert TradingView.signed_pct(-0.25) == "-0.25%"
      assert TradingView.pct_suffix(nil) == ""
      assert TradingView.pct_suffix(1.4) == " (+1.40%)"
    end

    test "qty trims float dust but keeps genuine fractions" do
      assert TradingView.qty(3.0) == "3"
      assert TradingView.qty(0.30000000000000004) == "0.3"
      assert TradingView.qty(1.5) == "1.5"
      assert TradingView.qty(2) == "2"
    end

    test "index_price carries no currency mark" do
      assert TradingView.index_price(5432.1) == "5432.10"
      assert TradingView.index_price(nil) == "—"
    end
  end

  describe "detail_state/2 — what the holdings panel may claim" do
    test "an account without a positions tool is never loading" do
      assert TradingView.detail_state(nil, nil) == :unsupported
      assert TradingView.detail_state(%{"holdings_supported" => false}, nil) == :unsupported
    end

    test "an ambiguous identity outranks everything else" do
      account = %{"identity_ambiguous" => true, "holdings_supported" => true}
      assert TradingView.detail_state(account, nil) == :ambiguous
    end

    test "an in-flight fetch for THIS account reads as loading" do
      account = %{"id" => "a1", "holdings_supported" => true, "detail_at" => iso(1)}
      assert TradingView.detail_state(account, {:loading, "a1"}) == :loading
      assert TradingView.detail_state(account, {:loading, "other"}) != :loading
    end

    test "a failure for THIS account surfaces its reason" do
      account = %{"id" => "a1", "holdings_supported" => true, "detail_at" => iso(1)}

      assert TradingView.detail_state(account, {:error, "a1", :bad_snapshot}) ==
               {:error, :bad_snapshot}
    end

    test "loaded with no positions is empty; loaded with positions is loaded" do
      base = %{"id" => "a1", "holdings_supported" => true, "detail_at" => iso(1)}
      assert TradingView.detail_state(base, nil) == :empty

      with_positions = Map.put(base, "positions", [%{"value" => 10.0}])
      assert TradingView.detail_state(with_positions, nil) == :loaded
    end

    test "never fetched reads as loading, not empty" do
      account = %{"id" => "a1", "holdings_supported" => true}
      assert TradingView.detail_state(account, nil) == :loading
    end
  end

  describe "detail_dataset_state/2 — the empty/stale distinction" do
    test "a FRESH empty read is a confirmed empty, not merely cached" do
      account = %{"detail_at" => iso(5)}

      assert %DataState{status: :confirmed_empty} =
               TradingView.detail_dataset_state(account, :empty)
    end

    test "a STALE empty read may not claim confirmation" do
      # older than the twelve-hour holdings threshold
      account = %{"detail_at" => iso(13 * 60)}
      assert %DataState{status: status} = TradingView.detail_dataset_state(account, :empty)
      refute status == :confirmed_empty
    end

    test "unsupported and ambiguous are unavailable with a reason" do
      assert %DataState{status: :unavailable, reason: :unsupported} =
               TradingView.detail_dataset_state(%{}, :unsupported)

      assert %DataState{status: :unavailable, reason: :ambiguous_identity} =
               TradingView.detail_dataset_state(%{}, :ambiguous)
    end

    test "loaded positions come back sorted by value, largest first" do
      account = %{
        "detail_at" => iso(5),
        "positions" => [
          %{"symbol" => "A", "value" => 5.0},
          %{"symbol" => "B", "value" => 50.0},
          %{"symbol" => "C", "value" => 20.0}
        ]
      }

      assert %DataState{data: rows} = TradingView.detail_dataset_state(account, :loaded)
      assert Enum.map(rows, & &1["symbol"]) == ~w(B C A)
    end
  end

  describe "account_dataset_state/1" do
    test "no snapshot at all is unavailable, not empty" do
      assert %DataState{status: :unavailable, reason: :not_loaded} =
               TradingView.account_dataset_state(nil)
    end

    test "an error with a previous snapshot degrades to stale rather than losing it" do
      prev = %{"fetched_at" => iso(30), "accounts" => []}

      assert %DataState{status: :stale, data: ^prev, reason: :boom} =
               TradingView.account_dataset_state({:error, :boom, prev})
    end

    test "an error with nothing cached is unavailable" do
      assert %DataState{status: :unavailable, reason: :boom} =
               TradingView.account_dataset_state({:error, :boom, nil})
    end
  end

  describe "included_total/2 — the headline must agree with the chart" do
    test "excluded accounts are left out of the total" do
      snap = %{
        "accounts" => [
          %{"last4" => "1111", "value" => 100.0},
          %{"last4" => "2222", "value" => 250.0}
        ]
      }

      assert TradingView.included_total(snap, []) == 350.0
      assert TradingView.included_total(snap, ["2222"]) == 100.0
    end

    test "non-numeric values are skipped rather than crashing the headline" do
      snap = %{
        "accounts" => [
          %{"last4" => "1111", "value" => 100.0},
          %{"last4" => "2222", "value" => "not a number"}
        ]
      }

      assert TradingView.included_total(snap, []) == 100.0
    end
  end

  describe "activity_rows/4 — naming the gap instead of hiding it" do
    test "no supported accounts says so" do
      assert %{orders: [], note: "no supported included accounts"} =
               TradingView.activity_rows([], [], nil, nil)
    end

    test "supported but none loaded reports the ratio" do
      accounts = [
        %{"last4" => "1111", "holdings_supported" => true},
        %{"last4" => "2222", "holdings_supported" => true}
      ]

      assert %{orders: [], note: "0 of 2 accounts loaded"} =
               TradingView.activity_rows(accounts, [], nil, nil)
    end

    test "a partial load is labelled partial and still shows what it has" do
      accounts = [
        %{
          "last4" => "1111",
          "holdings_supported" => true,
          "detail_at" => iso(5),
          "label" => "Investing",
          "orders" => [%{"placed_at" => iso(10), "state" => "filled"}]
        },
        %{"last4" => "2222", "holdings_supported" => true}
      ]

      assert %{note: "partial · 1 of 2 accounts", orders: [_one]} =
               TradingView.activity_rows(accounts, [], nil, nil)
    end

    test "excluded accounts drop out of the eligible set" do
      accounts = [
        %{"last4" => "1111", "holdings_supported" => true},
        %{"last4" => "2222", "holdings_supported" => true}
      ]

      assert %{note: "0 of 1 accounts loaded"} =
               TradingView.activity_rows(accounts, ["2222"], nil, nil)
    end
  end

  describe "activity_order_sections/1" do
    test "splits fills out from everything still open" do
      orders = [
        {%{"state" => "filled"}, "Investing"},
        {%{"state" => "queued"}, "Investing"}
      ]

      assert [{"Orders (not filled)", open}, {"Fills (from filled-order status)", fills}] =
               TradingView.activity_order_sections(orders)

      assert length(open) == 1
      assert length(fills) == 1
    end
  end

  describe "as-of labelling" do
    test "loading and unavailable never claim an age" do
      assert TradingView.as_of_label(DataState.loading(nil)) == "updating…"
      assert TradingView.as_of_label(DataState.unavailable(:boom)) == ""
      assert TradingView.as_of_label(DataState.fresh([], as_of: nil)) == ""
    end

    test "a known age reads as a relative time" do
      assert "as of " <> age = TradingView.as_of_label(DataState.fresh([], as_of: iso_dt(90)))
      assert age == "1h"
    end

    test "the suffix form is parenthetical" do
      assert TradingView.as_of_suffix(DataState.fresh([], as_of: nil)) == ""
      assert " (as of " <> _rest = TradingView.as_of_suffix(DataState.fresh([], as_of: iso_dt(2)))
    end
  end

  describe "error copy" do
    test "the broker-tools failure names the fix" do
      assert TradingView.detail_error({:error, :broker_tools_unavailable}) =~
               "claude mcp login robinhood"
    end

    test "an agent that answered without reaching the broker is not 'agent run failed'" do
      assert TradingView.card_error({:error, {:agent_exit, 2}, nil}) == "agent exited 2"
      assert TradingView.card_error({:error, :bad_snapshot, nil}) == "unreadable snapshot"
      assert TradingView.card_error({:error, :whatever, nil}) == "agent run failed"
    end

    test "a Robinhood message is passed through verbatim" do
      assert TradingView.detail_error({:error, {:robinhood, "rate limited"}}) == "rate limited"
    end
  end

  describe "position geometry and chips" do
    test "bar width scales against the largest position in THAT account" do
      account = %{
        "positions" => [%{"value" => 100.0}, %{"value" => 25.0}]
      }

      assert TradingView.bar_width(%{"value" => 100.0}, account) == 100.0
      assert TradingView.bar_width(%{"value" => 25.0}, account) == 25.0
    end

    test "a zero or garbage value cannot divide by zero" do
      account = %{"positions" => [%{"value" => 0}]}
      assert TradingView.bar_width(%{"value" => 0}, account) == 0
      assert TradingView.bar_width(%{"value" => "x"}, %{"positions" => []}) == 0
    end

    test "buy and sell chips carry distinct classes" do
      assert TradingView.order_side_class("buy") =~ "success"
      assert TradingView.order_side_class("sell") =~ "error"
      assert TradingView.order_side_class("wat") =~ "base-content"
    end

    test "day-change class is neutral when there is no percentage" do
      assert TradingView.position_day_class(nil) =~ "base-content"
      assert TradingView.position_day_class(-1.0) =~ "error"
      assert TradingView.position_day_class(1.0) =~ "success"
    end
  end

  describe "sorted_positions/1" do
    test "an account with no positions key yields an empty list" do
      assert TradingView.sorted_positions(%{}) == []
      assert TradingView.sorted_positions(nil) == []
    end
  end

  defp iso_dt(minutes_ago),
    do: DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second)
end
