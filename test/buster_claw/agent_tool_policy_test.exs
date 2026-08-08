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

  # The `:chartbuild` profile — the only one that ever subtracted from the deny
  # list — left with Chart Build on 08-08. `web_capable_builtins/0` survives as
  # the declaration a future web-capable profile would subtract, and is asserted
  # in "the strict default" above.
end
