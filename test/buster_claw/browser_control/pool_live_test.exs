defmodule BusterClaw.BrowserControl.PoolLiveTest do
  @moduledoc """
  The pool driving REAL sessions end to end — launches Chromium.

  Excluded by default; run with `mix test --include browser_engine` on a machine
  with a Chromium-family browser. Uses the app's real `SessionSupervisor`.

  A DataCase (not plain ExUnit) so the scope-gate test's synchronous
  `Scope.guard` has a sandbox connection to persist its Sentinel event; the
  browser processes themselves never touch the DB.
  """
  use BusterClaw.DataCase, async: false

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

  test "the scope gate blocks a real navigation before it reaches the engine" do
    alias BusterClaw.BrowserControl
    alias BusterClaw.BrowserControl.{Scope, Session}

    {:ok, pool} = Pool.start_link(name: nil, max_sessions: 1, idle_ms: 60_000)
    {:ok, s} = Pool.checkout(pool)

    scope = Scope.new("read example", ["example.com"], id: "live-gate")

    # In scope: the engine actually navigates and the session records the url.
    assert {:ok, _origin} = BrowserControl.navigate(s, scope, "https://example.com/")
    in_scope_url = Session.info(s).url
    assert in_scope_url == "https://example.com/"

    # Out of scope: halted, and the session's url is unchanged — the engine
    # never saw evil.com.
    assert {:halt, :out_of_scope, _} = BrowserControl.navigate(s, scope, "https://evil.com/")
    assert Session.info(s).url == in_scope_url

    # Payment page on the allowed host: halted the same way.
    assert {:halt, :payment_stop, _} =
             BrowserControl.navigate(s, scope, "https://example.com/checkout")

    assert Session.info(s).url == in_scope_url
  end

  test "a real HTTP redirect is authorized where it LANDED, not where it was sent" do
    alias BusterClaw.BrowserControl
    alias BusterClaw.BrowserControl.Scope

    {:ok, pool} = Pool.start_link(name: nil, max_sessions: 1, idle_ms: 60_000)
    {:ok, s} = Pool.checkout(pool)

    # amazon.com 301s to www.amazon.com — a real cross-host redirect, and both
    # are in scope (subdomains of an allowed domain are allowed), so the gate
    # permits it and the origin must describe the landing.
    scope = Scope.new("redirect check", ["amazon.com"], id: "live-redirect")

    assert {:ok, origin} = BrowserControl.navigate(s, scope, "https://amazon.com/")

    # The engine really does land on the www host. Before Finding 6 the origin
    # echoed the request, so this read "amazon.com" and the app believed it.
    assert origin.url == "https://www.amazon.com/"
    assert origin.host == "www.amazon.com"
    assert origin.redirected_from == "https://amazon.com/"

    # And the session agrees, rather than reporting what it was asked for.
    assert Session.info(s).url == "https://www.amazon.com/"
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
