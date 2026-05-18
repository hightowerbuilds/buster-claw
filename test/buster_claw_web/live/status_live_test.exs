defmodule BusterClawWeb.StatusLiveTest do
  use BusterClawWeb.ConnCase

  test "GET / renders the home shell", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Buster Claw"
    assert response =~ "Models"
    assert response =~ "Active key"
    # Sidebar nav still surfaces every section
    assert response =~ "Webhooks"
    assert response =~ "Hooks"
  end

  test "GET /chat renders the chat shell", %{conn: conn} do
    conn = get(conn, ~p"/chat")
    response = html_response(conn, 200)

    assert response =~ "Supervised local chat session"
    assert response =~ "Chat"
  end
end
