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

  test "a timeout reaps the agent's spawned grandchildren (process group)" do
    pidfile = Path.join(@tmp, "gc_#{System.unique_integer([:positive])}.pid")

    # The "agent" backgrounds a long-lived grandchild (a distinct process, NOT the
    # exec'd os_pid) and records its pid, then hangs. On timeout the whole process
    # group must be reaped — killing only the direct os_pid would leak the child.
    script = "sh -c 'echo $$ > #{pidfile}; exec sleep 30' & sleep 30"

    assert {:error, {:timeout, _partial}} =
             AgentRunner.run("ignored",
               agent_binary: "/bin/sh",
               argv: ["-c", script],
               cwd: @tmp,
               timeout_ms: 300
             )

    child_pid = wait_for_pid(pidfile)
    # After the group kill the grandchild must be gone.
    assert wait_until(fn -> not process_alive?(child_pid) end)
  end

  defp wait_for_pid(path, retries \\ 100)
  defp wait_for_pid(_path, 0), do: flunk("grandchild never recorded its pid")

  defp wait_for_pid(path, retries) do
    case File.read(path) do
      {:ok, raw} ->
        case Integer.parse(String.trim(raw)) do
          {pid, _} -> pid
          :error -> retry_pid(path, retries)
        end

      _ ->
        retry_pid(path, retries)
    end
  end

  defp retry_pid(path, retries) do
    Process.sleep(10)
    wait_for_pid(path, retries - 1)
  end

  defp process_alive?(pid) do
    match?(
      {_, 0},
      System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    )
  end

  defp wait_until(_fun, retries \\ 100)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, retries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, retries - 1)
    end
  end
end
