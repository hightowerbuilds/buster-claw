defmodule BusterClawWeb.BrowserPagesController do
  @moduledoc """
  The embedded browser's **Pages** index — every HTML page in
  `<workspace>/pages/`: the ones the agent has built for the user, then the
  bundled ones (Manual, Financial Informant). Reached from the hardcoded
  "Pages" button in the browser chrome. Entries open via `/ws/file` (same as
  the workspace browser) and record themselves into browser history on click.
  Dark-themed to match; loopback-only, like the rest of `/browser`.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Pages

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page(Pages.list()))
  end

  defp page(pages) do
    {yours, bundled} = Enum.split_with(pages, &(not &1.bundled?))

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Pages</title>
    <style>
      * { box-sizing: border-box; }
      html, body { margin: 0; height: 100%; }
      body { background: #121212; color: #f4f1ea; padding: 40px 28px;
             font: 15px/1.5 -apple-system, system-ui, sans-serif; }
      .eyebrow { font: 700 11px/1 ui-monospace, monospace; letter-spacing: .12em;
                 text-transform: uppercase; color: rgba(244,241,234,.5); }
      h1 { margin: 6px 0 24px; font-size: 26px; font-weight: 900; letter-spacing: -.01em; }
      h2 { margin: 32px 0 0; font-size: 13px; font-weight: 700; letter-spacing: .08em;
           text-transform: uppercase; color: rgba(244,241,234,.55); }
      ul { list-style: none; margin: 8px 0 0; padding: 0; max-width: 52rem; }
      li { border-top: 1px solid rgba(244,241,234,.12); }
      a { display: flex; align-items: baseline; gap: 12px; padding: 11px 4px;
          color: #f4f1ea; text-decoration: none; min-width: 0; }
      a:hover { color: #ff4d1c; }
      .title { font-weight: 600; flex: 0 1 auto; overflow: hidden;
               text-overflow: ellipsis; white-space: nowrap; }
      .file { color: rgba(244,241,234,.45); font: 12px/1.4 ui-monospace, monospace;
              overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
              flex: 1 1 auto; }
      .when { color: rgba(244,241,234,.45); font: 12px/1.4 ui-monospace, monospace;
              flex: 0 0 auto; }
      .empty { color: rgba(244,241,234,.55); max-width: 40rem; }
      .empty code { color: #ff4d1c; }
    </style>
    </head>
    <body>
      <p class="eyebrow">Buster Claw</p>
      <h1>Pages</h1>
      #{yours_section(yours)}
      #{bundled_section(bundled)}
      <script>
        // Record opened pages into the browser history (fires during navigation).
        document.addEventListener("click", function (e) {
          var a = e.target.closest("a[data-file]")
          if (!a) return
          try {
            navigator.sendBeacon("/browser/history?url=" + encodeURIComponent(a.getAttribute("href")) +
              "&label=" + encodeURIComponent(a.getAttribute("data-label")))
          } catch (_e) {}
        })
      </script>
    </body>
    </html>
    """
  end

  defp yours_section([]) do
    """
    <p class="empty">
      Nothing here yet. Ask the agent to build you a page — any
      <code>.html</code> it saves into the workspace's <code>pages/</code>
      folder shows up in this list.
    </p>
    """
  end

  defp yours_section(pages), do: "<ul>#{Enum.map_join(pages, "\n", &row/1)}</ul>"

  defp bundled_section([]), do: ""

  defp bundled_section(pages) do
    """
    <h2>Built in</h2>
    <ul>#{Enum.map_join(pages, "\n", &row/1)}</ul>
    """
  end

  defp row(page) do
    href = "/ws/file?path=" <> URI.encode_www_form("/pages/" <> page.file)

    """
    <li><a data-file data-label="#{escape(page.title)}" href="#{escape(href)}">
      <span class="title">#{escape(page.title)}</span>
      <span class="file">#{escape(page.file)}</span>
      <span class="when">#{stamp(page.mtime)}</span>
    </a></li>
    """
  end

  # "Jul 12" — enough to scan recency; the list is already newest-first.
  defp stamp(posix) when is_integer(posix) and posix > 0 do
    posix |> DateTime.from_unix!() |> Calendar.strftime("%b %-d")
  end

  defp stamp(_unknown), do: ""

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
