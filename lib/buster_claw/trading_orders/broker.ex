defmodule BusterClaw.TradingOrders.Broker do
  @moduledoc """
  Structured boundary for equity order review, submission, and reconciliation.

  Implementations must call a broker endpoint directly and return validated
  maps. Sending a natural-language instruction to an agent is not a valid
  implementation of this behaviour.
  """

  alias BusterClaw.TradingOrders.OrderIntent

  @type review :: %{
          required(:quote_cents) => pos_integer(),
          required(:buying_power_cents) => non_neg_integer(),
          required(:estimated_notional_cents) => pos_integer(),
          required(:concentration_bps) => non_neg_integer(),
          required(:market_open) => boolean(),
          required(:broker_preview) => map(),
          required(:broker_preview_id) => String.t(),
          required(:broker_timestamp) => DateTime.t()
        }

  @callback review(map()) :: {:ok, review()} | {:error, term()}

  @callback submit(OrderIntent.t(), String.t()) ::
              {:ok,
               %{
                 required(:broker_order_id) => String.t(),
                 required(:status) => String.t(),
                 required(:response) => map()
               }}
              | {:error, {:definitive | :unknown, term()}}

  @callback fetch_order(OrderIntent.t()) ::
              {:ok, %{required(:status) => String.t(), required(:response) => map()}}
              | {:error, term()}
end
