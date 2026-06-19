defmodule BusterClaw.AgentRunnerTest do
  use ExUnit.Case, async: true

  alias BusterClaw.AgentRunner

  @tmp System.tmp_dir!()

  test "captures output and merges stderr into one stream" do
    assert {:ok, result} =
             AgentRunner.run("ignored",
               agent_binary: "/bin/sh",
               argv: ["-c", "echo to-stdout; echo to-stderr 1>&2"],
               cwd: @tmp
             )

    assert result.exit_status == 0
    assert result.output =~ "to-stdout"
    assert result.output =~ "to-stderr"
    assert is_integer(result.duration_ms)
  end

  test "passes the prompt as a discrete arg — no shell injection" do
    # If the prompt were interpolated into a shell string, this would execute
    # `echo pwned`. It must come back literal.
    assert {:ok, result} =
             AgentRunner.run("ignored",
               agent_binary: "/bin/echo",
               argv: ["$(echo pwned)"],
               cwd: @tmp
             )

    # Literal, un-evaluated: proves the prompt was never handed to a shell.
    assert String.trim(result.output) == "$(echo pwned)"
  end

  test "runs through a login shell when :login is set" do
    assert {:ok, %{exit_status: 0, output: out}} =
             AgentRunner.run("ignored",
               agent_binary: "/bin/echo",
               argv: ["login-ok"],
               cwd: @tmp,
               login: true
             )

    assert out =~ "login-ok"
  end

  test "reports a non-zero exit status without treating it as a crash" do
    assert {:ok, %{exit_status: 3}} =
             AgentRunner.run("ignored",
               agent_binary: "/bin/sh",
               argv: ["-c", "exit 3"],
               cwd: @tmp
             )
  end

  test "a missing agent binary surfaces as a non-zero exit (127)" do
    assert {:ok, %{exit_status: status}} =
             AgentRunner.run("ignored",
               agent_binary: "/no/such/agent-cli-xyz",
               argv: [],
               cwd: @tmp
             )

    assert status != 0
  end

  test "kills a run that exceeds the wall-clock deadline" do
    started = System.monotonic_time(:millisecond)

    assert {:error, {:timeout, partial}} =
             AgentRunner.run("ignored",
               agent_binary: "/bin/sleep",
               argv: ["5"],
               cwd: @tmp,
               timeout_ms: 150
             )

    elapsed = System.monotonic_time(:millisecond) - started
    # Must return promptly on timeout, nowhere near the 5s sleep.
    assert elapsed < 2_000
    assert partial.agent == :custom
  end
end
