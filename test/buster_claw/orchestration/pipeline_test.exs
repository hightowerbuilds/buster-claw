defmodule BusterClaw.Orchestration.PipelineTest do
  # async: false — the pipeline task runs in its own process under the app's
  # RunnerSupervisor and shares this test's sandbox connection (shared mode).
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Orchestration
  alias BusterClaw.Orchestration.Pipeline

  setup do
    {:ok, shift} = Orchestration.start_shift()
    %{shift: shift}
  end

  defp run!(task, shift) do
    {:ok, pid} = Pipeline.start(task, shift)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
  end

  test "noop task completes", %{shift: shift} do
    {:ok, task} = Orchestration.create_task(%{name: "n", type: "pipeline", command: "noop"})

    run!(task, shift)

    assert Orchestration.get_task!(task.id).state == "done"
  end

  test "a GWS command with no Google account fails gracefully (no crash)", %{shift: shift} do
    {:ok, task} =
      Orchestration.create_task(%{
        name: "sync",
        type: "pipeline",
        command: "gmail_sync",
        params: %{}
      })

    run!(task, shift)

    reloaded = Orchestration.get_task!(task.id)
    assert reloaded.error =~ "no_google_account"
    # No cron + attempts under max → reset to pending for retry; never crashed.
    assert reloaded.state in ["pending", "failed"]
  end

  test "an unknown command is reported, not crashed", %{shift: shift} do
    {:ok, task} = Orchestration.create_task(%{name: "x", type: "pipeline", command: "bogus"})

    run!(task, shift)

    assert Orchestration.get_task!(task.id).error =~ "unknown_command"
  end
end
