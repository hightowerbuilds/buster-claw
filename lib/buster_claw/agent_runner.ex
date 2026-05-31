defmodule BusterClaw.AgentRunner do
  @moduledoc """
  Dispatches an `:agent`-type orchestrator task as a headless `claude`/`codex`
  run, supervised under the orchestration runner supervisor.

  Modes (`:agent_runner_mode`):
    * `:stub` (default) — simulate a run (write a small output file, mark done).
      Safe for dev/CI; exercises the full dispatch→record→complete loop without
      API calls.
    * `:real` — invoke the configured CLI (`claude -p` / `codex exec`) in the
      workspace, capturing output. Timeout/heartbeat are Phase 2.
  """
  require Logger

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Orchestration

  @runner_supervisor BusterClaw.Orchestration.RunnerSupervisor

  @doc "Start a headless agent run for `task`; reports completion to Orchestration."
  def start(task, shift) do
    Task.Supervisor.start_child(@runner_supervisor, fn -> run(task, shift) end)
  end

  defp run(task, shift) do
    engine = engine(task)
    {:ok, agent_run} = Orchestration.create_run(%{task_id: task.id, engine: engine, status: "running"})
    output_path = output_path(task, agent_run)

    case execute(task, engine, output_path) do
      {:ok, code} ->
        Orchestration.update_run(agent_run, %{
          status: "done",
          exit_code: code,
          output_path: output_path,
          finished_at: now()
        })

        Orchestration.complete_task(task, output_path)
        Orchestration.bump_shift(shift, :done)

      {:error, code, reason} ->
        Orchestration.update_run(agent_run, %{
          status: "failed",
          exit_code: code,
          output_path: output_path,
          error: format(reason),
          finished_at: now()
        })

        Orchestration.fail_task(task, format(reason))
        Orchestration.bump_shift(shift, :failed)
    end
  rescue
    error ->
      Logger.error("Agent task #{task.id} crashed: #{Exception.message(error)}")
      Orchestration.fail_task(task, Exception.message(error))
      Orchestration.bump_shift(shift, :failed)
  end

  # --- execution ------------------------------------------------------------

  defp execute(task, engine, output_path) do
    case mode() do
      :stub -> stub_execute(task, engine, output_path)
      :real -> real_execute(task, engine, output_path)
    end
  end

  defp stub_execute(task, engine, output_path) do
    body = """
    [stub agent run]
    engine: #{engine}
    task: #{task.name}
    prompt:
    #{task.prompt}
    """

    write_output(output_path, body)
    {:ok, 0}
  end

  defp real_execute(task, engine, output_path) do
    [bin | base_args] = engine_command(engine)

    if System.find_executable(bin) do
      args = base_args ++ [task.prompt]
      {output, code} = System.cmd(bin, args, cd: workspace(), stderr_to_stdout: true)
      write_output(output_path, output)
      if code == 0, do: {:ok, 0}, else: {:error, code, "exit #{code}"}
    else
      {:error, nil, "agent binary not found: #{bin}"}
    end
  end

  # --- helpers --------------------------------------------------------------

  defp engine(%{engine: e}) when e in ["claude", "codex"], do: e
  defp engine(_task), do: "claude"

  defp engine_command("codex"), do: Application.get_env(:buster_claw, :agent_runner_codex, ["codex", "exec"])
  defp engine_command(_claude), do: Application.get_env(:buster_claw, :agent_runner_claude, ["claude", "-p"])

  defp mode, do: Application.get_env(:buster_claw, :agent_runner_mode, :stub)

  defp workspace, do: Artifact.workspace_root()

  defp output_path(task, agent_run) do
    date = Date.utc_today() |> Date.to_iso8601()
    dir = Path.join([workspace(), "shift", date])
    File.mkdir_p(dir)
    Path.join(dir, "task-#{task.id}-run-#{agent_run.id}.log")
  end

  defp write_output(path, content) do
    File.mkdir_p(Path.dirname(path))
    File.write(path, content)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
