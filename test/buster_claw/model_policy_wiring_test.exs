defmodule BusterClaw.ModelPolicyWiringTest do
  # async: false — every case writes the `model_policy` Settings row (SQLite
  # serializes writers), and the surfaces under test resolve their model from
  # processes the shared sandbox has to lend a connection to.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Agent.Chat
  alias BusterClaw.{AgentRunner, Dispatch, Dispatcher, ModelPolicy}
  alias BusterClaw.{Orchestration, Swarm, Trading, TradingOrder}
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

  defp order! do
    {:ok, order} =
      TradingOrder.parse("""
      Ready when you are.

      ```order
      {"side":"buy","symbol":"AAPL","quantity":2,"order_type":"limit",
       "limit_price":199.25,"time_in_force":"day","account_last4":"6587"}
      ```
      """)

    order
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

  describe "the money surfaces, where the floor is the point" do
    # The 07-28 measurement: haiku on a trading read invoked the broker tool in
    # only 1 of 2 runs, and on the miss it INVENTED the answer. An operator
    # economising globally must not be able to reach these two surfaces.
    test "a trading read runs at the floor even when the global default is haiku" do
      {:ok, _} = ModelPolicy.put(:default, "claude-haiku-4-5")
      put_env(:trading_agent_runner, capturing_runner(self()))

      _ = Trading.fetch_account_snapshot()

      assert_receive {:run_opts, opts}
      assert Keyword.fetch!(opts, :model) == "claude-sonnet-5"
    end

    test "an order submission runs at the floor even when the global default is haiku" do
      {:ok, _} = ModelPolicy.put(:default, "claude-haiku-4-5")
      put_env(:trading_submit_runner, capturing_runner(self()))

      _ = TradingOrder.submit(order!())

      assert_receive {:run_opts, opts}
      assert Keyword.fetch!(opts, :model) == "claude-sonnet-5"
    end

    # Naming the surface IS the deliberate gesture, so it is honoured.
    test "naming the surface explicitly still goes below the floor" do
      {:ok, _} = ModelPolicy.put(:trading_read, "claude-haiku-4-5")
      put_env(:trading_agent_runner, capturing_runner(self()))

      _ = Trading.fetch_account_snapshot()

      assert_receive {:run_opts, opts}
      assert Keyword.fetch!(opts, :model) == "claude-haiku-4-5"
    end
  end

  describe "the additive promise" do
    # An install that upgrades into this feature must run exactly as it did the
    # day before: no `--model`, not `--model ""`, not a named default.
    test "an empty policy leaves the money surfaces with no model to pass" do
      put_env(:trading_agent_runner, capturing_runner(self()))
      put_env(:trading_submit_runner, capturing_runner(self()))

      _ = Trading.fetch_account_snapshot()
      assert_receive {:run_opts, read_opts}
      assert Keyword.get(read_opts, :model) == nil

      _ = TradingOrder.submit(order!())
      assert_receive {:run_opts, submit_opts}
      assert Keyword.get(submit_opts, :model) == nil
    end

    test "a nil model reaches the CLI as NO --model argument" do
      assert {:ok, %{exit_status: 0, output: output}} =
               AgentRunner.run("prompt",
                 agent: :claude,
                 agent_binary: "/bin/echo",
                 cwd: System.tmp_dir!(),
                 model: nil
               )

      # The failure this test exists to catch is `--model ""` reaching claude.
      refute output =~ "--model"
    end

    test "a configured model reaches the CLI as a real --model argument" do
      assert {:ok, %{exit_status: 0, output: output}} =
               AgentRunner.run("prompt",
                 agent: :claude,
                 agent_binary: "/bin/echo",
                 cwd: System.tmp_dir!(),
                 model: "claude-opus-5"
               )

      assert output =~ "--model claude-opus-5"
    end
  end

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
      {:ok, _pid} = Chat.start_link(conv_id: conv_id, persist: false, audit: false)

      :ok = Chat.send_message(conv_id, "hello")

      wait_until(fn -> File.exists?(argv_file) end)
      assert File.read!(argv_file) =~ "--model claude-opus-5"
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
