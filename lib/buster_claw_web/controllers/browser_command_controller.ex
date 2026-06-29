defmodule BusterClawWeb.BrowserCommandController do
  @moduledoc """
  Receives the result of an agent co-presence command from the desktop side and
  fulfils the matching `BusterClaw.Browser.Bridge` request. The JS bridge POSTs
  JSON `{ref, ok: true, url, title}` on success (url/title only for `current`),
  or `{ref, error}` on failure. Loopback-only; no CSRF (raw `/browser` scope).
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Browser.Bridge

  def create(conn, %{"ref" => ref} = params) when is_binary(ref) and ref != "" do
    Bridge.fulfill(ref, result_for(params))
    send_resp(conn, 204, "")
  end

  def create(conn, _params), do: send_resp(conn, 400, "missing ref")

  defp result_for(%{"error" => error}) when is_binary(error) and error != "" do
    {:error, {:browser_failed, String.slice(error, 0, 200)}}
  end

  defp result_for(%{"ok" => true} = params) do
    # `current` returns url + title; the trigger actions send neither, yielding an
    # empty map that simply confirms success.
    {:ok,
     params
     |> Map.take(["url", "title"])
     |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)}
  end

  defp result_for(_params), do: {:error, :no_result}
end
