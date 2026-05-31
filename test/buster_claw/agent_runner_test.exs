defmodule BusterClaw.AgentRunnerTest do
  use BusterClaw.DataCase, async: false

  import Ecto.Query

  alias BusterClaw.{AgentRunner, Orchestration}
  alias BusterClaw.Orchestration.{AgentRun, Task}

  # AgentRunner.start/2 spawns work under a Task.Supervisor (a separate process).
  # `async: false` makes DataCase run the sandbox in shared mode, so that process
  # uses this test's connection. We monitor the returned pid and await :DOWN so
  # the run fully finishes (all its DB writes) before we assert or tear down.

  defp agent_task(attrs \\ %{}) do
    {:ok, task} =
      Orchestration.create_task(
        Map.merge(
          %{name: "agent t", type: "agent", engine: "claude", prompt: "do a thing"},
          attrs
        )
      )

    task
  end

  defp await_run(pid, timeout_ms \\ 6_000) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout_ms
  end

  defp run_for(task_id, status) do
    AgentRun |> where([r], r.task_id == ^task_id and r.status == ^status) |> Repo.one()
  end

  describe "stub mode" do
    test "completes a task and records a done run" do
      Application.put_env(:buster_claw, :agent_runner_mode, :stub)

      {:ok, shift} = Orchestration.start_shift()
      task = agent_task()

      {:ok, pid} = AgentRunner.start(task, shift)
      await_run(pid)

      run = run_for(task.id, "done")
      assert run, "expected a done agent_run for task #{task.id}"
      assert run.exit_code == 0
      assert run.output_path && File.exists?(run.output_path)
      assert Repo.get!(Task, task.id).state == "done"
    end
  end

  # Environment-dependent: needs `sleep` + `kill` on PATH (true on macOS/Linux).
  # Uses :real mode with `sleep` as the "agent binary" and a tiny timeout so the
  # run is force-killed. Self-skips if `sleep` isn't available.
  describe "real mode timeout" do
    test "kills an overrunning run and records a timeout" do
      if System.find_executable("sleep") do
        Application.put_env(:buster_claw, :agent_runner_mode, :real)
        Application.put_env(:buster_claw, :agent_runner_claude, ["sleep"])
        Application.put_env(:buster_claw, :agent_run_timeout_ms, 200)
        Application.put_env(:buster_claw, :agent_heartbeat_interval_ms, 50)

        on_exit(fn ->
          Application.put_env(:buster_claw, :agent_runner_mode, :stub)
          Application.put_env(:buster_claw, :agent_runner_claude, ["claude", "-p"])
          Application.put_env(:buster_claw, :agent_run_timeout_ms, 600_000)
          Application.put_env(:buster_claw, :agent_heartbeat_interval_ms, 30_000)
        end)

        {:ok, shift} = Orchestration.start_shift()
        task = agent_task(%{prompt: "10"})

        {:ok, pid} = AgentRunner.start(task, shift)
        await_run(pid)

        run = run_for(task.id, "timeout")
        assert run, "expected a timeout agent_run for task #{task.id}"
        assert run.error =~ "timeout"
        assert Repo.get!(Task, task.id).state in ["pending", "failed"]
      else
        assert true
      end
    end
  end
end
