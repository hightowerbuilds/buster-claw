defmodule BusterClawWeb.BrowserHomeController do
  @moduledoc """
  The embedded browser's homepage — shown in the content webview when no URL is
  loaded. Dark-themed to match the app; server-renders the recent-URL list (from
  `BusterClaw.BrowserHistory`), including workspace HTML/MD files. Clicking an
  entry navigates the content webview directly (plain links; allowed by the
  webview's http(s) nav guard).
  """
  use BusterClawWeb, :controller

  alias BusterClaw.BrowserHistory

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page(BrowserHistory.list()))
  end

  defp page(entries) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Browser</title>
    <style>
      * { box-sizing: border-box; }
      html, body { margin: 0; height: 100%; }
      body {
        background: #121212; color: #f4f1ea; padding: 40px 28px;
        font: 15px/1.5 -apple-system, system-ui, sans-serif;
      }
      .eyebrow { font: 700 11px/1 ui-monospace, monospace; letter-spacing: .12em;
                 text-transform: uppercase; color: rgba(244,241,234,.5); }
      h1 { margin: 6px 0 24px; font-size: 26px; font-weight: 900; letter-spacing: -.01em; }
      ul { list-style: none; margin: 0; padding: 0; max-width: 52rem; }
      li { border-top: 1px solid rgba(244,241,234,.12); }
      a { display: flex; align-items: baseline; gap: 12px; padding: 11px 4px;
          color: #f4f1ea; text-decoration: none; }
      a:hover { color: #ff4d1c; }
      .label { font-weight: 600; flex: 0 0 auto; max-width: 22rem; overflow: hidden;
               text-overflow: ellipsis; white-space: nowrap; }
      .url { color: rgba(244,241,234,.45); font: 12px/1.4 ui-monospace, monospace;
             overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .empty { color: rgba(244,241,234,.55); max-width: 40rem; }
    </style>
    </head>
    <body>
      <p class="eyebrow">Browser</p>
      <h1>Recent</h1>
      #{body(entries)}
    </body>
    </html>
    """
  end

  defp body([]) do
    """
    <p class="empty">No recent pages yet. Type a URL (e.g. <code>apnews.com</code>) or an
    absolute workspace path (e.g. <code>/library/notes.md</code>) in the address bar above.</p>
    """
  end

  defp body(entries) do
    rows =
      Enum.map_join(entries, "\n", fn e ->
        url = escape(e["url"])
        label = escape(e["label"] || e["url"])

        ~s(<li><a href="#{url}"><span class="label">#{label}</span><span class="url">#{url}</span></a></li>)
      end)

    "<ul>\n#{rows}\n</ul>"
  end

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
