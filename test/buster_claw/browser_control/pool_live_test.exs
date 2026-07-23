defmodule BusterClaw.BrowserControl.PoolLiveTest do
  @moduledoc """
  The pool driving REAL sessions end to end — launches Chromium.

  Excluded by default; run with `mix test --include browser_engine` on a machine
  with a Chromium-family browser. Uses the app's real `SessionSupervisor`.
  """
  use ExUnit.Case, async: false

  alias BusterClaw.BrowserControl.{Pool, Session}

  @moduletag :browser_engine
  @moduletag timeout: 90_000

  test "checkout yields a working session, reused across checkin, capped, and idle-reaped" do
    # Short idle window so the reaper is observable within the test.
    {:ok, pool} = Pool.start_link(name: nil, max_sessions: 1, idle_ms: 800)

    {:ok, s1} = Pool.checkout(pool)
    assert :ok = Session.navigate(s1, "data:text/html,<title>pool-a</title>hi")

    assert {:ok, %{"result" => %{"value" => "pool-a"}}} =
             Session.command(s1, "Runtime.evaluate", %{"expression" => "document.title"})

    # Cap holds while leased.
    assert {:error, :pool_exhausted} = Pool.checkout(pool)

    # Checkin → same engine reused, not a new one.
    :ok = Pool.checkin(pool, s1)
    assert {:ok, ^s1} = Pool.checkout(pool)
    :ok = Pool.checkin(pool, s1)

    # Idle-reaped after the window: the session terminates and the pool empties.
    wait_until(fn -> Pool.stats(pool).total == 0 end, 200)
    refute Process.alive?(s1)
    assert %{total: 0, available: 0, leased: 0} = Pool.stats(pool)
  end

  test "killing the OS engine takes the session down loudly, freeing the pool" do
    {:ok, pool} = Pool.start_link(name: nil, max_sessions: 1, idle_ms: 60_000)

    {:ok, s1} = Pool.checkout(pool)
    %{os_pid: os_pid} = Session.info(s1)
    assert is_integer(os_pid)

    # The engine dies out from under the session (driver crash / TDR analogue).
    System.cmd("kill", ["-9", to_string(os_pid)])

    wait_until(fn -> not Process.alive?(s1) end, 200)
    wait_until(fn -> Pool.stats(pool).total == 0 end, 200)
    assert %{total: 0, leased: 0} = Pool.stats(pool)
  end

  defp wait_until(fun, tries) do
    cond do
      tries <= 0 ->
        flunk("condition never held")

      fun.() ->
        :ok

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end
end
