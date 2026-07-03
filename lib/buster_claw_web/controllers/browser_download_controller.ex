defmodule BusterClawWeb.BrowserDownloadController do
  @moduledoc """
  Records a browser download on the Sentinel audit feed. Called (POST, query
  params) by the Rust shell when a content webview finishes a download — the
  one browser ingress that pulls untrusted bytes onto disk without passing
  through the server-side fetch pipeline (which records its own events).
  Loopback-only, single-user; no CSRF (raw scope).
  """
  use BusterClawWeb, :controller

  def create(conn, %{"url" => url} = params) when is_binary(url) and url != "" do
    success = params["success"] == "true"
    verb = if success, do: "Downloaded", else: "Download failed"

    BusterClaw.Sentinel.observe(:untrusted_ingest, "#{verb}: #{url}", %{
      url: url,
      file: params["file"],
      success: success,
      trust: "fetched",
      via: "browser"
    })

    send_resp(conn, 204, "")
  end

  def create(conn, _params), do: send_resp(conn, 400, "missing url")
end
