defmodule BusterClaw.AgentToolPolicyTest do
  use ExUnit.Case, async: true

  alias BusterClaw.AgentToolPolicy

  describe "the strict default" do
    test "denies the shell, the filesystem, sub-agents, and the whole web" do
      denied = AgentToolPolicy.denied_builtins()

      for tool <- ~w(Bash BashOutput KillShell Edit Write NotebookEdit Read Glob Grep Task) do
        assert tool in denied, "#{tool} must stay denied by default"
      end

      assert "WebFetch" in denied
      assert "WebSearch" in denied
    end

    test "an unknown profile gets the strict default, not a permissive one" do
      # Fail closed: a typo'd or future profile name must not silently widen.
      assert AgentToolPolicy.denied_builtins(:nonexistent) == AgentToolPolicy.denied_builtins()
      assert AgentToolPolicy.denied_builtins(:robinhood) == AgentToolPolicy.denied_builtins()
    end
  end

  describe "the chartbuild profile" do
    test "subtracts exactly one entry, and that entry is WebSearch" do
      # The assertion is the SET DIFFERENCE, not "WebSearch is absent". Written
      # this way, widening Chart Build's surface has to change this test — which
      # is the point. A profile that quietly gained Bash would pass a test that
      # only checked for WebSearch.
      default = MapSet.new(AgentToolPolicy.denied_builtins())
      chartbuild = MapSet.new(AgentToolPolicy.denied_builtins(:chartbuild))

      assert MapSet.difference(default, chartbuild) == MapSet.new(["WebSearch"])
      assert MapSet.difference(chartbuild, default) == MapSet.new([])
    end

    test "WebFetch is still denied — it reaches loopback" do
      # Measured 08-03 (claude 2.1.220): WebFetch connects from the LOCAL
      # machine. 127.0.0.1:4000 with the BEAM listening gave `read ECONNRESET`;
      # 127.0.0.1:4999 with nothing listening gave `connect ECONNREFUSED`. Only
      # a host that sees this machine's sockets produces that pair, so WebFetch
      # is an SSRF path into our own command API with URLGuard nowhere in it.
      #
      # This test exists because the denial looks arbitrary in the code: one name
      # missing from one list, on the profile that is otherwise the web-capable
      # one. Without the reason recorded next to the assertion, the next reader
      # tidies it away.
      assert "WebFetch" in AgentToolPolicy.denied_builtins(:chartbuild)
    end

    test "the allowlist and the deny list cannot drift apart" do
      # `web_capable_builtins/0` is what ChartBuilder passes to --allowedTools,
      # and it must be exactly what `denied_builtins(:chartbuild)` subtracted.
      # If they diverge, a tool is either approved-but-denied (dead) or
      # denied-but-approved (a hole).
      default = MapSet.new(AgentToolPolicy.denied_builtins())
      chartbuild = MapSet.new(AgentToolPolicy.denied_builtins(:chartbuild))

      assert MapSet.difference(default, chartbuild) ==
               MapSet.new(AgentToolPolicy.web_capable_builtins())
    end

    test "web_capable_builtins is search only" do
      assert AgentToolPolicy.web_capable_builtins() == ["WebSearch"]
    end
  end

  describe "profiles that must never reach the web" do
    test "a broker-reading run gets the strict default" do
      # Trading and TradingOrder call denied_builtins/0. A run that can read the
      # broker has no business reaching the internet in the same conversation,
      # so there is deliberately no :robinhood profile that subtracts anything.
      assert "WebSearch" in BusterClaw.Trading.denied_tools()
      assert "WebFetch" in BusterClaw.Trading.denied_tools()
    end
  end
end
