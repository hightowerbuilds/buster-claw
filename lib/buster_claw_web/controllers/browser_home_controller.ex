defmodule BusterClawWeb.BrowserHomeController do
  @moduledoc """
  The embedded browser's homepage — shown in the content webview when no URL is
  loaded. Dark-themed to match the app; server-renders the saved **bookmarks**
  (from `BusterClaw.Bookmarks`) above the **recent-URL** list (from
  `BusterClaw.BrowserHistory`), including workspace HTML/MD files. Clicking an
  entry navigates the content webview directly (plain links; allowed by the
  webview's http(s) nav guard); a bookmark's "×" posts a remove form back here.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.{Bookmarks, BrowserHistory}

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page(Bookmarks.list(), BrowserHistory.list()))
  end

  defp page(bookmarks, history) do
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
      h2 { margin: 32px 0 0; font-size: 13px; font-weight: 700; letter-spacing: .08em;
           text-transform: uppercase; color: rgba(244,241,234,.55); }
      ul { list-style: none; margin: 8px 0 0; padding: 0; max-width: 52rem; }
      li { border-top: 1px solid rgba(244,241,234,.12); display: flex; align-items: center; }
      a { display: flex; align-items: baseline; gap: 12px; padding: 11px 4px;
          color: #f4f1ea; text-decoration: none; flex: 1 1 auto; min-width: 0; }
      a:hover { color: #ff4d1c; }
      .label { font-weight: 600; flex: 0 0 auto; max-width: 22rem; overflow: hidden;
               text-overflow: ellipsis; white-space: nowrap; }
      .url { color: rgba(244,241,234,.45); font: 12px/1.4 ui-monospace, monospace;
             overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .empty { color: rgba(244,241,234,.55); max-width: 40rem; }
      .empty code { color: #ff4d1c; }
      form.rm { margin: 0; flex: 0 0 auto; }
      button.rm { background: transparent; border: 0; cursor: pointer; padding: 4px 8px;
                  color: rgba(244,241,234,.4); font-size: 16px; line-height: 1; }
      button.rm:hover { color: #ff4d1c; }

      /* Bookmark cards */
      .grid { display: grid; gap: 12px; margin: 12px 0 0; max-width: 60rem;
              grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); }
      .card { position: relative; border: 1px solid rgba(244,241,234,.12);
              border-radius: 8px; background: rgba(244,241,234,.02);
              transition: border-color .15s ease, background .15s ease, transform .15s ease; }
      .card:hover { border-color: rgba(255,77,28,.55); background: rgba(255,77,28,.05);
                    transform: translateY(-1px); }
      .card > a { display: block; padding: 14px; text-decoration: none; color: #f4f1ea; }
      .card .head { display: flex; align-items: center; gap: 10px; min-width: 0; }
      .card .fav { width: 20px; height: 20px; flex: 0 0 auto; border-radius: 4px;
                   background: rgba(244,241,234,.08); }
      .card .label { font-weight: 700; font-size: 14px; overflow: hidden;
                     text-overflow: ellipsis; white-space: nowrap; }
      .card .host { margin-top: 8px; color: rgba(244,241,234,.45);
                    font: 12px/1.3 ui-monospace, monospace; overflow: hidden;
                    text-overflow: ellipsis; white-space: nowrap; }
      .card .tags { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 10px; }
      .card .rm { position: absolute; top: 6px; right: 6px; opacity: 0; transition: opacity .15s ease; }
      .card:hover .rm { opacity: 1; }
      .tag { font: 600 10px/1 ui-monospace, monospace; padding: 3px 7px;
             background: rgba(255,77,28,.18); color: #ff4d1c; border-radius: 3px;
             text-transform: uppercase; letter-spacing: .04em; }
    </style>
    </head>
    <body>
      <p class="eyebrow">Browser</p>
      <h1>Home</h1>
      <h2>Bookmarks</h2>
      #{bookmarks_body(bookmarks)}
      <h2>Recent</h2>
      #{recent_body(history)}
    </body>
    </html>
    """
  end

  defp bookmarks_body([]) do
    """
    <p class="empty">No bookmarks yet. Open a page and press <code>+ Bookmark</code> in the
    toolbar above to save it here — it'll show up as a card with its favicon and any tags.</p>
    """
  end

  defp bookmarks_body(entries) do
    cards =
      Enum.map_join(entries, "\n", fn e ->
        raw_url = e["url"]
        url = escape(raw_url)
        label = escape(e["label"] || raw_url)
        host = escape(host(raw_url))
        favicon = e["favicon_url"] || Bookmarks.favicon_url(raw_url)
        tags_html = tags_body(e["tags"])

        fav_html =
          if favicon,
            do: ~s(<img class="fav" src="#{escape(favicon)}" alt="" loading="lazy" />),
            else: ~s(<span class="fav"></span>)

        ~s(<div class="card">) <>
          ~s(<a href="#{url}">) <>
          ~s(<div class="head">#{fav_html}<span class="label">#{label}</span></div>) <>
          ~s(<div class="host">#{host}</div>#{tags_html}) <>
          ~s(</a>) <>
          ~s(<form class="rm" method="post" action="/browser/bookmarks/remove">) <>
          ~s(<input type="hidden" name="url" value="#{url}" />) <>
          ~s(<button class="rm" type="submit" title="Remove bookmark" aria-label="Remove bookmark">&times;</button>) <>
          ~s(</form></div>)
      end)

    ~s(<div class="grid">\n#{cards}\n</div>)
  end

  defp host(url) do
    case URI.parse(to_string(url)) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> to_string(url)
    end
  end

  defp tags_body(nil), do: ""
  defp tags_body([]), do: ""

  defp tags_body(tags) when is_list(tags) do
    chips = Enum.map_join(tags, "", fn t -> ~s(<span class="tag">#{escape(t)}</span>) end)
    ~s(<span class="tags">#{chips}</span>)
  end

  defp tags_body(_), do: ""

  defp recent_body([]) do
    """
    <p class="empty">No recent pages yet. Type a URL (e.g. <code>apnews.com</code>) or an
    absolute workspace path (e.g. <code>/library/notes.md</code>) in the address bar above.</p>
    """
  end

  defp recent_body(entries) do
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
