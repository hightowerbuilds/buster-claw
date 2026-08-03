defmodule BusterClaw.Browser.FlowRunner do
  @moduledoc """
  Executes a declarative browser flow: an ordered list of step maps, each
  `%{"action" => ..., ...that command's args}`, against the live-tab command
  primitives.

  Halts at the first failing step. A `wait` that never matched and an `assert`
  that didn't pass are step failures — that is what they are in a flow for. On
  failure a best-effort screenshot is attached when a desktop shell is
  attached; a screenshot problem never masks the step failure.

  Owns the flow CONTRACT — validation, ordering, halt-on-failure, the report
  shape — and none of the execution. Every caller injects `exec:` (and
  `screenshot:`): `Commands.Web` passes the live-tab primitives,
  `BackgroundFlow` passes a headless CDP session. Until 08-02 the live-tab
  executor lived here as a default, which made this module call back into
  `Commands.Web` while `Commands.Web` called it — a dependency cycle for the
  sake of a default argument.
  """

  @max_steps 25
  @actions ~w(navigate wait click fill extract assert find_elements)
  # A whole-page extract can be 200k chars; the flow report keeps the data but
  # caps bodies so the result (and its audit row) stays bounded.
  @detail_text_cap 20_000

  def actions, do: @actions
  def max_steps, do: @max_steps

  @doc """
  Validate and run a flow. Returns `{:ok, %{status: "passed" | "failed",
  steps: [per-step reports], failed_step: nil | n, screenshot: map | nil}}`,
  or `{:error, reason}` for a flow that is invalid before any step runs.

  Options: `exec:` (REQUIRED) is the per-step executor
  (`fn action, args -> result end`); `screenshot:` replaces the failure
  screenshot (`fn -> map | nil end`, default none).
  """
  def run(steps, opts \\ [])

  def run(steps, opts) when is_list(steps) do
    with :ok <- validate(steps) do
      exec = Keyword.fetch!(opts, :exec)
      screenshot = Keyword.get(opts, :screenshot, fn -> nil end)

      results = run_steps(steps, exec)
      failed = Enum.find(results, &(&1.status == "failed"))

      report = %{
        status: if(failed, do: "failed", else: "passed"),
        steps: results,
        failed_step: failed && failed.step
      }

      {:ok, if(failed, do: Map.put(report, :screenshot, screenshot.()), else: report)}
    end
  end

  def run(_steps, _opts), do: {:error, :steps_must_be_a_list}

  @doc """
  Validate a step list without running it — `:ok` or the same typed errors
  `run/2` would return. Used by saved checks to refuse a bad definition at
  save time rather than at 2am when the check runs.
  """
  def validate(steps)

  def validate([]), do: {:error, :empty_flow}

  def validate(steps) when length(steps) > @max_steps,
    do: {:error, {:too_many_steps, length(steps)}}

  def validate(steps) when is_list(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.find_value(:ok, fn
      {%{"action" => action}, _index} when action in @actions -> nil
      {%{"action" => action}, index} -> {:error, {:bad_step, index, {:unknown_action, action}}}
      {step, index} when is_map(step) -> {:error, {:bad_step, index, :missing_action}}
      {_step, index} -> {:error, {:bad_step, index, :not_a_map}}
    end)
  end

  def validate(_steps), do: {:error, :steps_must_be_a_list}

  defp run_steps(steps, exec) do
    steps
    |> Enum.with_index(1)
    |> Enum.reduce_while([], fn {%{"action" => action} = step, index}, acc ->
      args = Map.delete(step, "action")
      started = System.monotonic_time(:millisecond)
      {status, detail} = classify(action, exec.(action, args))

      result = %{
        step: index,
        action: action,
        status: status,
        ms: System.monotonic_time(:millisecond) - started,
        detail: detail
      }

      if status == "failed", do: {:halt, [result | acc]}, else: {:cont, [result | acc]}
    end)
    |> Enum.reverse()
  end

  defp classify("wait", {:ok, %{matched: false} = data}), do: {"failed", data}
  defp classify("assert", {:ok, %{passed: false} = data}), do: {"failed", data}
  defp classify(_action, {:ok, data}), do: {"passed", compact(data)}
  defp classify(_action, {:error, reason}), do: {"failed", %{error: format_reason(reason)}}

  defp compact(%{text: text} = data)
       when is_binary(text) and byte_size(text) > @detail_text_cap do
    data
    |> Map.put(:text, binary_part(text, 0, @detail_text_cap))
    |> Map.put(:text_truncated, true)
  end

  defp compact(data), do: data

  defp format_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
