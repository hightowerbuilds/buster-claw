defmodule BusterClaw.SchedulerTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Scheduler, Workflow}

  test "manages scheduler jobs through a focused context" do
    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "daily-ingest",
               type: "ingest",
               cron: "0 8 * * *"
             })

    assert [^job] = Scheduler.list_jobs()

    assert {:ok, job} = Scheduler.update_job(job, %{enabled: false})
    refute job.enabled

    assert {:ok, _job} = Scheduler.delete_job(job)
    assert [] = Scheduler.list_jobs()
  end

  test "run_now records custom placeholders without executing commands" do
    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "custom-placeholder",
               type: "custom",
               cron: "@daily",
               custom_cmd: "exit 42"
             })

    assert {:ok, summary} = Scheduler.run_now(job)
    assert summary.status == "placeholder"
    assert summary.custom_cmd == "exit 42"

    updated = Scheduler.get_job!(job.id)
    assert updated.last_run_at
    refute updated.last_error

    assert [event] = Workflow.list_runtime_events()
    assert event.kind == "scheduler.custom"
    assert event.metadata["job_id"] == "custom-placeholder"
  end

  test "run_now ingest succeeds with no configured sources" do
    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "empty-ingest",
               type: "ingest",
               cron: "@hourly"
             })

    assert {:ok, %{saved: 0, errors: []}} = Scheduler.run_now(job)
    assert Scheduler.get_job!(job.id).last_run_at
  end
end
