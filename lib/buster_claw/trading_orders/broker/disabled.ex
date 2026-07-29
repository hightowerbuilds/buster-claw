defmodule BusterClaw.TradingOrders.Broker.Disabled do
  @moduledoc """
  Fail-closed production default.

  Robinhood's documented equity trading surface is Agentic MCP, not a public
  direct equity HTTP API. This adapter keeps writes sealed until a structured,
  authenticated MCP client is installed.
  """
  @behaviour BusterClaw.TradingOrders.Broker

  @impl true
  def review(_request), do: {:error, :structured_broker_adapter_not_configured}

  @impl true
  def submit(_intent, _client_order_id),
    do: {:error, {:definitive, :structured_broker_adapter_not_configured}}

  @impl true
  def fetch_order(_intent), do: {:error, :structured_broker_adapter_not_configured}
end
