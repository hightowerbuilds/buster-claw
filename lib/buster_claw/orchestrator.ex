defmodule BusterClaw.Orchestrator do
  @moduledoc """
  Kill-switch watcher for the active shift. A supervised ticker that, when a
  shift is active, stops it if the kill switch (STOP file) is engaged. A shift
  runs until it is stopped — there is no fixed window.

  It no longer dispatches headless `claude`/`codex` runs — work is now pulled by
  a human-run Claude Code session through the Dispatch queue. This — not an LLM —
  is what stays up for the shift; OTP restarts it on crash, and all work state
  lives durably in `Orchestration` so a restart resumes.
  """
  use GenServer

  require Logger

  alias BusterClaw.{Orchestration, Sentinel}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Force an immediate tick (tests / manual nudge)."
  def tick_now(server \\ __MODULE__), do: send(server, :tick)

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, configured(:orchestrator_tick_ms, 30_000)),
      max_consecutive_failures:
        Keyword.get(
          opts,
          :max_consecutive_failures,
          configured(:orchestrator_max_consecutive_failures, 5)
        ),
      autostart: Keyword.get(opts, :autostart, true),
      consecutive_failures: 0
    }

    if state.autostart, do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = record_tick(state, safe_tick())
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  # Update the crash-loop counter from a tick's pass/fail result. A failure is a
  # tick whose body raised (rescued in `safe_tick`). On reaching the threshold we
  # stop the shift, raise a critical Sentinel event, and reset the counter so the
  # operator can restart cleanly.
  defp record_tick(state, :ok), do: %{state | consecutive_failures: 0}

  defp record_tick(state, :error) do
    failures = state.consecutive_failures + 1

    if failures >= state.max_consecutive_failures do
      trip_crash_loop(failures, state)
      %{state | consecutive_failures: 0}
    else
      %{state | consecutive_failures: failures}
    end
  end

  # The brake itself must not crash the ticker (the very thing OTP keeps alive),
  # so its side-effects are isolated — a failure here just logs.
  defp trip_crash_loop(failures, state) do
    Logger.error(
      "Orchestrator hit #{failures} consecutive tick failures; stopping shift (crash loop)"
    )

    Orchestration.stop_shift("crash loop")

    Sentinel.observe(
      :security_block,
      "Shift stopped: orchestrator crash loop (#{failures} consecutive tick failures)",
      %{consecutive_failures: failures, threshold: state.max_consecutive_failures}
    )

    :ok
  rescue
    error ->
      Logger.error(
        "Orchestrator crash-loop brake failed to stop shift: #{Exception.message(error)}"
      )

      :error
  end

  defp safe_tick do
    run_tick()
    :ok
  rescue
    error ->
      Logger.error("Orchestrator tick failed: #{Exception.message(error)}")
      :error
  end

  defp run_tick do
    case Orchestration.active_shift() do
      nil -> :idle
      shift -> run_shift_tick(shift)
    end
  end

  defp run_shift_tick(shift) do
    if Orchestration.kill_switch_engaged?() do
      Orchestration.stop_shift("kill switch")

      Sentinel.observe(:security_block, "Shift stopped by kill switch (STOP file)", %{
        shift_id: shift.id
      })
    else
      :ok
    end
  end

  defp configured(key, default), do: Application.get_env(:buster_claw, key, default)
end
