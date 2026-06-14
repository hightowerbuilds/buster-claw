defmodule BusterClawWeb.BrowserChromeController do
  @moduledoc """
  The embedded browser's native chrome — a thin toolbar (back/forward/reload +
  address bar) loaded into the `browser-chrome` child webview. Served from the
  Phoenix origin so it can call the `browser_*` Tauri commands (granted to that
  webview via the `browser-chrome` capability). It drives the sibling
  `browser-content` webview; it never renders site content itself.
  """
  use BusterClawWeb, :controller

  def show(conn, params) do
    initial = params["url"] || ""

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page(initial))
  end

  defp page(initial) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Browser chrome</title>
    <style>
      * { box-sizing: border-box; }
      html, body { margin: 0; height: 100%; overflow: hidden; }
      body {
        display: flex; align-items: center; gap: 6px; padding: 0 8px; height: 46px;
        background: #121212; color: #f4f1ea;
        font: 13px/1 -apple-system, system-ui, sans-serif;
        border-bottom: 2px solid rgba(244,241,234,.18);
      }
      button.nav {
        flex: 0 0 auto; width: 30px; height: 30px; display: grid; place-items: center;
        background: transparent; color: #f4f1ea; border: 2px solid rgba(244,241,234,.2);
        border-radius: 3px; cursor: pointer; font-size: 14px; line-height: 1;
      }
      button.nav:hover { border-color: #ff4d1c; color: #ff4d1c; }
      form { flex: 1 1 auto; display: flex; gap: 6px; min-width: 0; }
      input {
        flex: 1 1 auto; min-width: 0; height: 30px; padding: 0 10px;
        background: #1c1c1c; color: #f4f1ea; border: 2px solid rgba(244,241,234,.2);
        border-radius: 3px; font: 12px/1 ui-monospace, monospace; outline: none;
      }
      input:focus { border-color: rgba(244,241,234,.45); }
      button.go {
        flex: 0 0 auto; height: 30px; padding: 0 14px; cursor: pointer;
        background: #ff4d1c; color: #121212; border: 0; border-radius: 3px;
        font-weight: 700; font-size: 12px;
      }
    </style>
    </head>
    <body>
      <button class="nav" id="back" title="Back" aria-label="Back">&#9664;</button>
      <button class="nav" id="fwd" title="Forward" aria-label="Forward">&#9654;</button>
      <button class="nav" id="reload" title="Reload" aria-label="Reload">&#8635;</button>
      <form id="form">
        <input id="addr" type="text" autocomplete="off" spellcheck="false"
               placeholder="https://… or /path in your workspace"
               value="#{escape_attr(initial)}" />
        <button class="go" type="submit">Go</button>
      </form>
      <script>
        const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke
        const origin = window.location.origin
        const addr = document.getElementById("addr")
        function resolve(raw) {
          const v = (raw || "").trim()
          if (v === "") return null
          if (/^[a-z]+:\\/\\//i.test(v)) return v
          if (v.startsWith("/")) return origin + "/ws/file?path=" + encodeURIComponent(v)
          return "https://" + v
        }
        function go() {
          const url = resolve(addr.value)
          if (url && invoke) invoke("browser_navigate", {url})
        }
        document.getElementById("form").addEventListener("submit", function (e) { e.preventDefault(); go() })
        document.getElementById("back").addEventListener("click", function () { invoke && invoke("browser_back") })
        document.getElementById("fwd").addEventListener("click", function () { invoke && invoke("browser_forward") })
        document.getElementById("reload").addEventListener("click", function () { invoke && invoke("browser_reload") })
        addr.focus()
      </script>
    </body>
    </html>
    """
  end

  defp escape_attr(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
