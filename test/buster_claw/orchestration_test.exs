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
end
