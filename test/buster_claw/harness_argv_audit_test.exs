defmodule BusterClaw.HarnessArgvAuditTest do
  @moduledoc """
  The audit that should have existed before codex and opencode shipped.

  Three bugs reached the operator on 08-04 and every one was the same shape: a
  code path that had only ever been walked on claude. `--append-system-prompt`
  in a codex argv, claude's MCP flags in a codex argv, and claude's stream parsed
  by the codex normalizer. The suite was green through all three, because no test
  ran anything on a harness other than claude.

  This file walks every remaining argv- and stream-handling path on a NON-claude
  harness, and asserts the two invariants that hold the money paths together:

    1. A surface pinned to claude must actually be claude at the call site, and
       the files that hardcode claude's vocabulary must fail loudly if that pin
       is ever lifted without them being updated.
    2. A surface that is NOT pinned must carry no claude-only flag at all.
  """
  # async: false — writes the `model_policy` Settings row.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{AgentBackend, Dispatch, Dispatcher, ModelPolicy, Orchestration, Swarm}
  alias BusterClaw.Swarm.Coordinator

  # Every flag in this list is claude's spelling and is REJECTED by codex, not
  # ignored by it — `error: unexpected argument`, exit 2. Measured 08-03/08-04.
  @claude_only_flags ~w(
    --append-system-prompt
    --allowedTools
    --disallowedTools
    --strict-mcp-config
    --mcp-config
    --output-format
    --permission-mode
    --resume
  )

  defp capturing_runner(test_pid) do
    fn _prompt, opts ->
      send(test_pid, {:run_opts, opts})
      {:ok, %{agent: :stub, exit_status: 0, output: "", duration_ms: 1}}
    end
  end

  defp claude_only_flags_in(opts) do
    opts
    |> Keyword.get(:extra_args, [])
    |> Enum.filter(&(&1 in @claude_only_flags))
  end

  describe "the pinned money surfaces" do
    # trading.ex and trading_order.ex hardcode claude's tool flags and claude's
    # stream format, and parse with the claude normalizer. That is correct ONLY
    # because ModelPolicy pins those surfaces. If the pin is lifted without those
    # two files being rewritten, the argv is rejected and the anti-fabrication
    # check misreads its own stream — so the pin is asserted here, next to the
    # assumption it licenses.
    test "are pinned, which is what licenses their hardcoded claude vocabulary" do
      assert ModelPolicy.claude_only?(:trading_read)
      assert ModelPolicy.claude_only?(:order_submit)
    end

    test "resolve to claude even when the operator has chosen otherwise" do
      {:ok, _} = ModelPolicy.put_backend(:default, :codex)

      assert ModelPolicy.backend_for(:trading_read) == :claude
      assert ModelPolicy.backend_for(:order_submit) == :claude
    end
  end

  describe "the unpinned surfaces carry no claude-only flag" do
    setup do
      {:ok, _} = ModelPolicy.put_backend(:default, :codex)
      :ok
    end

    test "the dispatcher's queue run" do
      {:ok, _shift} = Orchestration.start_shift(unattended: true)
      {:ok, _item} = Dispatch.enqueue(%{source: "gmail", dedupe_key: "audit-dispatcher"})

      server =
        start_supervised!(
          {Dispatcher,
           [
             runner: capturing_runner(self()),
             autostart: false,
             subscribe: false,
             cooldown_ms: 0,
             interval_ms: 60_000
           ]}
        )

      Dispatcher.tick_now(server)

      assert_receive {:run_opts, opts}, 1_000
      assert Keyword.fetch!(opts, :agent) == :codex

      assert claude_only_flags_in(opts) == [],
             "the dispatcher would hand codex a flag it rejects"
    end

    test "the swarm planner" do
      Coordinator.plan("goal",
        planner_runner: capturing_runner(self()),
        max: 2
      )

      assert_receive {:run_opts, opts}
      assert Keyword.fetch!(opts, :agent) == :codex
      assert claude_only_flags_in(opts) == []
    end

    test "every swarm sub-run" do
      Swarm.run([%{role: "a", prompt: "p"}], runner: capturing_runner(self()))

      assert_receive {:run_opts, opts}
      assert Keyword.fetch!(opts, :agent) == :codex
      assert claude_only_flags_in(opts) == []
    end
  end

  describe "the harness table itself" do
    # The generated argv for a harness must never contain another harness's
    # spelling. This is the check that would have caught `--append-system-prompt`
    # in a codex argv without anyone thinking to look for it.
    test "no backend's own argv contains a flag another backend rejects" do
      for backend <- AgentBackend.order(), backend != :claude do
        argv =
          AgentBackend.argv(backend, "prompt",
            stream: true,
            model: "m",
            permission_mode: "dontAsk"
          )

        for flag <- @claude_only_flags do
          refute flag in argv, "#{backend}'s argv contains claude's #{flag}"
        end
      end
    end

    test "claude's own argv is unchanged by all of this" do
      argv = AgentBackend.argv(:claude, "prompt", stream: true, permission_mode: "dontAsk")

      assert argv == [
               "-p",
               "prompt",
               "--permission-mode",
               "dontAsk",
               "--output-format",
               "stream-json",
               "--verbose"
             ]
    end
  end
end
