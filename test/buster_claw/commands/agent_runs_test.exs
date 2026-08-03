defmodule BusterClaw.Commands.AgentRunsTest do
  @moduledoc """
  The run commands with a stubbed session starter (no Chromium from a test):
  start registers a discoverable, supervised run that outlives the caller;
  status projects mode/summary/cart; stop halts the run and its session.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl.AgentMode
  alias BusterClaw.BrowserControl.Commerce.Cart
  alias BusterClaw.Commands

  # A "session": a GenServer that tolerates Session.lease's cast, answers
  # Session.navigate's call, and stops cleanly under Session.stop. It remembers
  # the last URL so the scripted surface can answer `location.href` — the
  # post-navigation landing check (Finding 6) reads it on every navigation.
  defmodule StubSession do
    use GenServer
    def start, do: GenServer.start(__MODULE__, :ok)
    @impl true
    def init(:ok), do: {:ok, %{url: nil}}
    @impl true
    def handle_cast(_msg, state), do: {:noreply, state}
    @impl true
    def handle_call({:navigate, url, _timeout}, _from, state),
      do: {:reply, :ok, %{state | url: url}}

    def handle_call(:last_url, _from, state), do: {:reply, state.url, state}
    def handle_call(_msg, _from, state), do: {:reply, {:error, :stub}, state}
  end

  # A scripted stand-in for `Session` (set via :agent_run_session_mod): the CDP
  # command surface the run's acts use, plus navigation, which since Finding 6
  # also flows through this module rather than straight to `Session`.
  defmodule ScriptedSessionMod do
    defdelegate navigate(session, url), to: BusterClaw.BrowserControl.Session

    # The confirmation screenshot. Without this the run process dies mid-capture
    # and the "happy path" silently stops being happy.
    def command(_session, "Page.captureScreenshot", _params),
      do: {:ok, %{"data" => Base.encode64("png-bytes")}}

    def command(session, "Runtime.evaluate", %{"expression" => js}) do
      value =
        cond do
          # Page.read / extract — must be checked first, its JS also mentions
          # location.href.
          js =~ "text: (document.body" ->
            %{"url" => "https://example.com/x", "title" => "X", "text" => "plenty of page text"}

          # Page.current — the landing read. Echoing the requested URL is the
          # "nothing redirected" case.
          js =~ "location.href" ->
            %{"url" => GenServer.call(session, :last_url), "title" => "X"}

          true ->
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

  defp paper_cart do
    {:ok, cart} =
      Cart.add_item(
        Cart.new(),
        "Printer paper",
        1299,
        2
      )

    cart
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
      Cart.add_item(
        Cart.new(),
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
    assert Commands.command_tier("agent_run_finish") == :restricted
    assert Commands.command_tier("agent_run_resume") == :restricted
    assert Commands.command_tier("agent_run_confirm_purchase") == :restricted
    refute Commands.command_gated?("agent_run_start")
  end

  # The 07-25 field test's Finding 2 — "confirm_purchase has no command surface"
  # — answered 08-03 by operator decision: the agent may confirm. It spends
  # nothing (the human already paid by hand); what it costs is that the receipt
  # asserts a purchase no human affirmed, which is why provenance is recorded.
  describe "confirming a purchase from the command surface" do
    test "an agent confirmation receipts the run and marks who said so" do
      started = start!(%{"commerce" => true, "domains" => ["shop.com"]})
      run = AgentMode.whereis(started.run_id)

      {:ok, _} = AgentMode.put_cart(run, paper_cart())
      {:ok, :awaiting_human} = AgentMode.request_human(run, "pay")

      assert {:ok, receipt} =
               Commands.agent_run_confirm_purchase(%{
                 "id" => started.run_id,
                 "confirmation" => "  ORDER-77  "
               })

      assert receipt.confirmed_by == :agent
      assert receipt.confirmation == "ORDER-77"
      assert receipt.cart["total_cents"] == 2598
      assert AgentMode.mode(run) == :done
    end

    # The guards are the real floor: the agent cannot conjure a receipt for a run
    # that never reached a payment handoff, however it was asked to.
    test "it refuses a run that never handed off, and one with no cart" do
      # A cart, but still shopping — no payment handoff ever happened.
      working = start!(%{"commerce" => true, "domains" => ["shop.com"]})
      {:ok, _} = AgentMode.put_cart(AgentMode.whereis(working.run_id), paper_cart())

      assert {:error, {:not_awaiting_human, :agent_working}} =
               Commands.agent_run_confirm_purchase(%{"id" => working.run_id})

      # Waiting on the human, but nothing was ever put in front of them.
      cartless = start!(%{"commerce" => true, "domains" => ["shop.com"]})
      {:ok, :awaiting_human} = AgentMode.request_human(AgentMode.whereis(cartless.run_id), "pay")

      assert {:error, :empty_cart} =
               Commands.agent_run_confirm_purchase(%{"id" => cartless.run_id})
    end

    test "it names a missing run and a missing id rather than guessing" do
      assert {:error, :run_not_found} =
               Commands.agent_run_confirm_purchase(%{"id" => "ghost"})

      assert {:error, :missing_id} = Commands.agent_run_confirm_purchase(%{})
    end
  end

  # The 07-25 field test's "Final mode: stopped — not done": there was no verb
  # for finishing, so a completed errand could only be halted, and a run that
  # simply stopped calling sat in agent_working forever holding its session.
  describe "finishing a run" do
    test "finish ends the run as done and shuts its session down", %{session: session} do
      started = start!()
      run = AgentMode.whereis(started.run_id)

      assert {:ok, %{mode: :done}} = Commands.agent_run_finish(%{"id" => started.run_id})
      assert AgentMode.mode(run) == :done

      # Done is terminal and non-acting, exactly like stopped — and the browser
      # window does not outlive the errand.
      assert {:error, {:not_acting, :done}} = AgentMode.navigate(run, "https://example.com/")
      refute Process.alive?(session)
    end

    test "a handoff can be finished by the human's side without resuming" do
      started = start!(%{"commerce" => true, "domains" => ["shop.com"]})
      run = AgentMode.whereis(started.run_id)
      {:ok, :awaiting_human} = AgentMode.request_human(run, "pay")

      assert {:ok, %{mode: :done}} = Commands.agent_run_finish(%{"id" => started.run_id})
    end

    test "finishing twice names the mode rather than pretending" do
      started = start!()
      assert {:ok, %{mode: :done}} = Commands.agent_run_finish(%{"id" => started.run_id})

      assert {:error, {:not_finishable, :done}} =
               Commands.agent_run_finish(%{"id" => started.run_id})
    end

    test "typed refusals" do
      assert {:error, :missing_id} = Commands.agent_run_finish(%{})
      assert {:error, :run_not_found} = Commands.agent_run_finish(%{"id" => "nope"})
    end
  end

  describe "resuming after a handoff" do
    test "resume returns the wheel to the agent, which can then act again" do
      started = start!(%{"commerce" => true, "domains" => ["shop.com"]})
      run = AgentMode.whereis(started.run_id)
      {:ok, :awaiting_human} = AgentMode.request_human(run, "pay")

      # Only agent_working acts, so a handoff with no resume verb was a run that
      # could do nothing at all from this surface.
      assert {:error, {:not_acting, :awaiting_human}} = AgentMode.act(run, :read, %{})

      assert {:ok, %{mode: :agent_working}} =
               Commands.agent_run_resume(%{"id" => started.run_id})

      assert {:ok, _result} =
               Commands.agent_run_act(%{"id" => started.run_id, "action" => "read"})
    end

    test "resume refuses when the run was not awaiting anyone" do
      started = start!()

      assert {:error, {:not_resumable, :agent_working}} =
               Commands.agent_run_resume(%{"id" => started.run_id})
    end

    test "typed refusals" do
      assert {:error, :missing_id} = Commands.agent_run_resume(%{})
      assert {:error, :run_not_found} = Commands.agent_run_resume(%{"id" => "nope"})
    end
  end
end
