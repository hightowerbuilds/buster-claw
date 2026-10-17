defmodule BusterClawWeb.BrowserChromeController do
  @moduledoc """
  The embedded browser's native chrome — a **tab strip** + a toolbar (back/forward/
  reload + address bar + bookmark), loaded into a `browser-chrome-<sid>` child
  webview. Served from the Phoenix origin so it can call the `browser_*` Tauri
  commands (granted via the `browser-chrome` capability, whose `browser-chrome-*`
  glob covers every surface).

  This controller resolves the three inputs and sends the document; the markup
  is `BusterClawWeb.Browser.ChromePage` (layout + styles only). The behavior
  lives in `assets/js/chrome.js` (its own esbuild entry point, served as
  `/assets/js/chrome.js`), which owns the tab-strip UI and tab lifecycle; Rust
  owns the per-tab content webviews and the per-surface active-tab pointer.

  `?sid=` identifies the browser surface this chrome drives (`main` for the solo
  `/browse`, `left`/`right` for a browser+browser split); it's handed to the JS
  via `<body data-sid>` and every `browser_*` invoke carries it so two
  side-by-side browsers stay independent.
  """
  use BusterClawWeb, :controller

  alias BusterClawWeb.Browser.ChromePage

  # Omnibox search engine: query text is appended to this prefix. Overridable
  # via the `browser_search_url` setting; DuckDuckGo default fits the app's
  # no-third-party-reporting posture.
  @default_search_url "https://duckduckgo.com/?q="

  def show(conn, params) do
    initial = params["url"] || ""
    sid = sanitize_sid(params["sid"])
    search_url = BusterClaw.Settings.get("browser_search_url", @default_search_url)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page(initial, sid, search_url))
  end

  # Surface ids are alphanumeric only (matches the Rust sanitiser); default "main".
  defp sanitize_sid(sid) do
    case sid |> to_string() |> String.replace(~r/[^A-Za-z0-9]/, "") do
      "" -> "main"
      cleaned -> cleaned
    end
  end

  defp page(initial, sid, search_url),
    do: ChromePage.html(%{initial: initial, sid: sid, search_url: search_url})
end
