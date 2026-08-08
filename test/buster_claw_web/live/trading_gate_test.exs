defmodule BusterClawWeb.TradingGateTest do
  @moduledoc """
  Trading is owned by the `trading-robinhood` extension, and is **absent** until
  it is installed — not merely unlinked.

  The review's complaint about this codebase was that unfinished surfaces look
  production-ready. The answer to it is not a hidden link; it is that every door
  into the surface is shut and the surface's own process does no work. These are
  the negative tests that make that claim checkable.
  """
  # async: false — points the global :workspace_root at a tmp dir and stubs the
  # trading fetcher seams in the app env.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Agent.Conversations
  alias BusterClaw.Extensions
  alias BusterClaw.Settings

  @extension "trading-robinhood"

  setup do
    root = Path.join(System.tmp_dir!(), "bc_gate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "memory"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    prev_cli = Application.get_env(:buster_claw, :agent_cli)
    Application.put_env(:buster_claw, :agent_cli, {:claude, "/usr/local/bin/claude"})

    test_pid = self()
    prev_fetcher = Application.get_env(:buster_claw, :trading_snapshot_fetcher)

    Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
      send(test_pid, :broker_snapshot_fetched)
      {:error, {:robinhood, "disabled in test"}}
    end)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      Application.put_env(:buster_claw, :agent_cli, prev_cli)
      Application.put_env(:buster_claw, :trading_snapshot_fetcher, prev_fetcher)
      File.rm_rf(root)
    end)

    :ok
  end

  describe "a fresh install has no Trading" do
    test "the extension is off, so the surface is not installed" do
      refute Extensions.enabled?(@extension)
      refute Extensions.surface_enabled?("trading")
    end

    test "the dock has no Trading item — and still has Charts" do
      paths = Enum.map(BusterClawWeb.Layouts.navigation_items(), & &1.path)

      refute "/trading" in paths
      assert "/charts" in paths
      assert "/" in paths
    end

    test "/trading mounts the install card and does no trading work", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/trading")

      assert html =~ "not installed"
      assert html =~ "Robinhood Trading"

      # The whole surface's mount was skipped: nothing subscribed, nothing was
      # seeded, and no broker call was made.
      refute_receive :broker_snapshot_fetched, 300
      assert Conversations.list_kinds(["robinhood"]) == []
    end

    test "the card states the capability from the manifest, not from prose", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/trading")

      assert html =~ "agent.robinhood.com"
      assert html =~ "order_cancel"
      assert html =~ "real brokerage account"
    end

    test "Trading cannot be joined into a split pane", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/split?left=%2Ftrading")

      # An unavailable pane falls through to the "no such pane" branch rather
      # than rendering TradingLive — the gate holds at every door, not the front
      # one.
      refute html =~ "trading-tab-strip"
      refute_receive :broker_snapshot_fetched, 300
    end

    test "/charts is untouched by the gate", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/charts")

      assert html =~ "Chart Build"
      refute_receive :broker_snapshot_fetched, 300
    end
  end

  describe "enabling it from the card" do
    test "the button installs the surface and lands on it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/trading")

      assert {:error, {:live_redirect, %{to: "/trading"}}} =
               render_click(view, "enable_trading", %{})

      assert Extensions.enabled?(@extension)
      assert Extensions.surface_enabled?("trading")
    end

    test "once enabled the dock carries Trading and the surface mounts", %{conn: conn} do
      {:ok, _manifest} = Extensions.enable(@extension)

      assert "/trading" in Enum.map(BusterClawWeb.Layouts.navigation_items(), & &1.path)

      {:ok, _view, html} = live(conn, ~p"/trading")

      assert html =~ "trading-tab-strip"
      assert_receive :broker_snapshot_fetched, 1_000
    end

    test "disabling removes it again without touching the data", %{conn: conn} do
      {:ok, _manifest} = Extensions.enable(@extension)
      {:ok, _view, _html} = live(conn, ~p"/trading")
      assert [%{kind: "robinhood"}] = Conversations.list_kinds(["robinhood"])

      :ok = Extensions.disable(@extension)

      refute "/trading" in Enum.map(BusterClawWeb.Layouts.navigation_items(), & &1.path)

      # The conversation is still there. Turning a surface off is not a delete —
      # the operator's data outlives their decision about the surface.
      assert [%{kind: "robinhood"}] = Conversations.list_kinds(["robinhood"])
    end
  end

  describe "adopt/2 — the upgrade path for installs that predate the extension" do
    test "an install with Trading data is adopted as on" do
      assert :adopted = Extensions.adopt(@extension, true)
      assert Extensions.enabled?(@extension)
    end

    test "it never overrides a decision the operator already made" do
      :ok = Extensions.disable(@extension)

      assert :already_decided = Extensions.adopt(@extension, true)

      # The point of the whole mechanism: someone who turned Trading OFF does
      # not get it back on the next boot.
      refute Extensions.enabled?(@extension)
    end

    test "it does not override an explicit on either" do
      {:ok, _manifest} = Extensions.enable(@extension)
      assert :already_decided = Extensions.adopt(@extension, false)
      assert Extensions.enabled?(@extension)
    end

    test "a fresh install is left alone" do
      assert Settings.get("extension:" <> @extension) == nil
      refute Extensions.surface_enabled?("trading")
    end
  end

  describe "a surface nobody owns is not gated" do
    test "surface_owned? is false for an unclaimed name" do
      refute Extensions.surface_owned?("phone")
      refute Extensions.surface_enabled?("phone")
    end

    test "an unowned surface stays in the dock" do
      # Phone carries no `:surface`, so it is ordinary application code and the
      # extension mechanism must not touch it.
      assert "/phone" in Enum.map(BusterClawWeb.Layouts.navigation_items(), & &1.path)
    end
  end
end
