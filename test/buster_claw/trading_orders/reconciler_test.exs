defmodule BusterClaw.TradingOrders.ReconcilerTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.TradingOrderBrokerFake
  alias BusterClaw.TradingOrders
  alias BusterClaw.TradingOrders.Reconciler

  setup do
    previous_broker = Application.get_env(:buster_claw, :trading_order_broker)
    previous_account = Application.get_env(:buster_claw, :trading_order_account)
    previous_policy = Application.get_env(:buster_claw, :trading_order_policy)

    Application.put_env(:buster_claw, :trading_order_broker, TradingOrderBrokerFake)

    Application.put_env(:buster_claw, :trading_order_account, %{
      id: "agentic-account-opaque",
      label: "Agentic"
    })

    Application.put_env(:buster_claw, :trading_order_policy,
      max_notional_cents: 100_000,
      max_concentration_bps: 2_500,
      max_quote_age_seconds: 30,
      blocked_symbols: [],
      allow_market_orders_outside_hours: true
    )

    on_exit(fn ->
      restore_env(:trading_order_broker, previous_broker)
      restore_env(:trading_order_account, previous_account)
      restore_env(:trading_order_policy, previous_policy)
    end)

    :ok
  end

  test "a tick advances every nonterminal order and leaves terminal orders alone" do
    accepted = submitted_order()
    assert accepted.status == "accepted"

    pid = start_supervised!({Reconciler, autostart: false, interval_ms: 60_000})
    Reconciler.tick_now(pid)
    _ = :sys.get_state(pid)

    assert TradingOrders.get(accepted.public_id).status == "filled"

    event_count = length(TradingOrders.events(accepted.public_id))
    Reconciler.tick_now(pid)
    _ = :sys.get_state(pid)

    assert length(TradingOrders.events(accepted.public_id)) == event_count
  end

  defp submitted_order do
    {:ok, draft} =
      TradingOrders.create_draft(%{
        "account_id" => "agentic-account-opaque",
        "symbol" => "AAPL",
        "side" => "buy",
        "amount_type" => "quantity",
        "amount" => "2",
        "order_type" => "market",
        "limit_price" => "",
        "time_in_force" => "day"
      })

    {:ok, preview} = TradingOrders.preview(draft.public_id)

    TradingOrders.confirm_and_submit(
      draft.public_id,
      preview.intent.preview_digest,
      preview.confirmation_phrase
    )
    |> elem(1)
  end

  defp restore_env(key, nil), do: Application.delete_env(:buster_claw, key)
  defp restore_env(key, value), do: Application.put_env(:buster_claw, key, value)
end
