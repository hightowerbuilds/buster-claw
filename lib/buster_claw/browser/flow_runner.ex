defmodule BusterClaw.Browser.FlowRunner do
  @moduledoc """
  Executes a declarative browser flow: an ordered list of step maps, each
  `%{"action" => ..., ...that command's args}`, against the live-tab command
  primitives.

  Halts at the first failing step. A `wait` that never matched and an `assert`
  that didn't pass are step failures — that is what they are in a flow for. On
  failure a best-effort screenshot is attached when a desktop shell is
  attached; a screenshot problem never masks the step failure.

  Calls the LOCAL `BusterClaw.Commands.Web` functions, never
  `Commands.call/3`: the flow was policy-checked and audited once at the choke
  point, and re-entering per step would re-audit and double rate-limit. The
  primitives' own Sentinel events still fire per step, so the feed shows each
  act individually.
  """

  alias BusterClaw.Browser.Bridge
  alias BusterClaw.Commands.Web

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

  Options (tests): `exec:` replaces the per-step executor
  (`fn action, args -> result end`); `screenshot:` replaces the failure
  screenshot (`fn -> map | nil end`).
  """
  def run(steps, opts \\ [])

  def run(steps, opts) when is_list(steps) do
    with :ok <- validate(steps) do
      exec = Keyword.get(opts, :exec, &execute/2)
      screenshot = Keyword.get(opts, :screenshot, &failure_screenshot/0)

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

  defp validate([]), do: {:error, :empty_flow}

  defp validate(steps) when length(steps) > @max_steps,
    do: {:error, {:too_many_steps, length(steps)}}

  defp validate(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.find_value(:ok, fn
      {%{"action" => action}, _index} when action in @actions -> nil
      {%{"action" => action}, index} -> {:error, {:bad_step, index, {:unknown_action, action}}}
      {step, index} when is_map(step) -> {:error, {:bad_step, index, :missing_action}}
      {_step, index} -> {:error, {:bad_step, index, :not_a_map}}
    end)
  end

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

  defp execute("navigate", args), do: Web.browser_navigate(args)
  defp execute("wait", args), do: Web.browser_wait(args)
  defp execute("click", args), do: Web.browser_click(args)
  defp execute("fill", args), do: Web.browser_fill(args)
  defp execute("extract", args), do: Web.browser_extract(args)
  defp execute("assert", args), do: Web.browser_assert(args)
  defp execute("find_elements", args), do: Web.browser_find_elements(args)

  # Only worth attempting when a desktop shell is attached — without one the
  # capture would just burn its timeout on an already-failed flow.
  defp failure_screenshot do
    with true <- Bridge.available?(),
         {:ok, shot} <- Web.browser_screenshot() do
      Map.take(shot, [:path, :url])
    else
      _ -> nil
    end
  end
end
