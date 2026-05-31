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

  require Logger

  alias BusterClaw.{AgentRunner, Orchestration, Sentinel}
  alias BusterClaw.Orchestration.Pipeline

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Force an immediate tick (tests / manual nudge)."
  def tick_now(server \\ __MODULE__), do: send(server, :tick)

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, configured(:orchestrator_tick_ms, 30_000)),
      max_concurrent: Keyword.get(opts, :max_concurrent, configured(:orchestrator_max_concurrent, 3)),
      owner: owner_id(),
      autostart: Keyword.get(opts, :autostart, true)
    }

    if state.autostart, do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    safe_tick(state)
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  defp safe_tick(state) do
    run_tick(state)
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
