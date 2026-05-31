defmodule BusterClaw.OrchestrationVitalsTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Orchestration

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp run(attrs) do
    {:ok, run} =
      Orchestration.create_run(Map.merge(%{engine: "claude", status: "running"}, attrs))

    run
  end

  describe "vitals/0 and snapshot/0" do
    test "snapshot includes vitals without dropping the existing keys" do
      snap = Orchestration.snapshot()

      assert Map.has_key?(snap, :shift)
      assert Map.has_key?(snap, :running)
      assert Map.has_key?(snap, :upcoming)
      assert Map.has_key?(snap, :recent)

      assert %{
               running: _,
               max_concurrent: _,
               runs_last_hour: _,
               max_runs_per_hour: _,
               done_today: _,
               failed_today: _
             } = snap.vitals
    end

    test "vitals reflects config-driven caps" do
      v = Orchestration.vitals()

      assert v.max_concurrent ==
               Application.get_env(:buster_claw, :orchestrator_max_concurrent, 3)

      assert v.max_runs_per_hour ==
               Application.get_env(:buster_claw, :orchestrator_max_runs_per_hour, 120)
    end

    test "counts running, hourly rate, and today's outcomes" do
      # Two in-flight runs (also count toward the last hour).
      run(%{status: "running"})
      run(%{status: "running"})

      # Finished outcomes today.
      run(%{status: "done"})
      run(%{status: "failed"})
      run(%{status: "timeout"})
      run(%{status: "killed"})

      # A run started over an hour ago should not count toward runs_last_hour.
      run(%{status: "done", started_at: DateTime.add(now(), -7200, :second)})

      v = Orchestration.vitals()

      assert v.running == 2
      # 6 seeded with started_at defaulting to now; the 7th is 2h old.
      assert v.runs_last_hour == 6
      assert v.done_today == 2
      assert v.failed_today == 3
    end
  end
end
