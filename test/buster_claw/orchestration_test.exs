defmodule BusterClaw.OrchestrationTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Orchestration

  describe "shifts" do
    test "start/active/stop lifecycle" do
      refute Orchestration.shift_active?()
      {:ok, shift} = Orchestration.start_shift()
      assert Orchestration.shift_active?()
      assert Orchestration.active_shift().id == shift.id
      assert shift.job_key == "lookout"
      assert shift.job_name == "Lookout"

      {:ok, stopped} = Orchestration.stop_shift("kill switch")
      assert stopped.status == "stopped"
      refute Orchestration.shift_active?()
    end

    test "a shift runs until stopped (no fixed window)" do
      {:ok, shift} = Orchestration.start_shift()
      assert shift.status == "active"
      refute Map.has_key?(shift, :ends_at)
      refute Map.has_key?(shift, :duration_hours)
    end

    test "start stores job assignment metadata" do
      assert {:ok, shift} =
               Orchestration.start_shift(
                 job: "lookout",
                 agent_name: "Codex",
                 shell: "Terminal 2"
               )

      assert shift.job_name == "Lookout"
      assert shift.agent_name == "Codex"
      assert shift.shell == "Terminal 2"
    end

    test "starting a shift supersedes a prior active one" do
      {:ok, first} = Orchestration.start_shift()
      {:ok, _second} = Orchestration.start_shift()
      assert Repo.get!(BusterClaw.Orchestration.Shift, first.id).status == "completed"
    end
  end

  describe "shift assignments" do
    test "starting an assignment requires an active shift" do
      assert {:error, :no_active_shift} =
               Orchestration.start_shift_assignment(role_key: "mail-triage")
    end

    test "starts, lists, and stops a specialist role inside the active shift" do
      {:ok, shift} = Orchestration.start_shift(job: "lookout", shell: "Lookout terminal")

      assert {:ok, assignment} =
               Orchestration.start_shift_assignment(
                 role_key: "mail-triage",
                 agent_name: "Mail Triage",
                 shell: "Email terminal",
                 purpose: "Handle incoming email."
               )

      assert assignment.shift_id == shift.id
      assert assignment.role_key == "mail-triage"
      assert assignment.agent_name == "Mail Triage"
      assert assignment.shell == "Email terminal"
      assert assignment.status == "active"
      assert assignment.heartbeat_at

      assert [^assignment] = Orchestration.active_shift_assignments()

      assert {:ok, %{assignments: [^assignment], active_shift_id: shift_id}} =
               Orchestration.shift_assignment_status()

      assert shift_id == shift.id

      assert {:ok, stopped} = Orchestration.stop_shift_assignment(role_key: "mail-triage")
      assert stopped.status == "stopped"
      assert stopped.ended_at
      assert Orchestration.active_shift_assignments() == []
    end

    test "starting the same role replaces the previous active session" do
      {:ok, _shift} = Orchestration.start_shift()
      {:ok, first} = Orchestration.start_shift_assignment(role_key: "scribe", shell: "Notes 1")
      {:ok, second} = Orchestration.start_shift_assignment(role_key: "scribe", shell: "Notes 2")

      assert [^second] = Orchestration.active_shift_assignments()
      assert Repo.get!(BusterClaw.Orchestration.ShiftAssignment, first.id).status == "stopped"
    end

    test "stopping a shift stops its active assignments" do
      {:ok, _shift} = Orchestration.start_shift()
      {:ok, assignment} = Orchestration.start_shift_assignment(role_key: "ci-fix")

      assert {:ok, _stopped_shift} = Orchestration.stop_shift("done")

      assert Repo.get!(BusterClaw.Orchestration.ShiftAssignment, assignment.id).status ==
               "stopped"
    end
  end

  # The operator's brake (G-30). `stand_down/1` is `stop_shift/1` plus a latch,
  # and the tests below pin the two properties that make it different: the latch
  # goes down FIRST, and it goes down even when there is nothing to stop.
  describe "stand_down/1" do
    setup do
      on_exit(&Orchestration.clear_kill_switch/0)
    end

    test "stops the active shift and latches the kill switch" do
      {:ok, shift} = Orchestration.start_shift()
      refute Orchestration.kill_switch_engaged?()

      assert {:ok, stopped} = Orchestration.stand_down("stood down from the dock")

      assert stopped.id == shift.id
      assert stopped.status == "stopped"
      refute Orchestration.shift_active?()

      # The latch, not just the stop. Without it a `shift_start` moments later
      # brings the Dispatcher straight back up and the operator's brake reads as
      # a glitch.
      assert Orchestration.kill_switch_engaged?()
    end

    test "latches even with no active shift, and says which happened" do
      refute Orchestration.shift_active?()

      # Not an error: pulling the brake on an already-finished shift still has a
      # real effect, and reporting it as a failure would teach the operator that
      # the control sometimes does nothing.
      assert {:ok, :latched} = Orchestration.stand_down()
      assert Orchestration.kill_switch_engaged?()
    end

    test "going back on duty is what clears the latch" do
      {:ok, _shift} = Orchestration.start_shift()
      assert {:ok, _stopped} = Orchestration.stand_down()
      assert Orchestration.kill_switch_engaged?()

      # `Commands.Orchestration.shift_start/1` clears it before starting, which
      # is why resume needs no separate verb and no second answer to "who may
      # clear this". Asserted through the command, since that is the only caller
      # that does it.
      assert {:ok, _started} = BusterClaw.Commands.Orchestration.shift_start(%{})
      refute Orchestration.kill_switch_engaged?()
      assert Orchestration.shift_active?()
    end

    # ── On the ordering claim, and why there is no test for it ────────────────
    #
    # `stand_down/1`'s docs say the latch goes down BEFORE the stop, and that is
    # true and load-bearing — but it is **not** testable from here, and a test
    # pretending otherwise was written and deleted rather than kept.
    #
    # The deleted version subscribed, called `stand_down/1`, awaited
    # `:shift_stopped` and then asserted the latch. It passed with the order
    # swapped, because by the time a subscriber receives anything both lines
    # have run. It looked like an ordering guard and guarded nothing.
    #
    # **What is guarded instead is the property that actually matters**, and the
    # `:latched` test above is it: the latch goes down regardless of what the
    # stop does. A swap that also returned early on `{:error, :no_active_shift}`
    # — the plausible wrong version — fails there, loudly.
    #
    # The ordering itself is sequential code in one function with no branch
    # between the two calls. It is enforced by construction; the comment at the
    # call site is where it is defended.
  end
end
