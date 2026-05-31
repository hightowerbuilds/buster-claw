defmodule BusterClawWeb.SecurityLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Sentinel

  test "renders existing events and live-updates on a new broadcast", %{conn: conn} do
    {:ok, _} = Sentinel.observe(:security_block, "blocked gmail_send", %{command: "gmail_send"})

    {:ok, view, html} = live(conn, ~p"/security")
    assert html =~ "Security"
    assert html =~ "blocked gmail_send"

    # A subsequently recorded event appears live (the view subscribes to the topic).
    {:ok, _} =
      Sentinel.observe(:command_invoke, "source_create (ok)", %{
        command: "source_create",
        tier: :restricted
      })

    assert render(view) =~ "source_create (ok)"
  end

  test "acknowledge clears the unacknowledged count", %{conn: conn} do
    {:ok, _} = Sentinel.observe(:security_block, "blocked thing", %{command: "hook_test"})

    {:ok, view, _html} = live(conn, ~p"/security")
    assert render(view) =~ "1 unacknowledged"

    view |> element("button", "Acknowledge all") |> render_click()
    assert render(view) =~ "0 unacknowledged"
  end
end
