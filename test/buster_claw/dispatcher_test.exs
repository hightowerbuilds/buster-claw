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

  defp capturing_runner(test_pid) do
    fn _prompt, opts ->
      send(test_pid, {:opts, opts})
      {:ok, %{agent: :stub, exit_status: 0, output: "", duration_ms: 1}}
    end
  end

  defp env_token(opts) do
    opts |> Keyword.get(:env, []) |> Map.new() |> Map.get("BUSTER_CLAW_API_TOKEN")
  end

  defp env_url(opts) do
    opts |> Keyword.get(:env, []) |> Map.new() |> Map.get("BUSTER_CLAW_URL")
  end

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

  test "records a cross-run memory summary on a clean run" do
    {:ok, shift} = Orchestration.start_shift(unattended: true, job_key: "mail-triage")
    enqueue!()

    result =
      {:ok,
       %{agent: :stub, exit_status: 0, output: "claimed and replied to acme", duration_ms: 5}}

    server = start_dispatcher!(stub_runner(self(), result))

    Dispatcher.tick_now(server)

    assert_receive {:ran, _pid}, 1_000
    # The summary is written just after the shift counter, in the Dispatcher
    # process — wait on the summary itself, not on done_count.
    wait_until(fn -> match?({:ok, [_]}, BusterClaw.Memory.search("acme")) end)

    assert {:ok, [summary]} = BusterClaw.Memory.search("acme")
    assert summary.outcome == "completed"
    assert summary.detail =~ "acme"
    assert summary.shift_id == shift.id
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
    {:ok, shift} = Orchestration.start_shift(unattended: true)
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
    # Let the released run's completion write settle before teardown.
    wait_until(fn -> reload_shift(shift.id).done_count == 1 end)
  end

  describe "budget governor" do
    test "stops the shift when the per-shift run cap is reached (and does not run)" do
      {:ok, shift} = Orchestration.start_shift(unattended: true)
      enqueue!()
      # cap 0: the very first eligible tick is already over budget.
      server = start_dispatcher!(stub_runner(self()), max_runs_per_shift: 0)

      Dispatcher.tick_now(server)
      flush(server)

      refute_receive {:ran, _pid}, 200
      assert reload_shift(shift.id).status == "stopped"
      refute Orchestration.shift_active?()
    end

    test "does not start a swarm whose worst-case fan-out would overshoot the cap" do
      prev = Application.get_env(:buster_claw, :swarm_max_subtasks)
      Application.put_env(:buster_claw, :swarm_max_subtasks, 6)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:buster_claw, :swarm_max_subtasks, prev),
          else: Application.delete_env(:buster_claw, :swarm_max_subtasks)
      end)

      {:ok, shift} = Orchestration.start_shift(unattended: true)
      enqueue!(%{strategy: "swarm", request_summary: "big job"})

      test_pid = self()
      coordinator = fn goal, opts -> send(test_pid, {:coordinated, goal, opts}) end

      # cap 3 admits a single run (0 < 3) but NOT a swarm's worst case
      # (planner 1 + swarm_max_subtasks 6 = 7 > 3): the shift stops cleanly rather
      # than letting the on-completion `dispatched` bump overshoot.
      server =
        start_dispatcher!(stub_runner(self()), coordinator: coordinator, max_runs_per_shift: 3)

      Dispatcher.tick_now(server)
      flush(server)

      refute_receive {:coordinated, _goal, _opts}, 200
      refute_receive {:ran, _pid}, 200
      assert reload_shift(shift.id).status == "stopped"
      refute Orchestration.shift_active?()
    end

    test "runs normally while under the cap" do
      {:ok, shift} = Orchestration.start_shift(unattended: true)
      enqueue!()
      server = start_dispatcher!(stub_runner(self()), max_runs_per_shift: 5)

      Dispatcher.tick_now(server)

      assert_receive {:ran, _pid}, 1_000
      wait_until(fn -> reload_shift(shift.id).done_count == 1 end)
      assert reload_shift(shift.id).status == "active"
    end
  end

  describe "swarm strategy → coordinator path" do
    # A coordinator stub: records the goal/opts it was handed and returns a canned
    # swarm result, without planning or spawning real sub-runs.
    defp stub_coordinator(test_pid, result) do
      fn goal, opts ->
        send(test_pid, {:coordinated, goal, opts})
        result
      end
    end

    defp swarm_summary(ok, total) do
      results =
        for i <- 0..(total - 1) do
          %{role: "role-#{i}", index: i, status: if(i < ok, do: :ok, else: :error)}
        end

      %{swarm_id: 1, total: total, ok: ok, quorum: total, results: results}
    end

    test "a queued swarm item runs through the coordinator, not the generic runner" do
      {:ok, shift} = Orchestration.start_shift(unattended: true)
      enqueue!(%{strategy: "swarm", request_summary: "ship the thing"})

      server =
        start_dispatcher!(stub_runner(self()),
          coordinator: stub_coordinator(self(), {:ok, swarm_summary(2, 2)})
        )

      Dispatcher.tick_now(server)

      assert_receive {:coordinated, goal, _opts}, 1_000
      assert goal =~ "ship the thing"
      # The generic agent-pulls-queue runner must NOT fire for a swarm item.
      refute_receive {:ran, _pid}, 200

      wait_until(fn -> reload_shift(shift.id).done_count == 1 end)
      reloaded = reload_shift(shift.id)
      # dispatched counts the realized cost: planner (1) + sub-runs (2).
      assert reloaded.dispatched_count == 3
      assert reloaded.failed_count == 0
    end

    test "a crashing swarm run reclaims its in-flight item back to queued at runtime" do
      {:ok, _shift} = Orchestration.start_shift(unattended: true)
      item = enqueue!(%{strategy: "swarm", request_summary: "boom job"})

      # The coordinator crashes the monitored child *after* the item was marked
      # running. The :DOWN handler must reclaim it now, not wait for the next boot.
      crashing = fn _goal, _opts -> raise "kaboom" end

      server = start_dispatcher!(stub_runner(self()), coordinator: crashing)

      Dispatcher.tick_now(server)

      wait_until(fn -> Dispatch.get_item!(item.id).status == "queued" end)
      reclaimed = Dispatch.get_item!(item.id)
      assert reclaimed.status == "queued"
      assert reclaimed.claimed_by == nil
      assert reclaimed.started_at == nil

      # The pump survived the crash and is idle again.
      flush(server)
    end

    test "threads the provenance run_opts into the coordinator" do
      {:ok, _shift} = Orchestration.start_shift(unattended: true)
      enqueue!(%{strategy: "swarm", trusted: false, request_summary: "x"})

      server =
        start_dispatcher!(stub_runner(self()),
          coordinator: stub_coordinator(self(), {:ok, swarm_summary(1, 1)})
        )

      Dispatcher.tick_now(server)

      assert_receive {:coordinated, _goal, opts}, 1_000
      run_opts = Keyword.get(opts, :run_opts)
      assert env_token(run_opts) == BusterClaw.ApiToken.agent_value()
    end

    test "quorum-not-met blocks the item and counts a failure" do
      {:ok, shift} = Orchestration.start_shift(unattended: true)
      item = enqueue!(%{strategy: "swarm", request_summary: "hard job"})

      result = {:error, {:quorum_not_met, swarm_summary(1, 3)}}

      server =
        start_dispatcher!(stub_runner(self()), coordinator: stub_coordinator(self(), result))

      Dispatcher.tick_now(server)

      assert_receive {:coordinated, _goal, _opts}, 1_000
      wait_until(fn -> reload_shift(shift.id).failed_count == 1 end)
      assert Dispatch.get_item(item.id).status == "blocked"
      # planner (1) + 3 sub-runs.
      assert reload_shift(shift.id).dispatched_count == 4
    end

    test "an unplannable goal blocks the item" do
      {:ok, shift} = Orchestration.start_shift(unattended: true)
      item = enqueue!(%{strategy: "swarm", request_summary: "vague"})

      server =
        start_dispatcher!(stub_runner(self()),
          coordinator: stub_coordinator(self(), {:error, :unplannable})
        )

      Dispatcher.tick_now(server)

      assert_receive {:coordinated, _goal, _opts}, 1_000
      wait_until(fn -> reload_shift(shift.id).failed_count == 1 end)
      assert Dispatch.get_item(item.id).status == "blocked"
      # only the planner run was spent.
      assert reload_shift(shift.id).dispatched_count == 1
    end

    test "a single-strategy item still uses the generic runner, not the coordinator" do
      {:ok, _shift} = Orchestration.start_shift(unattended: true)
      enqueue!(%{strategy: "single"})

      server =
        start_dispatcher!(stub_runner(self()),
          coordinator: stub_coordinator(self(), {:ok, swarm_summary(1, 1)})
        )

      Dispatcher.tick_now(server)

      assert_receive {:ran, _pid}, 1_000
      refute_receive {:coordinated, _goal, _opts}, 200
    end
  end

  describe "provenance → token" do
    test "a trusted-only queue runs with the full (trusted) token" do
      {:ok, shift} = Orchestration.start_shift(unattended: true)
      enqueue!(%{trusted: true})
      server = start_dispatcher!(capturing_runner(self()))

      Dispatcher.tick_now(server)

      assert_receive {:opts, opts}, 1_000
      assert env_token(opts) == BusterClaw.ApiToken.value()
      # The run is pointed at this app's real endpoint, not the CLI's :4000 default.
      assert env_url(opts) =~ "http://127.0.0.1:"
      assert Keyword.get(opts, :login) == true
      # Let the run's completion write settle before teardown.
      wait_until(fn -> reload_shift(shift.id).done_count == 1 end)
    end

    test "any untrusted item makes the run use the agent (untrusted) token" do
      {:ok, shift} = Orchestration.start_shift(unattended: true)
      enqueue!(%{trusted: false})
      server = start_dispatcher!(capturing_runner(self()))

      Dispatcher.tick_now(server)

      assert_receive {:opts, opts}, 1_000
      assert env_token(opts) == BusterClaw.ApiToken.agent_value()
      wait_until(fn -> reload_shift(shift.id).done_count == 1 end)
    end

    test "an untrusted item buried beyond the newest 50 still forces the agent token" do
      {:ok, shift} = Orchestration.start_shift(unattended: true)
      # Oldest item is untrusted; a full page of newer trusted items would hide it
      # from a bounded newest-first sample, but the EXISTS gate must still catch it.
      enqueue!(%{trusted: false})
      for _ <- 1..55, do: enqueue!(%{trusted: true})

      server = start_dispatcher!(capturing_runner(self()))

      Dispatcher.tick_now(server)

      assert_receive {:opts, opts}, 1_000
      assert env_token(opts) == BusterClaw.ApiToken.agent_value()
      wait_until(fn -> reload_shift(shift.id).done_count == 1 end)
    end
  end
end
