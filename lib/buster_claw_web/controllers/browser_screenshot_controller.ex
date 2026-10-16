defmodule BusterClawWeb.BrowserScreenshotController do
  @moduledoc """
  Receives a captured screenshot from the desktop side and fulfils the matching
  `BusterClaw.Browser.Capture` request. The JS bridge POSTs JSON
  `{ref, url, data}` (base64 PNG) on success, or `{ref, error}` on failure.
  Loopback-only; no CSRF (raw `/browser` scope).
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Browser
  alias BusterClaw.Browser.Capture

  def create(conn, %{"ref" => ref} = params) when is_binary(ref) and ref != "" do
    Capture.fulfill(ref, result_for(ref, params))
    send_resp(conn, 204, "")
  end

  def create(conn, _params), do: send_resp(conn, 400, "missing ref")

  defp result_for(ref, %{"data" => data} = params) when is_binary(data) and data != "" do
    case Base.decode64(data) do
      {:ok, bytes} -> store(ref, bytes, params)
      :error -> {:error, :invalid_image_data}
    end
  end

  defp result_for(_ref, %{"error" => error}) when is_binary(error) do
    {:error, {:capture_failed, String.slice(error, 0, 200)}}
  end

  defp result_for(_ref, _params), do: {:error, :no_image}

  defp store(ref, bytes, params) do
    with {:ok, stored} <- Browser.store_screenshot(ref, bytes) do
      {:ok, Map.put(stored, :url, params["url"])}
    end
  end
end
