defmodule BusterClaw.OrchestratorTest do
  # async: false — these drive a GenServer that talks to the shared sandbox.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Orchestrator, Orchestration}
  alias BusterClaw.Orchestration.AgentRun

  # `async: false` → DataCase runs the sandbox in shared mode, so the Orchestrator
  # GenServer (a separate process) uses this test's connection.

  defp agent_task(attrs \\ %{}) do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    {:ok, task} =
      Orchestration.create_task(
        Map.merge(
          %{name: "rate t", type: "agent", engine: "claude", prompt: "x", due_at: past},
          attrs
        )
      )

    task
  end

  defp insert_runs(n) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for _ <- 1..n do
      {:ok, _} =
        Orchestration.create_run(%{engine: "claude", status: "done", started_at: now})
    end
  end

  # Run one tick synchronously inside an autostart:false server, then read state.
  defp start_orchestrator(opts) do
    name = :"orch_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised(
        {Orchestrator, [{:name, name}, {:autostart, false}, {:interval_ms, 60_000} | opts]}
      )

    %{pid: pid, name: name}
  end

  defp tick_sync(name) do
    Orchestrator.tick_now(name)
    # Force a synchronous round-trip so the async :tick is processed first.
    _ = :sys.get_state(name)
    :ok
  end

  describe "rate cap" do
    test "skips dispatch when runs in the last hour are at/over the cap" do
      Application.put_env(:buster_claw, :agent_runner_mode, :stub)
      on_exit(fn -> Application.put_env(:buster_claw, :agent_runner_mode, :stub) end)

      {:ok, _shift} = Orchestration.start_shift()
      _task = agent_task()

      # Saturate the trailing-hour window.
      insert_runs(3)

      %{name: name} = start_orchestrator(max_runs_per_hour: 3, max_concurrent: 5)

      tick_sync(name)

      # The due task should NOT have been claimed/dispatched (still pending),
      # and no new "running" run was created for it.
      task = Orchestration.list_tasks() |> List.first()
      assert task.state == "pending"
      assert Repo.aggregate(where(AgentRun, [r], r.status == "running"), :count, :id) == 0
    end

    test "dispatches when under the cap" do
      Application.put_env(:buster_claw, :agent_runner_mode, :stub)
      on_exit(fn -> Application.put_env(:buster_claw, :agent_runner_mode, :stub) end)

      {:ok, _shift} = Orchestration.start_shift()
      _task = agent_task()

      %{name: name} = start_orchestrator(max_runs_per_hour: 100, max_concurrent: 5)

      tick_sync(name)

      # Task was claimed and marked running (dispatch happened). The stub run may
      # already have completed, so assert the task left the pending pool.
      task = Orchestration.list_tasks() |> List.first()
      refute task.state == "pending"
    end
  end

  describe "crash-loop brake" do
    # Healthy ticks must never accumulate failures (the :ok path of record_tick).
    # The failure-trip path (stop shift after N raised ticks) needs an injectable
    # failure seam to test without fighting the Ecto sandbox — tracked as a
    # follow-up in daily-growth/roadmaps/05-31-26-orchestration-followups.md.
    test "healthy ticks keep the consecutive-failure counter at zero" do
      {:ok, _shift} = Orchestration.start_shift()
      %{name: name} = start_orchestrator(max_consecutive_failures: 3)

      tick_sync(name)
      tick_sync(name)
      assert :sys.get_state(name).consecutive_failures == 0
    end
  end
end
