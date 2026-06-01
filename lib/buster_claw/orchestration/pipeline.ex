defmodule BusterClaw.Orchestration.Pipeline do
  @moduledoc """
  Runs `:pipeline`-type orchestrator tasks via existing Elixir workers (no agent).
  Dispatched async under the orchestration runner supervisor; reports the outcome
  back to the `Orchestration` context.
  """
  require Logger

  alias BusterClaw.Orchestration

  @runner_supervisor BusterClaw.Orchestration.RunnerSupervisor

  @doc "Start a pipeline task asynchronously; reports completion to Orchestration."
  def start(task, shift) do
    Task.Supervisor.start_child(@runner_supervisor, fn -> run(task, shift) end)
  end

  defp run(task, shift) do
    case execute(task.command, task.params || %{}) do
      {:ok, summary} ->
        Orchestration.complete_task(task, summary)
        Orchestration.bump_shift(shift, :done)

      {:error, reason} ->
        Orchestration.fail_task(task, format(reason))
        Orchestration.bump_shift(shift, :failed)
    end
  rescue
    error ->
      Logger.error("Pipeline task #{task.id} crashed: #{Exception.message(error)}")
      Orchestration.fail_task(task, Exception.message(error))
      Orchestration.bump_shift(shift, :failed)
  end

  # Known deterministic commands. Extend as more pipeline work is added.
  defp execute("noop", _params), do: {:ok, "noop"}

  defp execute(command, _params) when is_binary(command),
    do: {:error, {:unknown_command, command}}

  defp execute(_command, _params), do: {:error, :missing_command}

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
