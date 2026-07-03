defmodule BusterClawWeb.BrowserTabsController do
  @moduledoc """
  Durable tab state for the embedded browser (roadmap Phase 2.1).

  The chrome's tab model lives in its webview's JS heap, so an app restart
  used to forget every tab. The chrome now POSTs `{tabs, active}` here
  (debounced, per surface) on every mutation and hydrates from GET on a cold
  load, recreating the native webviews through its normal new-tab path.
  Stored as a JSON blob in `BusterClaw.Settings` under `browser_tabs.<sid>`.
  Loopback-only, single-user; no CSRF (raw scope). Payloads are sanitized and
  bounded — a hostile page can't reach this origin, but the state also feeds
  back into `browser_navigate`, so only url/label strings survive.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Settings

  @max_tabs 50
  @max_url_len 2000
  @max_label_len 200
  @max_bytes 65_536

  def show(conn, params) do
    with raw when is_binary(raw) <- Settings.get(key(params["sid"])),
         {:ok, state} <- Jason.decode(raw) do
      json(conn, state)
    else
      _ -> json(conn, nil)
    end
  end

  def update(conn, params) do
    case sanitize(conn.body_params) do
      {:ok, clean} ->
        Settings.put(key(params["sid"]), Jason.encode!(clean))
        send_resp(conn, 204, "")

      :error ->
        send_resp(conn, 400, "invalid tab state")
    end
  end

  # Alphanumeric-only surface ids (same rule as the chrome/Rust sanitisers).
  defp key(sid) do
    case sid |> to_string() |> String.replace(~r/[^A-Za-z0-9]/, "") do
      "" -> "browser_tabs.main"
      cleaned -> "browser_tabs." <> cleaned
    end
  end

  defp sanitize(%{"tabs" => tabs} = body) when is_list(tabs) and length(tabs) <= @max_tabs do
    clean_tabs =
      tabs
      |> Enum.filter(&(is_map(&1) and is_binary(&1["url"])))
      |> Enum.map(fn t ->
        %{
          "url" => String.slice(t["url"], 0, @max_url_len),
          "label" => t["label"] |> to_string() |> String.slice(0, @max_label_len)
        }
      end)

    active = if is_integer(body["active"]) and body["active"] >= 0, do: body["active"], else: 0
    clean = %{"tabs" => clean_tabs, "active" => active}

    if byte_size(Jason.encode!(clean)) <= @max_bytes, do: {:ok, clean}, else: :error
  end

  defp sanitize(_), do: :error
end
