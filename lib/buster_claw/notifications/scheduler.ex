defmodule BusterClaw.Notifications.Scheduler do
  @moduledoc """
  Fires notifications when their moment arrives.

  Rather than poll on a fixed interval, it arms a single timer to the earliest
  armed `fire_at` (capped at `@max_idle_ms`, so clock drift or a missed wake
  self-heals and a far-future alarm is re-checked periodically). It subscribes to
  the `"notifications"` topic and re-arms whenever a create/snooze/dismiss could
  have moved the next moment earlier. On wake it calls `Notifications.fire_due/0`,
  which flips due rows to `fired` and broadcasts `{:notification_fired, _}`.

  Modeled on the other supervised pumps (`WalletPoller`, `Orchestration.Uptime`):
  config-gated in `application.ex`, off in tests (the suite drives `fire_due/1`
  and `tick_now/1` directly), and crash-safe — a bad tick is logged, never fatal.
  """

  use GenServer

  require Logger

  alias BusterClaw.Notifications

  # Never sleep longer than this between due-checks.
  @max_idle_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Force an immediate due-check (tests / manual nudge)."
  def tick_now(server \\ __MODULE__), do: send(server, :tick)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: Notifications.subscribe()

    state = %{
      timer: nil,
      max_idle_ms: Keyword.get(opts, :max_idle_ms, @max_idle_ms)
    }

    {:ok, arm(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    safe(fn -> Notifications.fire_due() end)
    {:noreply, arm(state)}
  end

  # A create/snooze/dismiss may have moved the next moment earlier — re-arm.
  def handle_info({:notifications, :changed, _notification}, state), do: {:noreply, arm(state)}

  # Our own fire broadcast; the tick already handled it.
  def handle_info({:notification_fired, _notification}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp arm(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :tick, next_delay(state.max_idle_ms))}
  end

  defp next_delay(max_idle_ms) do
    case Notifications.next_fire_at() do
      nil ->
        max_idle_ms

      fire_at ->
        fire_at
        |> DateTime.diff(DateTime.utc_now(), :millisecond)
        |> max(0)
        |> min(max_idle_ms)
    end
  end

  # One bad row (e.g. a transient DB error) must never take down the pump.
  defp safe(fun) do
    fun.()
  rescue
    error -> Logger.warning("Notifications.Scheduler tick failed: #{Exception.message(error)}")
  end
end
