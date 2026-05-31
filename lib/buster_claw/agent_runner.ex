defmodule BusterClaw.AgentRunner do
  @moduledoc """
  Dispatches an `:agent`-type orchestrator task as a headless `claude`/`codex`
  run, supervised under the orchestration runner supervisor.

  Modes (`:agent_runner_mode`):
    * `:stub` (default) — simulate a run (write a small output file, mark done).
      Safe for dev/CI; exercises the full dispatch→record→complete loop without
      API calls.
    * `:real` — invoke the configured CLI (`claude -p` / `codex exec`) in the
      workspace via a `Port`. The run is bounded by a hard timeout, emits
      periodic heartbeats, streams output to the log, and is killed (TERM→KILL)
      if it overruns.
  """
  require Logger

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Orchestration

  @runner_supervisor BusterClaw.Orchestration.RunnerSupervisor

  # Grace period between SIGTERM and SIGKILL when force-killing a timed-out run.
  @kill_grace_ms 2_000

  @doc "Start a headless agent run for `task`; reports completion to Orchestration."
  def start(task, shift) do
    Task.Supervisor.start_child(@runner_supervisor, fn -> run(task, shift) end)
  end

  defp run(task, shift) do
    engine = engine(task)

    {:ok, agent_run} =
      Orchestration.create_run(%{task_id: task.id, engine: engine, status: "running"})

    output_path = output_path(task, agent_run)

    case execute(task, engine, output_path, agent_run) do
      {:ok, code} ->
        Orchestration.update_run(agent_run, %{
          status: "done",
          exit_code: code,
          output_path: output_path,
          finished_at: now()
        })

        Orchestration.complete_task(task, output_path)
        Orchestration.bump_shift(shift, :done)

      {:timeout, reason} ->
        Orchestration.update_run(agent_run, %{
          status: "timeout",
          output_path: output_path,
          error: format(reason),
          finished_at: now()
        })

        Orchestration.fail_task(task, format(reason))
        Orchestration.bump_shift(shift, :failed)

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

  defp execute(task, engine, output_path, agent_run) do
    case mode() do
      :stub -> stub_execute(task, engine, output_path)
      :real -> real_execute(task, engine, output_path, agent_run)
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

  # Port-based real execution: spawns the CLI, streams output to `output_path`,
  # emits heartbeats on a fixed cadence, and enforces a hard wall-clock timeout.
  defp real_execute(task, engine, output_path, agent_run) do
    [bin | base_args] = engine_command(engine)

    case System.find_executable(bin) do
      nil ->
        {:error, nil, "agent binary not found: #{bin}"}

      exe ->
        args = base_args ++ [task.prompt]
        # Start fresh so streamed appends don't accumulate across reruns.
        File.mkdir_p(Path.dirname(output_path))
        File.write(output_path, "")

        port =
          Port.open(
            {:spawn_executable, exe},
            [:binary, :exit_status, {:args, args}, {:cd, workspace()}, :stderr_to_stdout]
          )

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        if os_pid, do: Orchestration.update_run(agent_run, %{os_pid: os_pid})

        deadline = System.monotonic_time(:millisecond) + timeout_ms()
        loop(port, os_pid, agent_run, output_path, deadline)
    end
  end

  # Drives the port to completion. Uses `receive ... after heartbeat_ms` so we
  # wake up at least once per heartbeat interval to emit a heartbeat and to
  # re-check the wall-clock deadline regardless of output activity.
  defp loop(port, os_pid, agent_run, output_path, deadline) do
    wait = receive_window(deadline)

    receive do
      {^port, {:data, chunk}} ->
        File.write(output_path, chunk, [:append])
        loop(port, os_pid, agent_run, output_path, deadline)

      {^port, {:exit_status, 0}} ->
        {:ok, 0}

      {^port, {:exit_status, code}} ->
        {:error, code, "exit #{code}"}
    after
      wait ->
        if past_deadline?(deadline) do
          force_kill(port, os_pid)
          {:timeout, "agent run exceeded #{timeout_ms()}ms timeout"}
        else
          Orchestration.heartbeat_run(agent_run)
          loop(port, os_pid, agent_run, output_path, deadline)
        end
    end
  end

  # Wake at the next heartbeat tick, but never sleep past the deadline.
  defp receive_window(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    min(heartbeat_ms(), max(remaining, 0))
  end

  defp past_deadline?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  # TERM, brief grace, then KILL. Then close the port so we stop receiving.
  defp force_kill(port, os_pid) do
    if os_pid do
      _ = System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
      drain_until_exit(port, @kill_grace_ms)
      _ = System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
    end

    safe_close(port)
  end

  # Give a TERMed process a moment to exit cleanly; swallow any final messages.
  defp drain_until_exit(port, grace_ms) do
    receive do
      {^port, {:exit_status, _code}} -> :ok
      {^port, {:data, _chunk}} -> drain_until_exit(port, grace_ms)
    after
      grace_ms -> :ok
    end
  end

  defp safe_close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # --- helpers --------------------------------------------------------------

  defp engine(%{engine: e}) when e in ["claude", "codex"], do: e
  defp engine(_task), do: "claude"

  defp engine_command("codex"),
    do: Application.get_env(:buster_claw, :agent_runner_codex, ["codex", "exec"])

  defp engine_command(_claude),
    do: Application.get_env(:buster_claw, :agent_runner_claude, ["claude", "-p"])

  defp mode, do: Application.get_env(:buster_claw, :agent_runner_mode, :stub)

  defp timeout_ms, do: Application.get_env(:buster_claw, :agent_run_timeout_ms, 600_000)
  defp heartbeat_ms, do: Application.get_env(:buster_claw, :agent_heartbeat_interval_ms, 30_000)

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
