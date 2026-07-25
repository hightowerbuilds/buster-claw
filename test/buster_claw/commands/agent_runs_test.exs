defmodule BusterClaw.Commands.AgentRunsTest do
  @moduledoc """
  The run commands with a stubbed session starter (no Chromium from a test):
  start registers a discoverable, supervised run that outlives the caller;
  status projects mode/summary/cart; stop halts the run and its session.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl.AgentMode
  alias BusterClaw.Commands

  # A "session": a GenServer that tolerates Session.lease's cast, answers
  # Session.navigate's call, and stops cleanly under Session.stop.
  defmodule StubSession do
    use GenServer
    def start, do: GenServer.start(__MODULE__, :ok)
    @impl true
    def init(:ok), do: {:ok, :ok}
    @impl true
    def handle_cast(_msg, state), do: {:noreply, state}
    @impl true
    def handle_call({:navigate, _url, _timeout}, _from, state), do: {:reply, :ok, state}
    def handle_call(_msg, _from, state), do: {:reply, {:error, :stub}, state}
  end

  # A scripted CDP surface for the run's acts (set via :agent_run_session_mod).
  defmodule ScriptedSessionMod do
    def command(_session, "Runtime.evaluate", %{"expression" => js}) do
      value =
        if js =~ "text: (document.body" do
          %{"url" => "https://example.com/x", "title" => "X", "text" => "plenty of page text"}
        else
          %{"matched" => true, "clicked" => "Go", "filled" => "input"}
        end

      {:ok, %{"result" => %{"value" => value}}}
    end
  end

  setup do
    {:ok, session} = StubSession.start()
    Application.put_env(:buster_claw, :agent_run_session_starter, fn -> {:ok, session} end)
    Application.put_env(:buster_claw, :agent_run_session_mod, ScriptedSessionMod)

    on_exit(fn ->
      Application.delete_env(:buster_claw, :agent_run_session_starter)
      Application.delete_env(:buster_claw, :agent_run_session_mod)
      if Process.alive?(session), do: GenServer.stop(session)
    end)

    {:ok, session: session}
  end

  defp start!(args \\ %{}) do
    {:ok, started} =
      Commands.agent_run_start(
        Map.merge(
          %{"intent" => "compare standing desks", "domains" => ["example.com"]},
          args
        )
      )

    on_exit(fn ->
      case AgentMode.whereis(started.run_id) do
        nil -> :ok
        pid -> Process.exit(pid, :kill)
      end
    end)

    started
  end

  test "start launches a supervised, discoverable run that outlives the caller" do
    started =
      Task.await(
        Task.async(fn ->
          {:ok, started} =
            Commands.agent_run_start(%{
              "intent" => "compare standing desks",
              "domains" => ["example.com"]
            })

          started
        end)
      )

    on_exit(fn ->
      case AgentMode.whereis(started.run_id) do
        nil -> :ok
        pid -> Process.exit(pid, :kill)
      end
    end)

    # The task (the "command caller") is gone; the run is not.
    run = AgentMode.whereis(started.run_id)
    assert is_pid(run) and Process.alive?(run)
    assert started.mode == :agent_working
    assert started.commerce == false
    assert AgentMode.mode(run) == :agent_working
  end

  test "commerce: true starts a handoff run; status carries mode and cart" do
    started = start!(%{"commerce" => true})
    assert started.commerce == true

    run = AgentMode.whereis(started.run_id)

    {:ok, cart} =
      BusterClaw.BrowserControl.Commerce.Cart.add_item(
        BusterClaw.BrowserControl.Commerce.Cart.new(),
        "Desk",
        49_900
      )

    {:ok, _summary} = AgentMode.put_cart(run, cart)

    assert {:ok, status} = Commands.agent_run_status(%{"id" => started.run_id})
    assert status.mode == :agent_working
    assert status.cart.total_cents == 49_900
    assert status.summary.steps == 1

    # And the id-less form lists it.
    assert {:ok, %{runs: runs}} = Commands.agent_run_status(%{})
    assert Enum.any?(runs, &(&1.run_id == started.run_id))
  end

  test "stop halts the run and shuts its session down", %{session: session} do
    started = start!()
    run = AgentMode.whereis(started.run_id)

    assert {:ok, %{mode: :stopped}} = Commands.agent_run_stop(%{"id" => started.run_id})
    assert AgentMode.mode(run) == :stopped

    # The run refuses new actions and its browser session is gone with it.
    assert {:error, {:not_acting, :stopped}} = AgentMode.navigate(run, "https://example.com/")
    refute Process.alive?(session)
  end

  test "navigate drives the run under its scope: ok, halted, and handoff results" do
    started = start!(%{"commerce" => true, "domains" => ["shop.com"]})
    id = started.run_id

    assert {:ok, %{result: "ok", navigated: "https://shop.com/a"}} =
             Commands.agent_run_navigate(%{"id" => id, "url" => "https://shop.com/a"})

    # A payment page on a commerce run is a handoff carrying the frozen cart.
    {:ok, _} =
      Commands.agent_run_cart(%{
        "id" => id,
        "items" => [%{"name" => "Stapler", "unit_cents" => 899}]
      })

    assert {:ok, %{result: "handoff", cart: cart}} =
             Commands.agent_run_navigate(%{"id" => id, "url" => "https://shop.com/checkout"})

    assert cart.total_cents == 899

    # Off-scope halts (fresh run — the handoff left the last one awaiting_human).
    other = start!(%{"domains" => ["shop.com"]})

    assert {:ok, %{result: "halted", reason: :out_of_scope}} =
             Commands.agent_run_navigate(%{"id" => other.run_id, "url" => "https://evil.com/"})
  end

  test "act performs page actions; content comes back egress-prepared" do
    started = start!()
    id = started.run_id

    {:ok, _} = Commands.agent_run_navigate(%{"id" => id, "url" => "https://example.com/a"})

    assert {:ok, %{action: "click", result: %{"clicked" => "Go"}}} =
             Commands.agent_run_act(%{"id" => id, "action" => "click", "selector" => "#go"})

    assert {:ok, %{action: "extract", result: payload}} =
             Commands.agent_run_act(%{"id" => id, "action" => "extract"})

    # Egress-prepared payload (title/elements/text shape), not the raw page map.
    assert %{title: "X", text: text} = payload
    assert text =~ "plenty of page text"
    refute Map.has_key?(payload, "url")

    assert {:error, {:unknown_action, "teleport"}} =
             Commands.agent_run_act(%{"id" => id, "action" => "teleport"})
  end

  test "cart validates items before it ever reaches the run" do
    started = start!()
    id = started.run_id

    assert {:ok, summary} =
             Commands.agent_run_cart(%{
               "id" => id,
               "items" => [
                 %{"name" => "Paper", "unit_cents" => 1299, "qty" => 2},
                 %{"name" => "Stapler", "unit_cents" => 899}
               ]
             })

    assert summary.total_cents == 3497

    assert {:error, {:invalid_item, 1}} =
             Commands.agent_run_cart(%{"id" => id, "items" => [%{"name" => "x"}]})

    assert {:error, {:invalid_item, 2}} =
             Commands.agent_run_cart(%{
               "id" => id,
               "items" => [
                 %{"name" => "ok", "unit_cents" => 1},
                 %{"name" => "bad", "unit_cents" => -5}
               ]
             })
  end

  test "typed refusals: bad args and unknown runs" do
    assert {:error, :missing_intent_or_domains} = Commands.agent_run_start(%{"intent" => "x"})

    assert {:error, :missing_intent_or_domains} =
             Commands.agent_run_start(%{"intent" => "x", "domains" => []})

    assert {:error, :run_not_found} = Commands.agent_run_status(%{"id" => "ghost"})
    assert {:error, :run_not_found} = Commands.agent_run_stop(%{"id" => "ghost"})
    assert {:error, :missing_id} = Commands.agent_run_stop(%{})
  end

  test "the commands are in the catalog at the expected tiers" do
    assert Commands.command_tier("agent_run_start") == :restricted
    assert Commands.command_tier("agent_run_status") == :safe
    assert Commands.command_tier("agent_run_stop") == :restricted
    refute Commands.command_gated?("agent_run_start")
  end
end
