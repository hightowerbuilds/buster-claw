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
      Sentinel.observe(:command_invoke, "document_save (ok)", %{
        command: "document_save",
        tier: :restricted
      })

    assert render(view) =~ "document_save (ok)"
  end

  test "acknowledge clears the unacknowledged count", %{conn: conn} do
    {:ok, _} = Sentinel.observe(:security_block, "blocked thing", %{command: "hook_test"})

    {:ok, view, _html} = live(conn, ~p"/security")
    assert render(view) =~ "1 unacknowledged"

    view |> element("button", "Acknowledge all") |> render_click()
    assert render(view) =~ "0 unacknowledged"
  end

  # About moved here from the Configuration rail on 10-17. Until 08-16 the app
  # displayed its own version nowhere (UPDATE_ROADMAP F5, G-42).
  test "About shows the running version and which build it is", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/security")

    assert has_element?(view, "#about")
    assert html =~ BusterClaw.BuildInfo.version()
    assert html =~ BusterClaw.BuildInfo.architecture_label()
    # `build_info_test.exs` pins the value against the VERSION file; this line
    # stops the pair from passing vacuously on a build where the spec cannot be
    # read.
    refute html =~ "unknown"
    assert has_element?(view, "#about button[phx-click='rerun_setup']")
  end
end
