defmodule BusterClawWeb.BrowserFaviconController do
  @moduledoc """
  Serves favicons for the embedded browser's tab strip, bookmark bar, and
  homepage from the local `BusterClaw.Favicons` cache — so visited hosts are
  never reported to a third-party favicon service. Loopback-only, same raw
  scope as the other /browser endpoints.
  """
  use BusterClawWeb, :controller

  def show(conn, %{"host" => host}) do
    case BusterClaw.Favicons.fetch(host) do
      {:ok, %{body: body, content_type: type}} ->
        conn
        |> put_resp_content_type(type, nil)
        |> put_resp_header("cache-control", "public, max-age=604800")
        |> send_resp(200, body)

      :error ->
        conn
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(404, "")
    end
  end

  def show(conn, _params), do: send_resp(conn, 400, "missing host")
end
