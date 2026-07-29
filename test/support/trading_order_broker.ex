defmodule BusterClaw.TradingOrderBrokerFake do
  @moduledoc false
  @behaviour BusterClaw.TradingOrders.Broker

  @impl true
  def review(request) do
    notify({:broker_reviewed, request})

    Process.get(
      {__MODULE__, :review},
      {:ok,
       %{
         quote_cents: 19_925,
         buying_power_cents: 500_000,
         estimated_notional_cents: 39_850,
         concentration_bps: 1_200,
         market_open: true,
         broker_preview: %{"warnings" => [], "estimated_fee_cents" => 0},
         broker_preview_id: "review-opaque-123",
         broker_timestamp: DateTime.utc_now()
       }}
    )
  end

  @impl true
  def submit(intent, client_order_id) do
    count = Process.get({__MODULE__, :submit_count}, 0) + 1
    Process.put({__MODULE__, :submit_count}, count)
    notify({:broker_submitted, intent.public_id, client_order_id})

    Process.get(
      {__MODULE__, :submit},
      {:ok,
       %{
         broker_order_id: "broker-order-456",
         status: "queued",
         response: %{"state" => "queued"}
       }}
    )
  end

  @impl true
  def fetch_order(intent) do
    notify({:broker_fetched, intent.public_id})

    Process.get(
      {__MODULE__, :fetch_order},
      {:ok, %{status: "filled", response: %{"state" => "filled"}}}
    )
  end

  defp notify(message) do
    case Application.get_env(:buster_claw, :trading_order_broker_observer) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
