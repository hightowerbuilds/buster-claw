defmodule BusterClawWeb.WebhookController do
  use BusterClawWeb, :controller

  alias BusterClaw.Webhooks

  @max_body_bytes 1_000_000

  def trigger(conn, %{"name" => name}) do
    with {:ok, body, conn} <- read_limited_body(conn),
         {:ok, summary} <- Webhooks.trigger(name, conn.req_headers, body) do
      conn
      |> put_status(:accepted)
      |> json(%{status: "accepted", trigger: summary})
    else
      {:error, :too_large, conn} ->
        conn |> put_status(:payload_too_large) |> json(%{error: "request body too large"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "webhook not found"})

      {:error, :disabled} ->
        conn |> put_status(:gone) |> json(%{error: "webhook disabled"})

      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})
    end
  end

  defp read_limited_body(conn) do
    case Plug.Conn.read_body(conn, length: @max_body_bytes, read_length: @max_body_bytes) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, :too_large, conn}
      {:error, reason} -> {:error, reason, conn}
    end
  end
end
