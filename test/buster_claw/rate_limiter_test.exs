defmodule BusterClaw.RateLimiterTest do
  # async: false — toggles the global :rate_limit_* config and the shared counter.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Commands, RateLimiter, Sentinel}

  setup do
    prev = %{
      enabled: Application.get_env(:buster_claw, :rate_limit_enabled),
      default: Application.get_env(:buster_claw, :rate_limit_default),
      window: Application.get_env(:buster_claw, :rate_limit_window_ms),
      overrides: Application.get_env(:buster_claw, :rate_limit_overrides)
    }

    # One wide window so a test's calls all land in the same bucket; low limit.
    Application.put_env(:buster_claw, :rate_limit_enabled, true)
    Application.put_env(:buster_claw, :rate_limit_default, 3)
    Application.put_env(:buster_claw, :rate_limit_window_ms, 60_000)
    Application.put_env(:buster_claw, :rate_limit_overrides, %{})
    RateLimiter.reset()

    on_exit(fn ->
      # DELETE what was absent rather than writing nil back. Only
      # `:rate_limit_enabled` is set in config/test.exs; the other three read
      # back as nil, and putting nil is NOT the same as leaving them unset —
      # `get_env/3`'s default does not apply to a key explicitly set to nil. A
      # nil window made the supervised sweeper raise on its next tick, and its
      # restarts took the Repo down with them: hundreds of unrelated tests
      # failing, intermittently, long after this file finished.
      restore(:rate_limit_enabled, prev.enabled)
      restore(:rate_limit_default, prev.default)
      restore(:rate_limit_window_ms, prev.window)
      restore(:rate_limit_overrides, prev.overrides)
      RateLimiter.reset()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:buster_claw, key)
  defp restore(key, value), do: Application.put_env(:buster_claw, key, value)

  # The guard for the class of bug, not just the instance: whatever is wrong
  # with the config, the sweeper is supervised and must not be able to take the
  # application down on its next tick.
  test "a nil window does not kill the supervised sweeper" do
    Application.put_env(:buster_claw, :rate_limit_window_ms, nil)
    pid = Process.whereis(RateLimiter)

    send(pid, :sweep)

    # Still the same process, still answering — not restarted, not dead.
    assert Process.alive?(pid)
    assert RateLimiter.reset() == :ok
    assert Process.whereis(RateLimiter) == pid
  end

  test "allows up to the limit, then rate-limits" do
    assert :ok = RateLimiter.check(:agent_untrusted, "gmail_search")
    assert :ok = RateLimiter.check(:agent_untrusted, "gmail_search")
    assert :ok = RateLimiter.check(:agent_untrusted, "gmail_search")
    assert {:error, :rate_limited} = RateLimiter.check(:agent_untrusted, "gmail_search")
  end

  test "limit is per-{caller, command} — distinct keys have independent quota" do
    for _ <- 1..3, do: RateLimiter.check(:agent_untrusted, "gmail_search")
    assert {:error, :rate_limited} = RateLimiter.check(:agent_untrusted, "gmail_search")

    # A different command, and a different caller, are unaffected.
    assert :ok = RateLimiter.check(:agent_untrusted, "drive_list")
    assert :ok = RateLimiter.check(:trusted, "gmail_search")
  end

  test "per-command override beats the default limit" do
    Application.put_env(:buster_claw, :rate_limit_overrides, %{"document_list" => 1})

    assert :ok = RateLimiter.check(:mcp, "document_list")
    assert {:error, :rate_limited} = RateLimiter.check(:mcp, "document_list")
  end

  test "disabled limiter always allows" do
    Application.put_env(:buster_claw, :rate_limit_enabled, false)
    for _ <- 1..50, do: assert(:ok = RateLimiter.check(:mcp, "gmail_search"))
  end

  test "reset clears counters" do
    for _ <- 1..3, do: RateLimiter.check(:agent, "document_list")
    assert {:error, :rate_limited} = RateLimiter.check(:agent, "document_list")

    RateLimiter.reset()
    assert :ok = RateLimiter.check(:agent, "document_list")
  end

  test "enforced end-to-end at Commands.call and audited" do
    # `document_list` is a safe read; three pass, the fourth is rate-limited.
    for _ <- 1..3, do: assert({:ok, _} = Commands.call("document_list", %{}, caller: :trusted))

    assert {:error, :rate_limited} = Commands.call("document_list", %{}, caller: :trusted)

    assert Enum.any?(
             Sentinel.list_events(limit: 50),
             &(&1.category == "security_block" and &1.metadata["reason"] == "rate_limited")
           )
  end
end
