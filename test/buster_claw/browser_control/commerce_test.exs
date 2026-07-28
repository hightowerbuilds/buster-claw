defmodule BusterClaw.BrowserControl.CommerceTest do
  @moduledoc """
  The Phase 5 flow with stubs: an in-scope commerce run attaches a cart as it
  shops, a payment page HANDS OFF (not halts) showing that cart, and — only from
  awaiting_human with a non-empty run cart — the human's confirmation captures
  the page and finishes the run. No payment credential ever passes through the
  agent.
  """
  # async: false — points the global :workspace_root at a tmp captures dir.
  use ExUnit.Case, async: false

  alias BusterClaw.BrowserControl.{AgentMode, Commerce}
  alias BusterClaw.BrowserControl.AgentMode.Trajectory
  alias BusterClaw.BrowserControl.Commerce.Cart
  alias BusterClaw.BrowserControl.Scope

  # Scripted navigate: /checkout is a payment page, evil.com is off-merchant.
  defmodule StubNav do
    def navigate(_session, %Scope{} = scope, url, _opts \\ []) do
      cond do
        String.contains?(url, "evil") -> {:halt, :out_of_scope, %{url: url, host: "evil.com"}}
        String.contains?(url, "checkout") -> {:halt, :payment_stop, %{url: url, host: "shop.com"}}
        true -> {:ok, %{scope_id: scope.id, host: "shop.com", url: url}}
      end
    end
  end

  # A CDP surface that answers the confirmation screenshot.
  defmodule StubSession do
    def command(_session, "Page.captureScreenshot", _params),
      do: {:ok, %{"data" => Base.encode64("png-bytes")}}
  end

  # No `command/3` at all — an engine with no capture surface.
  defmodule NoCaptureSession do
  end

  setup do
    root = Path.join(System.tmp_dir!(), "bc_commerce_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp run(opts \\ []) do
    scope = Commerce.scope("buy office supplies", ["shop.com"], id: "buy1")

    {:ok, pid} =
      [
        scope: scope,
        session: :stub,
        session_mod: StubSession,
        navigate_mod: StubNav,
        clock: fn -> 0 end
      ]
      |> Keyword.merge(opts)
      |> Commerce.start_run()

    pid
  end

  defp cart do
    {:ok, c} = Cart.add_item(Cart.new(), "Printer paper", 1299, 2)
    {:ok, c} = Cart.add_item(c, "Stapler", 899)
    c
  end

  defp shop_to_handoff(pid) do
    AgentMode.start_run(pid)
    AgentMode.navigate(pid, "https://shop.com/cart")
    {:ok, _} = AgentMode.put_cart(pid, cart())
    AgentMode.navigate(pid, "https://shop.com/checkout")
  end

  test "a payment page hands off to the human, showing the total and full cart" do
    pid = run()

    assert {:handoff, :payment, meta} = shop_to_handoff(pid)
    assert AgentMode.mode(pid) == :awaiting_human

    # The handoff carries the cart the ledger will later bill.
    assert meta.cart.total == "$34.97"
    assert meta.cart.total_cents == 3497
    assert meta.cart.lines =~ "Printer paper"

    # ...and the trajectory step shows the same thing to the rail.
    step = AgentMode.trajectory(pid) |> Trajectory.last()
    assert step.type == :handoff
    assert step.outcome == :awaiting_human
    assert step.summary =~ "$34.97"
  end

  test "cart-building is watchable: put_cart records a :cart step" do
    pid = run()
    AgentMode.start_run(pid)

    assert {:ok, summary} = AgentMode.put_cart(pid, cart())
    assert summary.total_cents == 3497

    step = AgentMode.trajectory(pid) |> Trajectory.last()
    assert step.type == :cart
    assert step.summary =~ "Stapler"
  end

  test "the cart is frozen by the handoff — no updates while the human pays" do
    pid = run()
    {:handoff, :payment, _} = shop_to_handoff(pid)

    assert {:error, {:cart_frozen, :awaiting_human}} = AgentMode.put_cart(pid, cart())
  end

  test "an off-merchant navigation still halts (the merchant allowlist holds)" do
    pid = run()
    AgentMode.start_run(pid)
    assert {:halt, :out_of_scope, _} = AgentMode.navigate(pid, "https://evil.com/")
    assert AgentMode.mode(pid) == :halted
  end

  test "confirming after the handoff captures the page and finishes",
       %{root: root} do
    pid = run()
    {:handoff, :payment, _} = shop_to_handoff(pid)

    assert {:ok, receipt} = Commerce.confirm_purchase(pid, confirmation: "ORDER-123")

    assert receipt.run_id == "buy1"
    assert receipt.confirmation == "ORDER-123"
    assert receipt.cart["total_cents"] == 3497
    assert Enum.any?(receipt.cart["items"], &(&1["name"] == "Printer paper"))

    # The confirmation page was captured under the workspace and receipted.
    capture = receipt.confirmation_capture
    assert capture == Path.join([root, "browser-control", "captures", "buy1-confirmation.png"])
    assert File.read!(capture) == "png-bytes"

    # The run is finished.
    assert AgentMode.mode(pid) == :done
  end

  test "a missing capture surface degrades to a receipt without an image" do
    pid = run(session_mod: NoCaptureSession)
    {:handoff, :payment, _} = shop_to_handoff(pid)

    assert {:ok, receipt} = Commerce.confirm_purchase(pid)
    assert receipt.cart["total_cents"] == 3497
    assert receipt.confirmation_capture == nil
    assert AgentMode.mode(pid) == :done
  end

  test "refuses confirmation before a handoff has happened" do
    pid = run()
    AgentMode.start_run(pid)
    {:ok, _} = AgentMode.put_cart(pid, cart())

    # Still agent_working — no payment handoff yet.
    assert {:error, {:not_awaiting_human, :agent_working}} =
             Commerce.confirm_purchase(pid)
  end

  test "refuses when the run has no cart (nothing was shown, nothing can be billed)" do
    pid = run()
    AgentMode.start_run(pid)
    AgentMode.navigate(pid, "https://shop.com/checkout")

    assert {:error, :empty_cart} = Commerce.confirm_purchase(pid)
  end

  test "the receipt amount is exactly the cart total the human was shown" do
    pid = run()
    {:handoff, :payment, meta} = shop_to_handoff(pid)

    {:ok, receipt} = Commerce.confirm_purchase(pid)
    assert receipt.cart["total_cents"] == meta.cart.total_cents
  end
end
