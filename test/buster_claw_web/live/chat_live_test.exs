defmodule BusterClawWeb.ChatLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders chat page and sends help command", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/chat")

    assert html =~ "Chat"
    assert html =~ "Supervised local chat session"

    view
    |> form("form", %{prompt: "/help"})
    |> render_submit()

    html = render(view)
    assert html =~ "Available Commands"
  end
end
