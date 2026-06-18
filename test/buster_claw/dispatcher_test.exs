defmodule BusterClaw.DispatcherTest do
  # async: false — the Dispatcher runs in its own process against the shared
  # sandbox and reads/writes the kill-switch file in a per-test tmp workspace.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Dispatch, Dispatcher, Orchestration}

  setup do
    tmp = Path.join(System.tmp_dir!(), "bc_disp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, tmp)

    on_exit(fn ->
      if prev_ws,
        do: Application.put_env(:buster_claw, :workspace_root, prev_ws),
        else: Application.delete_env(:buster_claw, :workspace_root)

      File.rm_rf(tmp)
    end)

    %{tmp: tmp}
  end

  # A runner that reports it ran and returns a canned result, without touching a
  # real agent. `result` lets a test simulate a clean/failed/error outcome.
  defp stub_runner(
         test_pid,
         result \\ {:ok, %{agent: :stub, exit_status: 0, output: "", duration_ms: 1}}
       ) do
    fn _prompt, _opts ->
      send(test_pid, {:ran, self()})
      result
    end
  end

  defp start_dispatcher!(runner, opts \\ []) do
    defaults = [
      runner: runner,
      autostart: false,
      subscribe: false,
      cooldown_ms: 0,
      interval_ms: 60_000
    ]

    start_supervised!({Dispatcher, Keyword.merge(defaults, opts)})
  end

  defp enqueue!(attrs \\ %{}) do
    {:ok, item} =
      Dispatch.enqueue(
        Map.merge(%{source: "gmail", dedupe_key: "k#{System.unique_integer([:positive])}"}, attrs)
      )

    item
  end

  defp flush(server), do: _ = :sys.get_state(server)

  defp wait_until(fun, retries \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, retries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, retries - 1)
    end
  end

  defp reload_shift(id), do: BusterClaw.Repo.get!(Orchestration.Shift, id)

  test "runs and counts a clean outcome when an unattended shift has queued work" do
    {:ok, shift} = Orchestration.start_shift(unattended: true, job_key: "dispatcher")
    enqueue!()
    server = start_dispatcher!(stub_runner(self()))

    Dispatcher.tick_now(server)

    assert_receive {:ran, _pid}, 1_000
    wait_until(fn -> reload_shift(shift.id).done_count == 1 end)

    reloaded = reload_shift(shift.id)
    assert reloaded.dispatched_count == 1
    assert reloaded.done_count == 1
    assert reloaded.failed_count == 0
  end

  test "counts a non-zero exit as failed" do
    {:ok, shift} = Orchestration.start_shift(unattended: true)
    enqueue!()
    result = {:ok, %{agent: :stub, exit_status: 1, output: "boom", duration_ms: 1}}
    server = start_dispatcher!(stub_runner(self(), result))

    Dispatcher.tick_now(server)

    assert_receive {:ran, _pid}, 1_000
    wait_until(fn -> reload_shift(shift.id).failed_count == 1 end)
    assert reload_shift(shift.id).done_count == 0
  end

  test "counts a runner error as failed" do
    {:ok, shift} = Orchestration.start_shift(unattended: true)
    enqueue!()
    server = start_dispatcher!(stub_runner(self(), {:error, {:timeout, %{}}}))

    Dispatcher.tick_now(server)

    assert_receive {:ran, _pid}, 1_000
    wait_until(fn -> reload_shift(shift.id).failed_count == 1 end)
  end

  test "leaves an attended shift alone" do
    {:ok, _shift} = Orchestration.start_shift(unattended: false)
    enqueue!()
    server = start_dispatcher!(stub_runner(self()))

    Dispatcher.tick_now(server)
    flush(server)

    refute_receive {:ran, _pid}, 200
  end

  test "does nothing with no active shift" do
    enqueue!()
    server = start_dispatcher!(stub_runner(self()))

    Dispatcher.tick_now(server)
    flush(server)

    refute_receive {:ran, _pid}, 200
  end

  test "does nothing when the queue is empty" do
    {:ok, _shift} = Orchestration.start_shift(unattended: true)
    server = start_dispatcher!(stub_runner(self()))

    Dispatcher.tick_now(server)
    flush(server)

    refute_receive {:ran, _pid}, 200
  end

  test "does not run while the kill switch is engaged" do
    {:ok, _shift} = Orchestration.start_shift(unattended: true)
    enqueue!()
    Orchestration.engage_kill_switch()
    server = start_dispatcher!(stub_runner(self()))

    Dispatcher.tick_now(server)
    flush(server)

    refute_receive {:ran, _pid}, 200
  end

  test "serializes — a second tick does not start a second run while one is in flight" do
    {:ok, _shift} = Orchestration.start_shift(unattended: true)
    enqueue!()
    enqueue!()
    test_pid = self()

    # This runner blocks until released, so the first run stays in flight while
    # we fire a second tick.
    blocking = fn _prompt, _opts ->
      send(test_pid, {:ran, self()})

      receive do
        :release -> {:ok, %{agent: :stub, exit_status: 0, output: "", duration_ms: 1}}
      end
    end

    server = start_dispatcher!(blocking)

    Dispatcher.tick_now(server)
    assert_receive {:ran, run_pid}, 1_000

    # Second tick while the first run is still blocked: must NOT spawn another.
    Dispatcher.tick_now(server)
    flush(server)
    refute_receive {:ran, _other}, 200

    send(run_pid, :release)
  end
end
