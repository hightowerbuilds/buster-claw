defmodule BusterClaw.SchedulerTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Automation, Integrations, Scheduler}

  setup do
    Req.Test.verify_on_exit!()

    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-scheduler-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, previous)
      File.rm_rf(root)
    end)

    :ok
  end

  test "manages scheduler jobs through a focused context" do
    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "daily-poll",
               type: "integrations_poll",
               cron: "0 8 * * *"
             })

    assert [^job] = Scheduler.list_jobs()

    assert {:ok, job} = Scheduler.update_job(job, %{enabled: false})
    refute job.enabled

    assert {:ok, _job} = Scheduler.delete_job(job)
    assert [] = Scheduler.list_jobs()
  end

  test "validates cron expressions and initializes next run time" do
    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "next-hour",
               type: "integrations_poll",
               cron: "@hourly"
             })

    assert job.next_run_at

    assert {:error, changeset} =
             Scheduler.create_job(%{
               job_id: "bad-cron",
               type: "integrations_poll",
               cron: "not a cron"
             })

    assert %{cron: [_]} = errors_on(changeset)
  end

  test "initializes next_run_at for imported enabled jobs" do
    assert {:ok, job} =
             Automation.create_scheduler_job(%{
               job_id: "imported",
               type: "integrations_poll",
               cron: "@daily"
             })

    refute job.next_run_at

    assert [{:ok, updated}] = Scheduler.ensure_next_runs(~U[2026-05-26 10:00:00Z])
    assert updated.job_id == "imported"
    assert updated.next_run_at == ~U[2026-05-27 00:00:00Z]
  end

  test "run_due executes due jobs and advances next_run_at" do
    now = ~U[2026-05-26 10:00:00Z]

    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "due-custom",
               type: "integrations_poll",
               cron: "* * * * *"
             })

    assert {:ok, _job} =
             Automation.update_scheduler_job(job, %{next_run_at: DateTime.add(now, -60, :second)})

    assert [{%{job_id: "due-custom"}, {:ok, %{status: "ok"}}}] = Scheduler.run_due(now)

    updated = Scheduler.get_job!(job.id)
    assert updated.last_run_at == now
    assert updated.next_run_at == ~U[2026-05-26 10:01:00Z]
  end

  test "supervised runner ticks due jobs" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "runner-custom",
               type: "integrations_poll",
               cron: "* * * * *"
             })

    assert {:ok, _job} =
             Automation.update_scheduler_job(job, %{next_run_at: DateTime.add(now, -60, :second)})

    runner_name = :"scheduler-runner-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {BusterClaw.Scheduler.Runner, name: runner_name, interval_ms: 60_000, autostart: false}
      )

    send(pid, :tick)
    _ = :sys.get_state(pid)

    assert Scheduler.get_job!(job.id).last_run_at

    GenServer.stop(pid)
  end

  test "run_now can poll integrations" do
    {:ok, _integration} =
      Integrations.create_integration(%{
        name: "disabled-github",
        service_type: "github",
        enabled: false,
        config_text: ~s({"owner":"acme","repo":"checkout"})
      })

    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "poll-integrations",
               type: "integrations_poll",
               cron: "@hourly"
             })

    assert {:ok, summary} = Scheduler.run_now(job)
    assert summary.status == "ok"
    assert summary.ok == 0
    assert summary.errors == 1
    assert [run_summary] = summary.runs
    assert run_summary.status == :error

    assert [run] = Integrations.list_runs()
    assert run.trigger == "scheduler"
    assert run.error == "Integration is disabled"
  end

  test "run_now rejects unsupported (cut) job types" do
    assert {:error, changeset} =
             Scheduler.create_job(%{
               job_id: "legacy-analyze",
               type: "analyze",
               cron: "@hourly"
             })

    assert %{type: [_]} = errors_on(changeset)
  end
end
