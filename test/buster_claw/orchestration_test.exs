defmodule BusterClaw.OrchestrationTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Orchestration

  defp past, do: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
  defp future, do: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

  defp pipeline_task(attrs \\ %{}) do
    {:ok, task} =
      Orchestration.create_task(
        Map.merge(%{name: "t", type: "pipeline", command: "noop", due_at: past()}, attrs)
      )

    task
  end

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

  describe "due selection + leasing" do
    test "lists only due, pending tasks" do
      due = pipeline_task(%{name: "due"})
      _future = pipeline_task(%{name: "later", due_at: future()})

      ids = Orchestration.list_due_tasks() |> Enum.map(& &1.id)
      assert due.id in ids
      assert length(ids) == 1
    end

    test "claim is exclusive and increments attempts" do
      task = pipeline_task()
      assert {:ok, claimed} = Orchestration.claim_task(task, "owner-a")
      assert claimed.state == "claimed"
      assert claimed.attempts == 1
      assert claimed.lease_owner == "owner-a"

      assert {:error, :not_claimable} = Orchestration.claim_task(task, "owner-b")
    end

    test "expired leases are reclaimed to pending" do
      task = pipeline_task()
      {:ok, claimed} = Orchestration.claim_task(task, "owner-a")

      claimed
      |> Ecto.Changeset.change(lease_expires_at: past())
      |> Repo.update!()

      assert Orchestration.reclaim_expired() == 1
      assert Orchestration.get_task!(task.id).state == "pending"
    end
  end

  describe "lifecycle outcomes" do
    test "one-shot complete marks done" do
      task = pipeline_task()
      {:ok, claimed} = Orchestration.claim_task(task, "o")
      {:ok, done} = Orchestration.complete_task(claimed, "ok")
      assert done.state == "done"
      assert done.result_path == "ok"
      assert is_nil(done.lease_owner)
    end

    test "cron task reschedules to pending with a next_run_at" do
      task = pipeline_task(%{cron: "*/5 * * * *"})
      {:ok, claimed} = Orchestration.claim_task(task, "o")
      {:ok, rescheduled} = Orchestration.complete_task(claimed, "ok")
      assert rescheduled.state == "pending"
      assert rescheduled.next_run_at
    end

    test "one-shot failure marks failed at max attempts" do
      task = pipeline_task(%{max_attempts: 1})
      {:ok, claimed} = Orchestration.claim_task(task, "o")
      {:ok, failed} = Orchestration.fail_task(claimed, "boom")
      assert failed.state == "failed"
      assert failed.error == "boom"
    end
  end

  describe "validation" do
    test "agent task requires a prompt; pipeline requires a command" do
      assert {:error, cs} = Orchestration.create_task(%{name: "a", type: "agent"})
      assert %{prompt: _} = errors_on(cs)

      assert {:error, cs} = Orchestration.create_task(%{name: "p", type: "pipeline"})
      assert %{command: _} = errors_on(cs)
    end
  end
end
