defmodule BusterClaw.Swarm.CoordinatorTest do
  # async: false — Swarm.run emits Sentinel events (DB writes) under the shared
  # SwarmTaskSupervisor.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Swarm.Coordinator

  defp planner(output, exit_status \\ 0) do
    fn _prompt, _opts -> {:ok, %{exit_status: exit_status, output: output}} end
  end

  defp ok_subrun do
    fn _prompt, _opts -> {:ok, %{agent: :stub, exit_status: 0, output: "ok", duration_ms: 1}} end
  end

  describe "plan/2" do
    test "parses a clean JSON array of {role, prompt}" do
      json =
        ~s([{"role":"research","prompt":"find sources"},{"role":"draft","prompt":"write it"}])

      assert {:ok, plan} = Coordinator.plan("goal", planner_runner: planner(json))

      assert plan == [
               %{role: "research", prompt: "find sources"},
               %{role: "draft", prompt: "write it"}
             ]
    end

    test "extracts the array even when wrapped in prose / markdown fences" do
      out = """
      Sure, here is the plan:

      ```json
      [{"role":"a","prompt":"do a"}]
      ```

      Hope that helps.
      """

      assert {:ok, [%{role: "a", prompt: "do a"}]} =
               Coordinator.plan("goal", planner_runner: planner(out))
    end

    test "ignores a stray bracket inside a string value (depth scan)" do
      json = ~s(prefix [{"role":"r","prompt":"use [brackets] safely"}] suffix)

      assert {:ok, [%{role: "r", prompt: "use [brackets] safely"}]} =
               Coordinator.plan("goal", planner_runner: planner(json))
    end

    test "defaults a missing role and drops blank-prompt entries" do
      json = ~s([{"prompt":"no role"},{"role":"x","prompt":"   "}])

      assert {:ok, [%{role: "worker-0", prompt: "no role"}]} =
               Coordinator.plan("goal", planner_runner: planner(json))
    end

    test "caps the plan at max_subtasks" do
      json = ~s([{"prompt":"a"},{"prompt":"b"},{"prompt":"c"}])

      assert {:ok, plan} =
               Coordinator.plan("goal", planner_runner: planner(json), max_subtasks: 2)

      assert length(plan) == 2
    end

    test "unparseable output is :unplannable" do
      assert {:error, :unplannable} =
               Coordinator.plan("goal", planner_runner: planner("no json here"))
    end

    test "an empty array is :unplannable" do
      assert {:error, :unplannable} = Coordinator.plan("goal", planner_runner: planner("[]"))
    end

    test "a non-zero planner exit surfaces :planner_failed" do
      assert {:error, {:planner_failed, 1}} =
               Coordinator.plan("goal", planner_runner: planner("[]", 1))
    end
  end

  describe "coordinate/2" do
    test "plans, then runs the swarm and meets quorum" do
      json = ~s([{"role":"a","prompt":"do a"},{"role":"b","prompt":"do b"}])

      assert {:ok, summary} =
               Coordinator.coordinate("goal", planner_runner: planner(json), runner: ok_subrun())

      assert summary.total == 2
      assert summary.ok == 2
    end

    test "an unplannable goal short-circuits — the swarm runner is never called" do
      test_pid = self()
      spy = fn _p, _o -> send(test_pid, :ran) && {:ok, %{exit_status: 0}} end

      assert {:error, :unplannable} =
               Coordinator.coordinate("goal", planner_runner: planner("garbage"), runner: spy)

      refute_receive :ran, 100
    end
  end
end
