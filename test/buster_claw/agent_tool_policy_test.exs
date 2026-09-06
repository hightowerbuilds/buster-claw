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

  # `web_capable_builtins/0` survives as the declaration a future web-capable
  # profile would subtract (the last one, `:chartbuild`, left 08-08), and is
  # asserted in "the strict default" above.

  describe "the :dispatcher profile" do
    test "subtracts exactly the shell and a file read, nothing else" do
      strict = AgentToolPolicy.denied_builtins()
      dispatcher = AgentToolPolicy.denied_builtins(:dispatcher)

      assert strict -- dispatcher == ~w(Bash BashOutput KillShell Read)
      assert dispatcher -- strict == [], "a profile may only subtract, never add"
    end

    test "still denies writes, sub-agents, and the whole web" do
      dispatcher = AgentToolPolicy.denied_builtins(:dispatcher)

      for tool <- ~w(Edit Write NotebookEdit Task WebFetch WebSearch) do
        assert tool in dispatcher, "#{tool} must stay denied to the unattended worker"
      end
    end
  end
end
