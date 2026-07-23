defmodule BusterClaw.BrowserControl.PoolTest do
  @moduledoc """
  Pool leasing / cap / crash logic, exercised with STUB sessions — no browser.

  A stub session is a plain Agent that records lease/release casts, so the pool's
  bookkeeping (cap, reuse, owner-death auto-release, session-death cleanup) is
  tested deterministically. The live-engine path is `BusterClaw.BrowserControl.PoolLiveTest`.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.BrowserControl.Pool

  # ── A stub that stands in for Session (start_session + lease/2 + release/1) ──
  defmodule StubSession do
    use Agent

    def start_session(_opts), do: Agent.start(fn -> %{leased_to: nil, releases: 0} end)

    def lease(pid, owner), do: safe(pid, &%{&1 | leased_to: owner})
    def release(pid), do: safe(pid, &%{&1 | leased_to: nil, releases: &1.releases + 1})
    def state(pid), do: Agent.get(pid, & &1)

    defp safe(pid, fun) do
      Agent.update(pid, fun)
    catch
      :exit, _ -> :ok
    end
  end

  # A stub whose start_session always fails, to prove error passthrough.
  defmodule FailingStart do
    def start_session(_opts), do: {:error, :boom}
  end

  defp start_pool(opts) do
    base = [
      name: nil,
      browser_path: "/fake/chrome",
      session_mod: StubSession,
      lease_mod: StubSession
    ]

    {:ok, pool} = Pool.start_link(Keyword.merge(base, opts))
    pool
  end

  test "checkout lazily starts a session and reports it leased" do
    pool = start_pool([])

    assert {:ok, s1} = Pool.checkout(pool)
    assert %{total: 1, available: 0, leased: 1, max: 3} = Pool.stats(pool)
    assert StubSession.state(s1).leased_to == self()
  end

  test "checkin returns the session to idle and reuses it next time" do
    pool = start_pool([])

    {:ok, s1} = Pool.checkout(pool)
    :ok = Pool.checkin(pool, s1)
    assert %{total: 1, available: 1, leased: 0} = Pool.stats(pool)
    assert StubSession.state(s1).releases == 1

    # Reuse, not a new engine.
    assert {:ok, ^s1} = Pool.checkout(pool)
    assert %{total: 1} = Pool.stats(pool)
  end

  test "the cap is hard: past max with none free is :pool_exhausted" do
    pool = start_pool(max_sessions: 2)

    {:ok, _} = Pool.checkout(pool)
    {:ok, _} = Pool.checkout(pool)
    assert {:error, :pool_exhausted} = Pool.checkout(pool)
    assert %{total: 2, leased: 2, max: 2} = Pool.stats(pool)
  end

  test "a freed session lets a would-be-exhausted checkout succeed" do
    pool = start_pool(max_sessions: 1)

    {:ok, s1} = Pool.checkout(pool)
    assert {:error, :pool_exhausted} = Pool.checkout(pool)
    :ok = Pool.checkin(pool, s1)
    assert {:ok, ^s1} = Pool.checkout(pool)
  end

  test "a dying lessee auto-releases its session" do
    pool = start_pool([])

    # A short-lived owner leases then exits without checking in.
    parent = self()

    owner =
      spawn(fn ->
        {:ok, s} = Pool.checkout(pool)
        send(parent, {:leased, s})
        Process.sleep(:infinity)
      end)

    assert_receive {:leased, _session}, 1_000
    assert %{leased: 1} = Pool.stats(pool)

    Process.exit(owner, :kill)
    # The owner-DOWN reclaim is async; wait for it to settle.
    wait_until(fn -> Pool.stats(pool).available == 1 end)
    assert %{total: 1, available: 1, leased: 0} = Pool.stats(pool)
  end

  test "a dying session is purged from the pool, freeing capacity" do
    pool = start_pool(max_sessions: 1)

    {:ok, s1} = Pool.checkout(pool)
    assert %{total: 1} = Pool.stats(pool)

    Process.exit(s1, :kill)
    wait_until(fn -> Pool.stats(pool).total == 0 end)
    assert %{total: 0, available: 0, leased: 0} = Pool.stats(pool)

    # Capacity is genuinely back — a fresh checkout succeeds.
    assert {:ok, s2} = Pool.checkout(pool)
    refute s2 == s1
  end

  test "a session that dies while leased is cleaned up without stranding the lease" do
    pool = start_pool([])

    {:ok, s1} = Pool.checkout(pool)
    Process.exit(s1, :kill)
    wait_until(fn -> Pool.stats(pool).total == 0 end)
    assert %{total: 0, leased: 0} = Pool.stats(pool)
  end

  test "with_session checks in even when the body raises" do
    pool = start_pool([])

    assert_raise RuntimeError, fn ->
      Pool.with_session(pool, fn _s -> raise "kaboom" end)
    end

    assert %{available: 1, leased: 0} = Pool.stats(pool)
  end

  test "a start_session failure surfaces its reason, not a crash" do
    {:ok, pool} =
      Pool.start_link(
        name: nil,
        browser_path: "/fake/chrome",
        session_mod: FailingStart,
        lease_mod: StubSession
      )

    assert {:error, :boom} = Pool.checkout(pool)
    assert %{total: 0} = Pool.stats(pool)
  end

  test "with no :browser_path the pool defers to detect/0 for engine resolution" do
    # This proves the resolution seam without faking the filesystem: on a machine
    # with a browser, checkout reaches the stub session; on one without, it's
    # {:error, :no_browser}. The detection logic itself is DetectTest's job.
    {:ok, pool} = Pool.start_link(name: nil, session_mod: StubSession, lease_mod: StubSession)

    case BusterClaw.BrowserControl.detect() do
      {:ok, _} -> assert {:ok, _session} = Pool.checkout(pool)
      {:error, :no_browser} -> assert {:error, :no_browser} = Pool.checkout(pool)
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      tries <= 0 ->
        flunk("condition never held")

      fun.() ->
        :ok

      true ->
        Process.sleep(5)
        wait_until(fun, tries - 1)
    end
  end
end
