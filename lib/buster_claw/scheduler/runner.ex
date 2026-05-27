defmodule BusterClaw.Scheduler.Runner do
  @moduledoc "Supervised ticker that runs due scheduler jobs."

  use GenServer

  require Logger

  alias BusterClaw.Scheduler

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, configured_interval_ms()),
      autostart: Keyword.get(opts, :autostart, true)
    }

    if state.autostart, do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_tick()
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  defp run_tick do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Scheduler.ensure_next_runs(now)
    Scheduler.run_due(now)
  rescue
    error ->
      Logger.error("Scheduler tick failed: #{Exception.message(error)}")
      []
  end

  defp schedule_tick(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp configured_interval_ms do
    Application.get_env(:buster_claw, :scheduler_tick_ms, 60_000)
  end
end
