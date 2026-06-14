defmodule BusterClawWeb.FinanceApiControllerTest do
  use BusterClawWeb.ConnCase, async: true

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  test "search returns an empty suggestion list for short queries (no network)", %{conn: conn} do
    body = conn |> get(~p"/finance/api/search?q=a") |> json_response(200)
    assert body == %{"ok" => true, "suggestions" => []}
  end

  test "lookup with no query returns an error (no network)", %{conn: conn} do
    body = conn |> get(~p"/finance/api/lookup") |> json_response(200)
    assert body["ok"] == false
    assert body["error"] =~ "Enter a ticker"
  end
end
