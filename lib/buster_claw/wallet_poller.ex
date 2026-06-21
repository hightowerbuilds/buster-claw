defmodule BusterClaw.WalletPoller do
  @moduledoc """
  Periodic + event-driven pump for wallet feeds.

  On each tick it polls every enabled, timer-driven feed that is due
  (`market`/`url`/`integration`) via `Wallets.poll_due_feeds/1`. It also reacts to
  PubSub events for low latency: a freshly-queued Gmail dispatch item is recorded
  against `gmail` feeds, and a completed integration run refreshes `integration`
  feeds bound to that integration.

  Modeled on `BusterClaw.Dispatcher`: self-rescheduling tick, crash-safe tick
  body, and test hooks (`tick_now/1`, injected `:finance`/`:fetch` functions,
  `autostart`/`subscribe` flags).
  """
  use GenServer

  require Logger

  alias BusterClaw.{Dispatch, Integrations, Wallets}

  @default_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Force an immediate poll (tests / manual nudge)."
  def tick_now(server \\ __MODULE__), do: send(server, :tick)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true) do
      Dispatch.subscribe()
      Integrations.subscribe()
    end

    state = %{
      interval_ms:
        Keyword.get(opts, :interval_ms, configured(:wallet_poller_tick_ms, @default_interval_ms)),
      poll_opts: Keyword.take(opts, [:finance, :fetch])
    }

    if Keyword.get(opts, :autostart, true), do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    safe_tick(fn -> Wallets.poll_due_feeds(state.poll_opts) end)
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  # Inbound Gmail receipt → record against gmail feeds.
  def handle_info({:dispatch, :dispatch_item_queued, %{source: "gmail"} = item}, state) do
    safe_tick(fn -> Wallets.record_gmail_signal(item) end)
    {:noreply, state}
  end

  def handle_info({:dispatch, _event, _item}, state), do: {:noreply, state}

  # Completed integration poll → refresh bound integration feeds.
  def handle_info({:integration_run, run}, state) do
    safe_tick(fn -> Wallets.record_integration_run(run) end)
    {:noreply, state}
  end

  def handle_info({:integration_changed, _event, _integration}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  # Never let one bad feed (network error, etc.) take down the supervised pump.
  defp safe_tick(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("WalletPoller tick failed: #{Exception.message(error)}")
      :error
  end

  defp configured(key, default), do: Application.get_env(:buster_claw, key, default)
end
