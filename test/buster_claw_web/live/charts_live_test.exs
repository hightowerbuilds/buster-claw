defmodule BusterClawWeb.ChartsLiveTest do
  @moduledoc """
  `/charts` — Chart Build's own route over `TradingLive`.

  The point of this route is that it is **broker-free by construction**, not by
  omission from a template: Chart Build had no Robinhood dependency but lived on
  `/trading`, so gating Trading behind its extension would have taken it down
  too. These tests hold that separation in place.
  """
  # async: false — points the global :workspace_root at a tmp dir and stubs the
  # trading fetcher seams in the app env.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Agent.Conversations

  setup do
    root = Path.join(System.tmp_dir!(), "bc_charts_live_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "memory"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    prev_cli = Application.get_env(:buster_claw, :agent_cli)
    Application.put_env(:buster_claw, :agent_cli, {:claude, "/usr/local/bin/claude"})

    prev_lookup = Application.get_env(:buster_claw, :chart_builder_loader)

    Application.put_env(:buster_claw, :chart_builder_loader, fn symbol ->
      %{
        symbol: symbol,
        quote: BusterClaw.DataState.unavailable(:not_configured, source: :finnhub),
        fundamentals: BusterClaw.DataState.unavailable({:unknown_symbol, symbol}, source: :edgar),
        filings: BusterClaw.DataState.unavailable({:unknown_symbol, symbol}, source: :edgar)
      }
    end)

    # The tripwire: any broker snapshot fetch tells this test process about it.
    test_pid = self()
    prev_fetcher = Application.get_env(:buster_claw, :trading_snapshot_fetcher)
    prev_detail = Application.get_env(:buster_claw, :trading_detail_fetcher)

    Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
      send(test_pid, :broker_snapshot_fetched)
      {:error, {:robinhood, "disabled in test"}}
    end)

    Application.put_env(:buster_claw, :trading_detail_fetcher, fn _last4 ->
      send(test_pid, :broker_detail_fetched)
      {:error, {:robinhood, "detail disabled in test"}}
    end)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      Application.put_env(:buster_claw, :agent_cli, prev_cli)
      Application.put_env(:buster_claw, :chart_builder_loader, prev_lookup)
      Application.put_env(:buster_claw, :trading_snapshot_fetcher, prev_fetcher)
      Application.put_env(:buster_claw, :trading_detail_fetcher, prev_detail)
      File.rm_rf(root)
    end)

    :ok
  end

  describe "the route is broker-free" do
    test "mounting /charts never starts a broker fetch", %{conn: conn} do
      {:ok, _view, _html} = live(conn, ~p"/charts")

      refute_receive :broker_snapshot_fetched, 300
      refute_receive :broker_detail_fetched, 300
    end

    test "/trading DOES start one — so the check above is meaningful", %{conn: conn} do
      {:ok, _view, _html} = live(conn, ~p"/trading")

      assert_receive :broker_snapshot_fetched, 1_000
    end

    test "mounting /charts does not conjure a Robinhood conversation", %{conn: conn} do
      {:ok, _view, _html} = live(conn, ~p"/charts")

      # `Trading.tabs/0` seeds a pinned "trading" Robinhood row. The charts
      # surface must not: a broker-free route that creates a broker
      # conversation is only cosmetically broker-free.
      assert Conversations.list_kinds(["robinhood"]) == []
      assert [%{kind: "chartbuild"}] = Conversations.list_kinds(["chartbuild"])
    end
  end

  describe "the surface holds only Chart Build" do
    test "the new-tab menu offers Chart Build and not Robinhood", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/charts")

      html = render_click(view, "trading_new_tab_menu", %{})

      assert html =~ "Chart Build"
      refute html =~ ~s(phx-value-kind="robinhood")
      refute html =~ ~s(phx-value-kind="chat")
    end

    test "a forged new-tab event for a Robinhood tab is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/charts")

      render_click(view, "trading_new_tab", %{"kind" => "robinhood"})

      assert Conversations.list_kinds(["robinhood"]) == []
      refute_receive :broker_snapshot_fetched, 200
    end

    test "a forged retype to Robinhood is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/charts")

      [chart] = Conversations.list_kinds(["chartbuild"])
      render_click(view, "trading_set_kind", %{"id" => chart.id, "kind" => "robinhood"})

      assert Conversations.list_kinds(["robinhood"]) == []
      assert [%{kind: "chartbuild"}] = Conversations.list_kinds(["chartbuild"])
    end

    test "a new Chart Build tab IS allowed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/charts")

      render_click(view, "trading_new_tab", %{"kind" => "chartbuild"})

      assert length(Conversations.list_kinds(["chartbuild"])) == 2
    end
  end

  describe "/trading is unchanged" do
    test "it still offers all three kinds", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/trading")

      html = render_click(view, "trading_new_tab_menu", %{})

      assert html =~ ~s(phx-value-kind="robinhood")
      assert html =~ ~s(phx-value-kind="chat")
      assert html =~ ~s(phx-value-kind="chartbuild")
    end

    test "it still seeds the pinned Robinhood conversation", %{conn: conn} do
      {:ok, _view, _html} = live(conn, ~p"/trading")

      assert [%{kind: "robinhood"}] = Conversations.list_kinds(["robinhood"])
    end
  end
end
