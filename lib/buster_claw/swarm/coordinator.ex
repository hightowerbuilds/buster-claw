defmodule BusterClaw.Swarm.Coordinator do
  @moduledoc """
  The Phase 4 **coordinator** — turns one unit of work into a parallel `Swarm` plan.

  Per S0.4 the coordinator is a *serial* planner pass followed by a bounded fan-out:

      coordinate/2  =  plan/2 (one AgentRunner run, serial)  →  Swarm.run/2

  `plan/2` runs a single headless agent that decomposes the goal into a JSON array
  of role-typed sub-tasks (`[{"role": .., "prompt": ..}]`), which is parsed,
  validated, and capped at `:swarm_max_subtasks`. The plan then runs through the
  unchanged Phase-4 `Swarm` mechanism (bounded concurrency, per-sub-run timeout,
  typed results, quorum fan-in, per-sub-run Sentinel provenance).

  Both the planner and the sub-runs default to `AgentRunner.run/2` but are
  independently injectable (`:planner_runner` / `:runner`) so tests never spawn a
  real agent. The planner emitting an unparseable or empty plan is `:unplannable`
  — the caller (Dispatcher) blocks the item rather than guessing.
  """
  require Logger

  alias BusterClaw.Swarm

  @type subtask :: %{role: String.t(), prompt: String.t()}

  @doc """
  Plan `goal` into sub-tasks, then run them as a quorum swarm.

  Options are passed through to `Swarm.run/2` (`:max_concurrency`, `:quorum`,
  `:timeout_ms`, `:runner`, `:run_opts`, `:swarm_id`) plus coordinator-only keys:
  `:planner_runner` (the serial planner; default `AgentRunner.run/2`),
  `:planner_run_opts`, and `:max_subtasks`.
  """
  @spec coordinate(String.t(), keyword()) ::
          {:ok, map()}
          | {:error, {:quorum_not_met, map()} | :unplannable | :empty_plan | term()}
  def coordinate(goal, opts \\ []) when is_binary(goal) do
    with {:ok, plan} <- plan(goal, opts) do
      Swarm.run(plan, opts)
    end
  end

  @doc """
  Run the serial planner and return a validated `[%{role, prompt}]` plan, or
  `{:error, :unplannable}` when the planner fails or emits nothing parseable.
  """
  @spec plan(String.t(), keyword()) :: {:ok, [subtask]} | {:error, :unplannable | term()}
  def plan(goal, opts \\ []) when is_binary(goal) do
    runner = Keyword.get(opts, :planner_runner, &BusterClaw.AgentRunner.run/2)
    run_opts = Keyword.get(opts, :planner_run_opts, Keyword.get(opts, :run_opts, []))
    max = Keyword.get(opts, :max_subtasks, config(:swarm_max_subtasks, 6))

    case runner.(planner_prompt(goal, max), run_opts) do
      {:ok, %{exit_status: 0, output: output}} -> parse_plan(output, max)
      {:ok, %{exit_status: status}} -> {:error, {:planner_failed, status}}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unplannable}
    end
  end

  # Extract the plan from the planner's stdout. The agent is told to emit ONLY the
  # JSON array, but real models wrap it in prose/fences, so we scan for the last
  # balanced top-level `[...]` and decode that. Anything not a non-empty list of
  # {role, prompt} string pairs is `:unplannable` (fail-closed, not a guessed plan).
  defp parse_plan(output, max) when is_binary(output) do
    with {:ok, json} <- extract_array(output),
         {:ok, list} when is_list(list) <- Jason.decode(json),
         subtasks when subtasks != [] <- normalize(list) do
      {:ok, Enum.take(subtasks, max)}
    else
      _ -> {:error, :unplannable}
    end
  end

  defp parse_plan(_output, _max), do: {:error, :unplannable}

  # Find the last top-level JSON array in the text by scanning bracket depth, so a
  # `[` inside a string value doesn't desync us against a leading prose `[`.
  defp extract_array(text) do
    graphemes = String.to_charlist(text)

    case scan_array(graphemes, [], 0, false, false, nil) do
      nil -> :error
      chars -> {:ok, List.to_string(chars)}
    end
  end

  # depth: bracket nesting; in_str/esc: inside a JSON string / escape; acc: chars of
  # the current top-level array (reversed). Returns the LAST complete array found.
  defp scan_array([], _acc, _depth, _in_str, _esc, last), do: last

  defp scan_array([c | rest], acc, depth, in_str, esc, last) do
    cond do
      esc -> scan_array(rest, [c | acc], depth, in_str, false, last)
      in_str and c == ?\\ -> scan_array(rest, [c | acc], depth, in_str, true, last)
      c == ?" -> scan_array(rest, [c | acc], depth, not in_str, false, last)
      in_str -> scan_array(rest, [c | acc], depth, in_str, false, last)
      c == ?[ and depth == 0 -> scan_array(rest, [c], 1, false, false, last)
      c == ?[ -> scan_array(rest, [c | acc], depth + 1, false, false, last)
      c == ?] and depth == 1 -> scan_array(rest, [], 0, false, false, Enum.reverse([c | acc]))
      c == ?] -> scan_array(rest, [c | acc], depth - 1, false, false, last)
      depth > 0 -> scan_array(rest, [c | acc], depth, false, false, last)
      true -> scan_array(rest, acc, depth, false, false, last)
    end
  end

  defp normalize(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} ->
      case entry do
        %{"prompt" => prompt} when is_binary(prompt) ->
          if String.trim(prompt) == "",
            do: [],
            else: [%{role: role(entry, index), prompt: prompt}]

        _ ->
          []
      end
    end)
  end

  defp role(%{"role" => role}, _index) when is_binary(role) and role != "", do: role
  defp role(_entry, index), do: "worker-#{index}"

  defp planner_prompt(goal, max) do
    """
    You are the planning coordinator for an unattended Buster Claw run. Decompose
    the goal below into at most #{max} INDEPENDENT sub-tasks that can run in
    parallel — each handled by its own agent that has the same ./buster-claw CLI
    you do. Split by distinct sub-goal (e.g. research vs. draft vs. verify), not by
    arbitrary slicing; if the goal is atomic, return a single sub-task.

    Output ONLY a JSON array, nothing else, in this exact shape:

        [{"role": "short-role-name", "prompt": "full instructions for this agent"}]

    Each "prompt" must be self-contained (the sub-agent does not see this goal or
    the other sub-tasks). Do not wrap the array in markdown fences or prose.

    GOAL:
    #{goal}
    """
  end

  defp config(key, default), do: Application.get_env(:buster_claw, key, default)
end
