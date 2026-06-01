defmodule BusterClaw.Orchestration.UptimeTest do
  # async: false — the GenServer runs in its own process and shares this test's
  # sandbox connection (it reads shift state in init), mirroring ReporterTest.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Orchestration
  alias BusterClaw.Orchestration.Uptime

  # Recording ops: each OS action just messages the test process so we can assert
  # engage/release happened, without touching caffeinate/launchctl.
  defp recording_ops(test_pid) do
    %{
      start_caffeinate: fn ->
        send(test_pid, {:uptime, :start_caffeinate})
        :fake_handle
      end,
      stop_caffeinate: fn handle ->
        send(test_pid, {:uptime, :stop_caffeinate, handle})
        :ok
      end,
      launchd_load: fn ->
        send(test_pid, {:uptime, :launchd_load})
        :ok
      end,
      launchd_unload: fn ->
        send(test_pid, {:uptime, :launchd_unload})
        :ok
      end
    }
  end

  defp start_uptime!(ops), do: start_supervised!({Uptime, ops: ops})

  # Round-trip a synchronous call so we know the cast/info was processed.
  defp sync(pid), do: _ = :sys.get_state(pid)

  test "engages caffeinate + launchd on :shift_started" do
    pid = start_uptime!(recording_ops(self()))

    send(pid, {:orchestration, :shift_started})
    sync(pid)

    assert_received {:uptime, :start_caffeinate}
    assert_received {:uptime, :launchd_load}
    assert Process.alive?(pid)
  end

  test "releases caffeinate + launchd on :shift_stopped" do
    pid = start_uptime!(recording_ops(self()))

    send(pid, {:orchestration, :shift_started})
    sync(pid)
    assert_received {:uptime, :start_caffeinate}

    send(pid, {:orchestration, :shift_stopped})
    sync(pid)

    assert_received {:uptime, :stop_caffeinate, :fake_handle}
    assert_received {:uptime, :launchd_unload}
  end

  test ":shift_completed also releases" do
    pid = start_uptime!(recording_ops(self()))

    send(pid, {:orchestration, :shift_started})
    sync(pid)
    assert_received {:uptime, :start_caffeinate}

    send(pid, {:orchestration, :shift_completed})
    sync(pid)

    assert_received {:uptime, :stop_caffeinate, :fake_handle}
    assert_received {:uptime, :launchd_unload}
  end

  test "does not spawn a second caffeinate when already engaged" do
    pid = start_uptime!(recording_ops(self()))

    send(pid, {:orchestration, :shift_started})
    sync(pid)
    assert_received {:uptime, :start_caffeinate}

    send(pid, {:orchestration, :shift_started})
    sync(pid)
    refute_received {:uptime, :start_caffeinate}
  end

  test "engages at init when a shift is already active (relaunch mid-shift)" do
    {:ok, _shift} = Orchestration.start_shift(hours: 12)

    pid = start_uptime!(recording_ops(self()))
    sync(pid)

    assert_received {:uptime, :start_caffeinate}
    assert_received {:uptime, :launchd_load}
  end

  test "an op that raises never crashes the process" do
    boom_ops = %{
      start_caffeinate: fn -> raise "boom" end,
      stop_caffeinate: fn _ -> raise "boom" end,
      launchd_load: fn -> raise "boom" end,
      launchd_unload: fn -> raise "boom" end
    }

    pid = start_uptime!(boom_ops)

    send(pid, {:orchestration, :shift_started})
    sync(pid)
    send(pid, {:orchestration, :shift_stopped})
    sync(pid)

    assert Process.alive?(pid)
  end
end
