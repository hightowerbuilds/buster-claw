defmodule BusterClaw.Swarm do
  @moduledoc """
  Bounded parallel fan-out / fan-in for agent sub-runs (Phase 4).

  Given a `plan` — a list of sub-tasks `%{role, prompt}` (an optional
  `budget_cents` is carried through for accounting) — `run/2` executes the
  sub-runs concurrently under a hard concurrency cap, with a per-sub-run timeout,
  then aggregates by **quorum**:

  - `Task.Supervisor.async_stream_nolink/4` is the engine: `nolink` so a crashing
    sub-run becomes *data* (an `{:exit, _}` result) rather than taking the swarm
    down; `on_timeout: :kill_task` enforces the wall-clock ceiling; `ordered: true`
    keeps results aligned with the plan.
  - Every sub-run — ok, error, timeout, or crash — yields exactly one typed result
    and exactly one `:command_invoke` Sentinel event tagged `{swarm_id, role,
    index}`, so the whole fan-out is on the audit feed and nothing is silently
    dropped.
  - Fan-in is deterministic: `{:ok, summary}` when successes ≥ `quorum`, else
    `{:error, {:quorum_not_met, summary}}`. The summary always carries every
    sub-run result.

  Crash-loop composition (when driven from the Dispatcher): a whole swarm is **one**
  tick, so a flaky sub-role is data, not a tick failure. Only the coordinator dying
  feeds the Orchestrator's brake.
  """
  require Logger

  alias BusterClaw.Sentinel

  @supervisor BusterClaw.SwarmTaskSupervisor

  @type subtask :: %{required(:prompt) => String.t(), optional(:role) => String.t()}
  @type result :: %{
          role: String.t(),
          index: non_neg_integer(),
          status: :ok | :error | :timeout,
          exit_status: integer() | nil,
          result: term()
        }

  @doc """
  Run a plan of sub-tasks in parallel and aggregate by quorum.

  Options: `:max_concurrency` (default config `:swarm_max_concurrency`, 3),
  `:timeout_ms` (per sub-run; default config `:swarm_timeout_ms`, 5 min),
  `:quorum` (successes needed; default a majority), `:runner` (injectable
  `(prompt, opts) -> {:ok, run} | {:error, reason}`; default `AgentRunner.run/2`),
  `:run_opts` (base opts merged into each runner call), `:swarm_id`.
  """
  @spec run([subtask], keyword()) ::
          {:ok, map()} | {:error, {:quorum_not_met, map()}} | {:error, :empty_plan}
  def run(plan, opts \\ [])

  def run([], _opts), do: {:error, :empty_plan}

  def run(plan, opts) when is_list(plan) do
    swarm_id = Keyword.get(opts, :swarm_id) || System.unique_integer([:positive])
    cap = Keyword.get(opts, :max_concurrency, config(:swarm_max_concurrency, 3))
    timeout = Keyword.get(opts, :timeout_ms, config(:swarm_timeout_ms, 300_000))
    runner = Keyword.get(opts, :runner, &BusterClaw.AgentRunner.run/2)
    run_opts = Keyword.get(opts, :run_opts, [])
    quorum = Keyword.get(opts, :quorum, majority(length(plan)))

    results =
      plan
      |> Enum.with_index()
      |> run_stream(runner, [timeout_ms: timeout] ++ run_opts, cap, timeout)
      |> Enum.with_index()
      |> Enum.map(fn {stream_result, index} ->
        classify(stream_result, Enum.at(plan, index), index)
      end)

    Enum.each(results, &audit_subrun(swarm_id, &1))
    aggregate(swarm_id, results, quorum)
  end

  defp run_stream(indexed_plan, runner, run_opts, cap, timeout) do
    Task.Supervisor.async_stream_nolink(
      @supervisor,
      indexed_plan,
      fn {subtask, index} -> run_one(subtask, index, runner, run_opts) end,
      max_concurrency: cap,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.to_list()
  end

  # Execute one sub-run. Returns a typed result map (no side effects — auditing and
  # aggregation happen once, centrally, so timeouts/crashes are covered uniformly).
  defp run_one(subtask, index, runner, run_opts) do
    role = role_of(subtask, index)

    case runner.(subtask.prompt, run_opts) do
      {:ok, %{exit_status: 0} = run} ->
        %{role: role, index: index, status: :ok, exit_status: 0, result: run}

      {:ok, run} ->
        %{
          role: role,
          index: index,
          status: :error,
          exit_status: Map.get(run, :exit_status),
          result: run
        }

      {:error, reason} ->
        %{role: role, index: index, status: :error, exit_status: nil, result: reason}
    end
  end

  # Map an async_stream outcome to a typed result. A killed-on-timeout task is
  # `{:exit, :timeout}`; any other exit is a crashed sub-run — both are data.
  defp classify({:ok, %{} = result}, _subtask, _index), do: result

  defp classify({:exit, :timeout}, subtask, index),
    do: %{
      role: role_of(subtask, index),
      index: index,
      status: :timeout,
      exit_status: nil,
      result: :timeout
    }

  defp classify({:exit, reason}, subtask, index),
    do: %{
      role: role_of(subtask, index),
      index: index,
      status: :error,
      exit_status: nil,
      result: reason
    }

  defp aggregate(swarm_id, results, quorum) do
    ok = Enum.count(results, &(&1.status == :ok))

    summary = %{
      swarm_id: swarm_id,
      total: length(results),
      ok: ok,
      quorum: quorum,
      results: results
    }

    Sentinel.observe(
      :command_invoke,
      "Swarm #{swarm_id} finished: #{ok}/#{length(results)} ok (quorum #{quorum})",
      %{swarm_id: swarm_id, total: length(results), ok: ok, quorum: quorum},
      severity: if(ok >= quorum, do: :info, else: :warning)
    )

    if ok >= quorum, do: {:ok, summary}, else: {:error, {:quorum_not_met, summary}}
  end

  defp audit_subrun(swarm_id, %{role: role, index: index, status: status} = r) do
    Sentinel.observe(
      :command_invoke,
      "Swarm #{swarm_id} sub-run #{role} (#{status})",
      %{
        swarm_id: swarm_id,
        role: role,
        index: index,
        status: status,
        exit_status: r.exit_status
      },
      severity: if(status == :ok, do: :info, else: :warning)
    )
  end

  defp role_of(%{role: role}, _index) when is_binary(role), do: role
  defp role_of(_subtask, index), do: "worker-#{index}"

  defp majority(n), do: div(n, 2) + 1

  defp config(key, default), do: Application.get_env(:buster_claw, key, default)
end
