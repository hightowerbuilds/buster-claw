defmodule BusterClawWeb.BrowserTabsControllerTest do
  use BusterClawWeb.ConnCase, async: true

  test "round-trips tab state per surface", %{conn: conn} do
    state = %{
      "tabs" => [
        %{"url" => "https://a.com", "label" => "A"},
        %{"url" => "https://b.com", "label" => "B"}
      ],
      "active" => 1
    }

    conn2 =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/browser/tabs?sid=main", Jason.encode!(state))

    assert response(conn2, 204)
    assert json_response(get(conn, ~p"/browser/tabs?sid=main"), 200) == state
    # Other surfaces are isolated.
    assert json_response(get(conn, ~p"/browser/tabs?sid=left"), 200) == nil
  end

  test "returns null when nothing is saved", %{conn: conn} do
    assert json_response(get(conn, ~p"/browser/tabs?sid=fresh"), 200) == nil
  end

  test "sanitizes entries and clamps lengths", %{conn: conn} do
    state = %{
      "tabs" => [
        %{"url" => String.duplicate("a", 3000), "label" => String.duplicate("b", 500)},
        %{"not" => "a tab"},
        %{"url" => 42},
        %{"url" => "https://ok.com", "label" => nil, "extra" => "dropped"}
      ],
      "active" => -3
    }

    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/browser/tabs?sid=clamp", Jason.encode!(state))
    |> response(204)

    saved = json_response(get(conn, ~p"/browser/tabs?sid=clamp"), 200)
    assert [first, second] = saved["tabs"]
    assert String.length(first["url"]) == 2000
    assert String.length(first["label"]) == 200
    assert second == %{"url" => "https://ok.com", "label" => ""}
    assert saved["active"] == 0
  end

  test "rejects oversized or malformed payloads", %{conn: conn} do
    too_many = %{"tabs" => List.duplicate(%{"url" => "https://x.com"}, 51)}

    assert conn
           |> put_req_header("content-type", "application/json")
           |> post(~p"/browser/tabs?sid=big", Jason.encode!(too_many))
           |> response(400)

    assert conn
           |> put_req_header("content-type", "application/json")
           |> post(~p"/browser/tabs?sid=bad", Jason.encode!(%{"nope" => true}))
           |> response(400)
  end

  test "hostile sid collapses to a safe settings key", %{conn: conn} do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/browser/tabs?sid=../etc", Jason.encode!(%{"tabs" => [], "active" => 0}))
    |> response(204)

    assert BusterClaw.Settings.get("browser_tabs.etc") != nil
  end
end
