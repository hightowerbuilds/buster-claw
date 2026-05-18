defmodule BusterClawWeb.IntegrationWebhookController do
  use BusterClawWeb, :controller

  alias BusterClaw.Integrations

  @max_body_bytes 1_000_000

  def trigger(conn, %{"name" => name}) do
    with {:ok, body, conn} <- read_limited_body(conn),
         {:ok, run} <- Integrations.handle_webhook(name, conn.req_headers, body) do
      conn
      |> put_status(:accepted)
      |> json(%{
        status: "accepted",
        run_id: run.id,
        document_id: run.document_id,
        records_fetched: run.records_fetched
      })
    else
      {:error, :too_large, conn} ->
        conn |> put_status(:payload_too_large) |> json(%{error: "request body too large"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "integration not found"})

      {:error, %{error: "Integration is disabled"}} ->
        conn |> put_status(:gone) |> json(%{error: "integration disabled"})

      {:error, %{error: error}} ->
        status = error_status(error)
        conn |> put_status(status) |> json(%{error: error})
    end
  end

  defp read_limited_body(conn) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) and byte_size(body) <= @max_body_bytes ->
        {:ok, body, conn}

      body when is_binary(body) ->
        {:error, :too_large, conn}

      _ ->
        case Plug.Conn.read_body(conn, length: @max_body_bytes, read_length: @max_body_bytes) do
          {:ok, body, conn} -> {:ok, body, conn}
          {:more, _partial, conn} -> {:error, :too_large, conn}
          {:error, reason} -> {:error, reason, conn}
        end
    end
  end

  defp error_status(error) do
    if String.contains?(to_string(error), "unauthorized") do
      :unauthorized
    else
      :unprocessable_entity
    end
  end
end
