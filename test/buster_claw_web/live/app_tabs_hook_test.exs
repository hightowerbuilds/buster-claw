defmodule BusterClawWeb.AppTabsHookTest do
  use BusterClawWeb.ConnCase
  import Phoenix.LiveViewTest
  alias BusterClaw.Commands

  test "chat commands reach the current tab strip and wait for its answer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_hook(view, "bc:tabs_ready", %{})
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         send(
           parent,
           {:result, Commands.call("app_tabs_join", %{"tab" => "browser"}, caller: :agent)}
         )
       end}
    )

    assert_push_event(view, "bc:app_tabs", %{
      ref: ref,
      action: :join,
      args: %{"tab" => "browser", "with" => "current"}
    })

    refute_receive {:result, _}

    render_hook(view, "bc:tabs_result", %{
      ref: ref,
      result: %{value: %{changed: true, current: "/split"}}
    })

    assert_receive {:result, {:ok, %{"changed" => true, "current" => "/split"}}}
  end

  test "the split shell handles commands while the chat is embedded", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/split?left=/&right=/browse")
    render_hook(view, "bc:tabs_ready", %{})
    parent = self()

    start_supervised!(
      {Task, fn -> send(parent, {:result, Commands.call("app_tabs_separate", %{})}) end}
    )

    assert_push_event(view, "bc:app_tabs", %{ref: ref, action: :separate})
    render_hook(view, "bc:tabs_result", %{ref: ref, result: %{value: %{current: "/"}}})
    assert_receive {:result, {:ok, %{"current" => "/"}}}
  end

  test "invalid selectors are rejected before sending a UI request" do
    assert {:error, :missing_tab} = Commands.call("app_tabs_join", %{})

    assert {:error, :invalid_tab} =
             Commands.call("app_tabs_join", %{"tab" => "browser", "with" => []})

    assert {:error, :invalid_tab} = Commands.call("app_tabs_separate", %{"tab" => 7})
  end
end
