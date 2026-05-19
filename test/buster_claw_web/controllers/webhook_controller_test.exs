defmodule BusterClawWeb.WebhookControllerTest do
  use BusterClawWeb.ConnCase

  alias BusterClaw.Webhooks

  test "POST /hooks/:name accepts authorized local webhook", %{conn: conn} do
    {:ok, _webhook} =
      Webhooks.create_webhook(%{name: "analyze-now", action: "analyze", secret: "secret"})

    conn =
      conn
      |> put_req_header("x-buster-claw-secret", "secret")
      |> post(~p"/hooks/analyze-now", %{document_id: 1})

    assert json_response(conn, 202)["status"] == "accepted"
  end

  test "POST /hooks/:name rejects when the secret header is missing", %{conn: conn} do
    {:ok, _webhook} =
      Webhooks.create_webhook(%{name: "missing-header", action: "ingest", secret: "secret"})

    conn = post(conn, ~p"/hooks/missing-header", %{})
    assert json_response(conn, 401)["error"] == "unauthorized"
  end

  test "POST /hooks/:name rejects when the secret header is wrong", %{conn: conn} do
    {:ok, _webhook} =
      Webhooks.create_webhook(%{name: "wrong-header", action: "ingest", secret: "real-secret"})

    conn =
      conn
      |> put_req_header("x-buster-claw-secret", "bad-secret")
      |> post(~p"/hooks/wrong-header", %{})

    assert json_response(conn, 401)["error"] == "unauthorized"
  end

  test "POST /hooks/:name accepts an empty body with a valid secret", %{conn: conn} do
    {:ok, _webhook} =
      Webhooks.create_webhook(%{name: "empty-body", action: "analyze", secret: "secret"})

    conn =
      conn
      |> put_req_header("x-buster-claw-secret", "secret")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/hooks/empty-body", "")

    assert json_response(conn, 202)["status"] == "accepted"
  end

  test "POST /hooks/:name returns 404 for an unknown webhook name", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-buster-claw-secret", "any")
      |> post(~p"/hooks/no-such-hook", %{})

    assert json_response(conn, 404)["error"] == "webhook not found"
  end

  test "POST /hooks/:name returns 410 for a disabled webhook", %{conn: conn} do
    {:ok, webhook} =
      Webhooks.create_webhook(%{name: "off", action: "ingest", secret: "secret"})

    {:ok, _} = Webhooks.update_webhook(webhook, %{enabled: false})

    conn =
      conn
      |> put_req_header("x-buster-claw-secret", "secret")
      |> post(~p"/hooks/off", %{})

    assert json_response(conn, 410)["error"] == "webhook disabled"
  end
end
