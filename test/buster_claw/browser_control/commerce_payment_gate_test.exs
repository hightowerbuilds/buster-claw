defmodule BusterClaw.BrowserControl.CommercePaymentGateTest do
  @moduledoc """
  The payment gate as the *run* actually experiences it, on real Amazon URLs.

  Why this file exists: on 07-25 the gate failed open on Amazon, and every test
  in the suite passed. `ScopeTest` proved the policy against paths we invented
  (`/checkout/`), and `AgentModeTest` proved the handoff against a `StubNav`
  that fakes the decision with `String.contains?(url, "checkout")` — so nothing
  in the suite ever asked the real `Scope` about a real checkout URL, which is
  the only question that mattered.

  Everything here therefore runs the **real** gate. `StubNav` is not used; the
  session double exists only to prove the browser is never reached.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl
  alias BusterClaw.BrowserControl.{AgentMode, Scope}
  alias BusterClaw.BrowserControl.Commerce.Cart

  # Amazon's real checkout funnel — the shapes the original regex let through.
  @amazon_checkout "https://www.amazon.com/gp/buy/spc/handlers/display.html"
  @amazon_payselect "https://www.amazon.com/gp/buy/payselect/handlers/display.html"
  @amazon_cart "https://www.amazon.com/gp/cart/view.html"
  @amazon_product "https://www.amazon.com/dp/B08N5WRWNW"

  # A pid that is guaranteed dead: if the gate ever falls through, the call to
  # Session.navigate/2 exits :noproc and the test fails loudly rather than
  # quietly navigating. "Never reached the browser" is asserted, not assumed.
  defp dead_session do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
    pid
  end

  describe "BrowserControl.navigate/3 — the real wiring, not a stand-in" do
    test "Amazon's checkout and payment URLs halt before the browser is touched" do
      scope = Scope.new("buy 45in boot laces and superglue", ["amazon.com"], id: "gate_test")
      session = dead_session()

      for url <- [@amazon_checkout, @amazon_payselect] do
        assert {:halt, :payment_stop, meta} = BrowserControl.navigate(session, scope, url),
               "payment gate failed OPEN on #{url}"

        assert meta.url == url
      end
    end

    test "the halt lands on the Sentinel feed with its scope and intent" do
      scope = Scope.new("buy boot laces", ["amazon.com"], id: "gate_sentinel")

      assert {:halt, :payment_stop, _} =
               BrowserControl.navigate(dead_session(), scope, @amazon_checkout)

      events = BusterClaw.Sentinel.list_events(limit: 5)
      block = Enum.find(events, &(&1.category == "security_block"))

      assert block, "a payment halt must be visible on the security feed"
      assert block.metadata["scope_id"] == "gate_sentinel"
      assert block.metadata["intent"] == "buy boot laces"
    end

    test "shopping URLs on the same host are not halted by the gate" do
      scope = Scope.new("buy boot laces", ["amazon.com"], id: "gate_allow")

      # These must pass the gate and reach the session layer. The session is
      # dead, so `Session.navigate` answers `:session_gone` — an answer only
      # reachable *past* the gate, which is the property under test. A halt
      # here would mean the gate over-fired on ordinary shopping.
      for url <- [@amazon_cart, @amazon_product] do
        assert {:error, :session_gone} = BrowserControl.navigate(dead_session(), scope, url),
               "gate over-halted an ordinary shopping URL: #{url}"
      end
    end
  end

  describe "a commerce run reaching Amazon checkout" do
    # The real gate, composed exactly as BrowserControl.navigate/3 composes it,
    # with an injectable session so "the browser was never navigated" is exact.
    defmodule GuardedNav do
      def navigate(session, %Scope{} = scope, url) do
        case Scope.guard(scope, {:navigate, url}) do
          {:ok, origin} ->
            Agent.update(session, &[url | &1])
            {:ok, origin}

          halt ->
            halt
        end
      end
    end

    setup do
      {:ok, session} = Agent.start_link(fn -> [] end)
      scope = Scope.new("buy 45in boot laces", ["amazon.com"], id: "commerce_gate")

      {:ok, run} =
        AgentMode.start_link(
          scope: scope,
          session: session,
          navigate_mod: GuardedNav,
          on_payment: :handoff,
          clock: fn -> 0 end
        )

      {:ok, :agent_working} = AgentMode.start_run(run)
      %{run: run, session: session}
    end

    test "hands off to the human instead of walking into checkout", %{
      run: run,
      session: session
    } do
      # Shopping proceeds.
      assert {:ok, _origin} = AgentMode.navigate(run, @amazon_product)
      assert {:ok, _origin} = AgentMode.navigate(run, @amazon_cart)

      cart =
        Cart.new()
        |> then(fn c ->
          {:ok, c} = Cart.add_item(c, "Benchmark Waxed Kevlar Boot Laces", 1495, 1)
          c
        end)
        |> then(fn c ->
          {:ok, c} = Cart.add_item(c, "Gorilla Super Glue", 876, 1)
          c
        end)

      {:ok, %{total_cents: 2371}} = AgentMode.put_cart(run, cart)

      # "Proceed to checkout" — the step the field test never empirically walked.
      assert {:handoff, :payment, meta} = AgentMode.navigate(run, @amazon_checkout)
      assert meta[:url] == @amazon_checkout

      # The mode is the whole point: acting is only legal in agent_working.
      assert AgentMode.mode(run) == :awaiting_human

      # The cart the human is shown is the frozen one, cent-exact.
      assert meta[:cart].total_cents == 2371

      # The checkout URL never reached the browser; the shopping URLs did.
      assert Agent.get(session, &Enum.reverse/1) == [@amazon_product, @amazon_cart]
    end

    test "the agent can neither act nor navigate once it is awaiting_human", %{run: run} do
      assert {:handoff, :payment, _} = AgentMode.navigate(run, @amazon_checkout)

      assert {:error, {:not_acting, :awaiting_human}} =
               AgentMode.act(run, :click, %{"text" => "Place your order"})

      # Stronger than the gate alone: after the handoff the agent cannot even
      # attempt the next payment URL, because navigation is gated on the acting
      # mode before the scope is ever consulted. The human owns the browser now.
      assert {:error, {:not_acting, :awaiting_human}} =
               AgentMode.navigate(run, @amazon_payselect)
    end
  end
end
