defmodule BusterClaw.SwarmTest do
  # async: false — the swarm spawns tasks under the global SwarmTaskSupervisor and
  # the test reads back Sentinel events it wrote.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Sentinel, Swarm}

  defp plan(n), do: for(i <- 1..n, do: %{role: "role-#{i}", prompt: "task-#{i}"})

  # A runner whose outcome is chosen per prompt by `outcomes` (prompt => result),
  # defaulting to a clean exit.
  defp runner(outcomes \\ %{}) do
    fn prompt, _opts ->
      Map.get(outcomes, prompt, {:ok, %{agent: :stub, exit_status: 0, duration_ms: 1}})
    end
  end

  defp swarm_events do
    Sentinel.list_events(limit: 100)
    |> Enum.filter(&Map.has_key?(&1.metadata, "swarm_id"))
  end

  test "fans out a plan and aggregates a clean quorum" do
    assert {:ok, summary} = Swarm.run(plan(3), runner: runner(), quorum: 2)

    assert summary.total == 3
    assert summary.ok == 3
    assert length(summary.results) == 3
    assert Enum.map(summary.results, & &1.role) == ["role-1", "role-2", "role-3"]
    assert Enum.all?(summary.results, &(&1.status == :ok))
  end

  test "every sub-run plus the summary lands on the audit feed with provenance" do
    {:ok, summary} = Swarm.run(plan(3), runner: runner(), quorum: 1, swarm_id: 4242)

    events = swarm_events()
    sub_runs = Enum.filter(events, &Map.has_key?(&1.metadata, "role"))

    assert length(sub_runs) == 3
    assert Enum.all?(sub_runs, &(&1.metadata["swarm_id"] == 4242))
    assert Enum.map(sub_runs, & &1.metadata["role"]) |> Enum.sort() == ~w(role-1 role-2 role-3)

    # The fan-in summary event is present too.
    assert Enum.any?(events, &(&1.metadata["swarm_id"] == 4242 and &1.metadata["ok"] == 3))
    assert summary.ok == 3
  end

  test "blocks (does not silently drop) when successes fall below quorum" do
    outcomes = %{
      "task-2" => {:ok, %{agent: :stub, exit_status: 1, duration_ms: 1}},
      "task-3" => {:error, :boom}
    }

    assert {:error, {:quorum_not_met, summary}} =
             Swarm.run(plan(3), runner: runner(outcomes), quorum: 2)

    assert summary.ok == 1
    # All three results are still present — nothing dropped.
    assert length(summary.results) == 3
    statuses = Enum.map(summary.results, & &1.status)
    assert :error in statuses
  end

  test "respects the concurrency cap" do
    {:ok, tracker} = Agent.start_link(fn -> %{cur: 0, max: 0} end)

    counting = fn _prompt, _opts ->
      Agent.update(tracker, fn s ->
        c = s.cur + 1
        %{cur: c, max: max(s.max, c)}
      end)

      Process.sleep(40)
      Agent.update(tracker, fn s -> %{s | cur: s.cur - 1} end)
      {:ok, %{agent: :stub, exit_status: 0, duration_ms: 1}}
    end

    assert {:ok, _} = Swarm.run(plan(6), runner: counting, max_concurrency: 2, quorum: 1)
    assert Agent.get(tracker, & &1.max) <= 2
  end

  test "a crashing sub-run is data, not a swarm failure" do
    crashing = fn prompt, _opts ->
      if prompt == "task-2", do: raise("kaboom")
      {:ok, %{agent: :stub, exit_status: 0, duration_ms: 1}}
    end

    assert {:ok, summary} = Swarm.run(plan(3), runner: crashing, quorum: 2)

    assert summary.ok == 2
    crashed = Enum.find(summary.results, &(&1.role == "role-2"))
    assert crashed.status == :error
  end

  test "a sub-run exceeding the timeout is killed and recorded as :timeout" do
    slow = fn prompt, _opts ->
      if prompt == "task-1", do: Process.sleep(1_000)
      {:ok, %{agent: :stub, exit_status: 0, duration_ms: 1}}
    end

    assert {:error, {:quorum_not_met, summary}} =
             Swarm.run(plan(2), runner: slow, timeout_ms: 80, quorum: 2)

    timed_out = Enum.find(summary.results, &(&1.role == "role-1"))
    assert timed_out.status == :timeout
  end

  test "an empty plan is a clean error" do
    assert {:error, :empty_plan} = Swarm.run([], runner: runner())
  end

  test "default quorum is a majority" do
    # 2 of 3 succeed → majority (2) met.
    outcomes = %{"task-3" => {:error, :nope}}
    assert {:ok, summary} = Swarm.run(plan(3), runner: runner(outcomes))
    assert summary.quorum == 2
    assert summary.ok == 2
  end
end
