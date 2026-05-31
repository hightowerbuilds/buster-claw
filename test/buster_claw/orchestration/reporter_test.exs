defmodule BusterClaw.Orchestration.ReporterTest do
  # Not async: the Reporter runs in its own process and we share the sandbox
  # connection with it (it does DB reads + Sentinel.observe writes).
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Orchestration
  alias BusterClaw.Orchestration.Reporter

  setup do
    # `async: false` → DataCase runs the sandbox in shared mode, so the Reporter
    # (a separate process) uses this test's connection — no manual toggling.

    # Default config for the suite; individual tests override as needed.
    Application.put_env(:buster_claw, :orchestrator_alerts_enabled, true)
    Application.put_env(:buster_claw, :orchestrator_morning_report, true)

    on_exit(fn ->
      Application.delete_env(:buster_claw, :orchestrator_alerts_enabled)
      Application.delete_env(:buster_claw, :orchestrator_morning_report)
    end)

    :ok
  end

  defp start_reporter! do
    start_supervised!(Reporter)
  end

  defp start_shift! do
    {:ok, shift} = Orchestration.start_shift(hours: 12)
    shift
  end

  describe ":shift_stopped" do
    test "does not crash when a shift exists (no delivery destinations -> graceful no-op)" do
      start_shift!()
      {:ok, _stopped} = Orchestration.stop_shift("kill switch")

      pid = start_reporter!()
      send(pid, {:orchestration, :shift_stopped})
      # Round-trip a synchronous call to ensure the message was processed.
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end

    test "alerts disabled: still does not crash" do
      Application.put_env(:buster_claw, :orchestrator_alerts_enabled, false)
      start_shift!()
      {:ok, _stopped} = Orchestration.stop_shift("manual")

      pid = start_reporter!()
      send(pid, {:orchestration, :shift_stopped})
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end

    test "no shift at all: does not crash" do
      pid = start_reporter!()
      send(pid, {:orchestration, :shift_stopped})
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end
  end

  describe ":shift_completed" do
    test "writes a morning report to the workspace shift/<date> dir" do
      # Point the workspace at a throwaway temp dir so we never touch the real one.
      workspace =
        Path.join(
          System.tmp_dir!(),
          "buster-claw-reporter-test-#{System.unique_integer([:positive])}"
        )

      prev_ws = Application.get_env(:buster_claw, :workspace_root)
      Application.put_env(:buster_claw, :workspace_root, workspace)

      on_exit(fn ->
        if prev_ws,
          do: Application.put_env(:buster_claw, :workspace_root, prev_ws),
          else: Application.delete_env(:buster_claw, :workspace_root)

        File.rm_rf(workspace)
      end)

      shift = start_shift!()
      {:ok, completed} = Orchestration.complete_shift(shift, "window elapsed")

      date = DateTime.to_date(completed.ends_at)

      path =
        Path.join([
          Path.expand(workspace),
          "shift",
          Date.to_iso8601(date),
          "morning-report.md"
        ])

      pid = start_reporter!()
      send(pid, {:orchestration, :shift_completed})
      _ = :sys.get_state(pid)

      assert Process.alive?(pid)
      assert File.exists?(path)

      contents = File.read!(path)
      assert contents =~ "Morning Report"
      assert contents =~ "Dispatched:"
    end

    test "morning report disabled: does not write but stays alive" do
      Application.put_env(:buster_claw, :orchestrator_morning_report, false)
      shift = start_shift!()
      {:ok, _completed} = Orchestration.complete_shift(shift, "window elapsed")

      pid = start_reporter!()
      send(pid, {:orchestration, :shift_completed})
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end

    test "no shift: does not crash" do
      pid = start_reporter!()
      send(pid, {:orchestration, :shift_completed})
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end
  end

  test "ignores unrelated messages" do
    pid = start_reporter!()
    send(pid, {:orchestration, :run_started})
    send(pid, :some_other_message)
    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
  end
end
