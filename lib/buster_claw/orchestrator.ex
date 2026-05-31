defmodule BusterClaw.Orchestrator do
  @moduledoc """
  The deterministic brain of the unattended shift. A supervised ticker that, when
  a shift is active, reclaims expired leases, selects due `orchestrator_tasks`,
  claims them, and dispatches: `:pipeline` → existing Elixir workers, `:agent` →
  headless `claude`/`codex` runs. Idles when no shift is active.

  This — not an LLM — is what must stay up for 12h; OTP restarts it on crash,
  and all work state lives durably in `Orchestration` so a restart resumes.
  """
  use GenServer

  import Ecto.Query

  require Logger

  alias BusterClaw.{AgentRunner, Orchestration, Repo, Sentinel}
  alias BusterClaw.Orchestration.{AgentRun, Pipeline}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Force an immediate tick (tests / manual nudge)."
  def tick_now(server \\ __MODULE__), do: send(server, :tick)

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, configured(:orchestrator_tick_ms, 30_000)),
      max_concurrent:
        Keyword.get(opts, :max_concurrent, configured(:orchestrator_max_concurrent, 3)),
      max_consecutive_failures:
        Keyword.get(
          opts,
          :max_consecutive_failures,
          configured(:orchestrator_max_consecutive_failures, 5)
        ),
      max_runs_per_hour:
        Keyword.get(opts, :max_runs_per_hour, configured(:orchestrator_max_runs_per_hour, 120)),
      owner: owner_id(),
      autostart: Keyword.get(opts, :autostart, true),
      consecutive_failures: 0
    }

    if state.autostart, do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = record_tick(state, safe_tick(state))
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

  defp safe_tick(state) do
    run_tick(state)
    :ok
  rescue
    error ->
      Logger.error("Orchestrator tick failed: #{Exception.message(error)}")
      :error
  end

  defp run_tick(state) do
    case Orchestration.active_shift() do
      nil -> :idle
      shift -> run_shift_tick(shift, state)
    end
  end

  defp run_shift_tick(shift, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    cond do
      Orchestration.kill_switch_engaged?() ->
        Orchestration.stop_shift("kill switch")

        Sentinel.observe(:security_block, "Shift stopped by kill switch (STOP file)", %{
          shift_id: shift.id
        })

      DateTime.compare(now, shift.ends_at) != :lt ->
        Orchestration.complete_shift(shift, "window elapsed")

      true ->
        dispatch_due(shift, state, now)
    end
  end

  defp dispatch_due(shift, state, now) do
    Orchestration.ensure_next_runs(now)
    Orchestration.reclaim_expired(now)

    if rate_capped?(state, now) do
      :rate_capped
    else
      dispatch_within_capacity(shift, state, now)
    end
  end

  defp dispatch_within_capacity(shift, state, now) do
    capacity = state.max_concurrent - length(Orchestration.list_active_runs())

    if capacity > 0 do
      now
      |> Orchestration.list_due_tasks()
      |> Enum.reduce_while(capacity, fn task, remaining ->
        if remaining <= 0 do
          {:halt, remaining}
        else
          dispatch(task, shift, state)
          {:cont, remaining - 1}
        end
      end)
    end
  end

  # Hourly throughput brake: count agent_runs started in the trailing hour. When
  # at/over the cap we skip dispatch for this tick (a transient brake, not a
  # shift stop) and surface a notice so the operator can see the throttle.
  defp rate_capped?(state, now) do
    started = runs_in_last_hour(now)

    if started >= state.max_runs_per_hour do
      Sentinel.observe(
        :command_invoke,
        "Orchestrator dispatch rate-capped: #{started} runs in the last hour (cap #{state.max_runs_per_hour})",
        %{runs_last_hour: started, cap: state.max_runs_per_hour},
        severity: :warning
      )

      true
    else
      false
    end
  end

  defp runs_in_last_hour(now) do
    one_hour_ago = DateTime.add(now, -3600, :second)

    Repo.aggregate(
      from(r in AgentRun, where: r.started_at >= ^one_hour_ago),
      :count,
      :id
    )
  end

  defp dispatch(task, shift, state) do
    case Orchestration.claim_task(task, state.owner) do
      {:ok, claimed} ->
        Orchestration.mark_running(claimed)
        Orchestration.bump_shift(shift, :dispatched)

        Sentinel.observe(:command_invoke, "Dispatched #{claimed.type} task: #{claimed.name}", %{
          task_id: claimed.id,
          type: claimed.type,
          engine: claimed.engine
        })

        case claimed.type do
          "agent" -> AgentRunner.start(claimed, shift)
          "pipeline" -> Pipeline.start(claimed, shift)
        end

      {:error, :not_claimable} ->
        :ok
    end
  end

  defp owner_id, do: "#{node()}/#{System.pid()}"

  defp configured(key, default), do: Application.get_env(:buster_claw, key, default)
end
