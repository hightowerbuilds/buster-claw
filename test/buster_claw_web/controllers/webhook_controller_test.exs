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

  test "POST /hooks/:name rejects invalid secret", %{conn: conn} do
    {:ok, _webhook} =
      Webhooks.create_webhook(%{name: "secret-hook", action: "ingest", secret: "secret"})

    conn = post(conn, ~p"/hooks/secret-hook", %{})

    assert json_response(conn, 401)["error"] == "unauthorized"
  end
end
