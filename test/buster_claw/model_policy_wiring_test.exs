defmodule BusterClaw.ModelPolicyWiringTest do
  # async: false — every case writes the `model_policy` Settings row (SQLite
  # serializes writers), and the surfaces under test resolve their model from
  # processes the shared sandbox has to lend a connection to.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Agent.Chat
  alias BusterClaw.{Dispatch, Dispatcher, ModelPolicy}
  alias BusterClaw.{Orchestration, Swarm}
  alias BusterClaw.Swarm.Coordinator

  # These assert on the opts the PRODUCTION code hands its runner, never on
  # `ModelPolicy.for_surface/1` — that resolution is `model_policy_test.exs`'s
  # job, and re-asserting it here would pass whether or not the wiring exists.

  setup do
    tmp = Path.join(System.tmp_dir!(), "bc_mpw_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_env(:workspace_root, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  # A runner/spawner stand-in that reports the opts it was actually handed.
  defp capturing_runner(
         test_pid,
         result \\ {:ok, %{agent: :stub, exit_status: 0, output: "", duration_ms: 1}}
       ) do
    fn _prompt, opts ->
      send(test_pid, {:run_opts, opts})
      result
    end
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:buster_claw, key)
    Application.put_env(:buster_claw, key, value)

    on_exit(fn ->
      case previous do
        {:ok, prev} -> Application.put_env(:buster_claw, key, prev)
        :error -> Application.delete_env(:buster_claw, key)
      end
    end)
  end

  defp wait_until(fun, retries \\ 200)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, retries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, retries - 1)
    end
  end

  # Phase 2's whole point: an operator can choose the HARNESS, not just the model,
  # and the choice reaches a real run. Before this, `detect/0` picked by PATH
  # order and codex was unreachable on any machine that had claude installed.
  #
  # Asserted on the dispatcher rather than a trading surface: the money surfaces
  # are pinned to claude (their confinement flags are claude-only), so they are
  # the wrong place to prove a harness choice travels.
  describe "the chosen harness reaches the runner" do
    test "a backend set for a surface is passed as :agent" do
      {:ok, _} = ModelPolicy.put_backend(:dispatcher, :codex)
      {:ok, _shift} = Orchestration.start_shift(unattended: true)
      {:ok, _item} = Dispatch.enqueue(%{source: "gmail", dedupe_key: "mpw-agent"})

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
    end
  end

  # The floored money surfaces left with the trading stack on 08-08. The wiring
  # they proved — that a floor reaches the runner's argv, not just the policy
  # table — is asserted for the surfaces that remain in "the remaining surfaces".

  describe "the remaining surfaces" do
    test "the dispatcher's queue run carries the :dispatcher model" do
      {:ok, _} = ModelPolicy.put(:dispatcher, "claude-opus-5")
      {:ok, _shift} = Orchestration.start_shift(unattended: true)
      {:ok, _item} = Dispatch.enqueue(%{source: "gmail", dedupe_key: "mpw-dispatcher"})

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
      assert Keyword.fetch!(opts, :model) == "claude-opus-5"
    end

    test "the planner run carries the :swarm_planner model" do
      {:ok, _} = ModelPolicy.put(:swarm_planner, "claude-fable-5")
      plan = ~s([{"role":"reader","prompt":"read"}])

      planner =
        capturing_runner(self(), {:ok, %{agent: :stub, exit_status: 0, output: plan}})

      assert {:ok, [%{role: "reader"}]} = Coordinator.plan("goal", planner_runner: planner)

      assert_receive {:run_opts, opts}
      assert Keyword.fetch!(opts, :model) == "claude-fable-5"
    end

    test "every swarm sub-run carries the :swarm_run model" do
      {:ok, _} = ModelPolicy.put(:swarm_run, "claude-opus-5")

      assert {:ok, _summary} =
               Swarm.run([%{role: "reader", prompt: "read"}],
                 runner: capturing_runner(self()),
                 quorum: 1
               )

      assert_receive {:run_opts, opts}
      assert Keyword.fetch!(opts, :model) == "claude-opus-5"
    end

    # Chat resolves in `default_spawner/2`, so the injectable spawner seam can't
    # see it — deliberately, since the chat unit tests run outside the DB
    # sandbox. This drives the REAL spawner against a stand-in `claude` that
    # records its own argv, which proves more anyway: the flag reaches the CLI.
    test "a chat turn passes the :chat model through to the CLI argv", %{tmp: tmp} do
      {:ok, _} = ModelPolicy.put(:chat, "claude-opus-5")
      argv_file = Path.join(tmp, "argv.txt")
      put_env(:agent_cli, {:claude, fake_cli!(tmp, argv_file)})

      conv_id = "mpw-#{System.unique_integer([:positive])}"
      {:ok, pid} = Chat.start_link(conv_id: conv_id, persist: false, audit: false)

      :ok = Chat.send_message(conv_id, "hello")

      wait_until(fn -> File.exists?(argv_file) end)
      assert File.read!(argv_file) =~ "--model claude-opus-5"

      # Stop it here rather than leaving it to the test process's link: a linked
      # Chat dies only once this test returns, so its in-flight DB work races the
      # sandbox owner's exit and logs a "client exited" disconnect. Deterministic
      # teardown, not a correctness fix.
      :ok = GenServer.stop(pid)
    end
  end

  # A stand-in for the operator's `claude`: records the argv it was given and
  # exits clean, so nothing here depends on a real CLI being installed.
  defp fake_cli!(dir, argv_file) do
    path = Path.join(dir, "fake-claude")
    File.write!(path, "#!/bin/sh\nprintf '%s\\n' \"$*\" > #{argv_file}\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end
end
