defmodule BusterClaw.OrchestrationTest do
  use BusterClaw.DataCase, async: true

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
      {:ok, shift} = Orchestration.start_shift(hours: 12)
      assert Orchestration.shift_active?()
      assert Orchestration.active_shift().id == shift.id

      {:ok, stopped} = Orchestration.stop_shift("kill switch")
      assert stopped.status == "stopped"
      refute Orchestration.shift_active?()
    end

    test "starting a shift supersedes a prior active one" do
      {:ok, first} = Orchestration.start_shift()
      {:ok, _second} = Orchestration.start_shift()
      assert Repo.get!(BusterClaw.Orchestration.Shift, first.id).status == "completed"
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
