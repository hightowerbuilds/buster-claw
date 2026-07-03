defmodule BusterClaw.OrchestratorTest do
  # async: false — these drive a GenServer that talks to the shared sandbox.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Orchestrator, Orchestration}

  # `async: false` → DataCase runs the sandbox in shared mode, so the Orchestrator
  # GenServer (a separate process) uses this test's connection.

  # Run ticks against an autostart:false server so each tick is explicit.
  defp start_orchestrator(opts \\ []) do
    # Unique per-test GenServer name; atom growth is bounded by the number of
    # test runs in a throwaway VM, so minting here is fine.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
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

  describe "janitor tick" do
    test "an active shift stays active after healthy ticks" do
      {:ok, shift} = Orchestration.start_shift()
      %{name: name} = start_orchestrator()

      tick_sync(name)
      tick_sync(name)

      assert %{id: id} = Orchestration.active_shift()
      assert id == shift.id
    end

    test "the kill switch stops the active shift" do
      {:ok, _shift} = Orchestration.start_shift()
      %{name: name} = start_orchestrator()

      # Drop the STOP kill switch into the workspace, then tick.
      Orchestration.engage_kill_switch()
      on_exit(&Orchestration.clear_kill_switch/0)

      tick_sync(name)

      assert Orchestration.active_shift() == nil
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
