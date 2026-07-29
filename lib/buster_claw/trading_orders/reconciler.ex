defmodule BusterClaw.TradingOrders.Reconciler do
  @moduledoc """
  Supervised recovery loop for accepted and uncertain equity orders.

  The process is inert while the structured broker lane is sealed. Once enabled,
  it periodically asks the broker for every nonterminal order's state. A crash or
  ambiguous submit therefore resumes from the durable client order id instead of
  issuing a second order.
  """
  use GenServer

  require Logger

  alias BusterClaw.TradingOrders

  @default_interval_ms 15_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Force an immediate reconciliation pass."
  def tick_now(server \\ __MODULE__), do: send(server, :tick)

  @impl true
  def init(opts) do
    state = %{
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          Application.get_env(
            :buster_claw,
            :trading_order_reconciliation_interval_ms,
            @default_interval_ms
          )
        ),
      autostart: Keyword.get(opts, :autostart, true)
    }

    if state.autostart, do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    reconcile_if_ready()
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  defp reconcile_if_ready do
    if TradingOrders.execution_ready?() do
      case TradingOrders.reconcile_pending() do
        {:ok, %{attempted: 0}} ->
          :ok

        {:ok, summary} ->
          Logger.info("Trading order reconciliation: #{inspect(summary)}")
      end
    end
  rescue
    error ->
      Logger.warning("Trading order reconciliation tick crashed: #{inspect(error)}")
      :ok
  end
end
