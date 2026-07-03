defmodule BusterClawWeb.BrowserHistoryPageController do
  @moduledoc """
  The browser-native History page (`GET /browser/history`) — rendered into the
  content webview with the homepage's dark styling, so history lives *in the
  browser* (linked from the homepage), not in the app dock. Day-grouped,
  searchable (`?q=`, FTS-ranked), with per-day and full clears
  (`POST /browser/history/clear`, plain forms + redirect — the content webview
  carries no Tauri or LiveView machinery).

  Recording stays on `BrowserHistoryController` (`POST /browser/history`,
  called by the Rust shell); this is the human view over the same data.
  Loopback-only, single-user; no CSRF (raw scope).
  """
  use BusterClawWeb, :controller

  alias BusterClaw.BrowserHistory

  def show(conn, params) do
    q = params["q"] |> to_string() |> String.trim()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page(q, groups(q)))
  end

  def clear(conn, %{"scope" => "all"}) do
    BrowserHistory.clear()
    redirect(conn, to: "/browser/history")
  end

  def clear(conn, %{"scope" => "day", "date" => iso}) do
    with {:ok, date} <- Date.from_iso8601(iso),
         {:ok, from} <- DateTime.new(date, ~T[00:00:00], "Etc/UTC"),
         {:ok, until} <- DateTime.new(Date.add(date, 1), ~T[00:00:00], "Etc/UTC") do
      BrowserHistory.clear_range(from, until)
    end

    redirect(conn, to: "/browser/history")
  end

  def clear(conn, _params), do: send_resp(conn, 400, "bad clear request")

  defp groups(""), do: BrowserHistory.grouped_by_day()

  defp groups(q) do
    case BrowserHistory.search(q, limit: 200) do
      {:ok, entries} ->
        entries
        |> Enum.group_by(&DateTime.to_date(&1.visited_at))
        |> Enum.sort_by(fn {date, _} -> date end, {:desc, Date})

      _ ->
        []
    end
  end

  defp page(q, groups) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>History</title>
    <style>
      * { box-sizing: border-box; }
      html, body { margin: 0; height: 100%; }
      body {
        background: #121212; color: #f4f1ea; padding: 40px 28px;
        font: 15px/1.5 -apple-system, system-ui, sans-serif;
      }
      .eyebrow { font: 700 11px/1 ui-monospace, monospace; letter-spacing: .12em;
                 text-transform: uppercase; color: rgba(244,241,234,.5); }
      .top { display: flex; align-items: baseline; justify-content: space-between;
             max-width: 60rem; }
      h1 { margin: 6px 0 0; font-size: 26px; font-weight: 900; letter-spacing: -.01em; }
      form.inline { display: inline; }
      button.danger { background: transparent; border: 1px solid rgba(244,241,234,.2);
                      border-radius: 4px; color: rgba(244,241,234,.55); cursor: pointer;
                      font: 600 11px/1 ui-monospace, monospace; padding: 5px 9px; }
      button.danger:hover { border-color: #ff4d1c; color: #ff4d1c; }
      form.search { margin: 18px 0 0; max-width: 60rem; }
      #q { width: 100%; max-width: 32rem; padding: 9px 12px;
           background: rgba(244,241,234,.04); border: 1px solid rgba(244,241,234,.16);
           border-radius: 6px; color: #f4f1ea;
           font: 14px/1 -apple-system, system-ui, sans-serif; }
      #q:focus { outline: none; border-color: rgba(255,77,28,.6); }
      #q::placeholder { color: rgba(244,241,234,.4); }
      .dayhead { display: flex; align-items: baseline; justify-content: space-between;
                 max-width: 60rem; margin: 32px 0 0;
                 border-bottom: 2px solid rgba(244,241,234,.15); padding-bottom: 4px; }
      h2 { margin: 0; font-size: 13px; font-weight: 700; letter-spacing: .08em;
           text-transform: uppercase; color: rgba(244,241,234,.55); }
      ul { list-style: none; margin: 4px 0 0; padding: 0; max-width: 60rem; }
      li { border-bottom: 1px solid rgba(244,241,234,.1); display: flex;
           align-items: baseline; gap: 12px; padding: 9px 4px; }
      .when { flex: 0 0 auto; width: 3rem; color: rgba(244,241,234,.4);
              font: 12px/1.4 ui-monospace, monospace; }
      li a { color: #f4f1ea; text-decoration: none; font-weight: 600; flex: 0 1 auto;
             min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      li a:hover { color: #ff4d1c; }
      .url { color: rgba(244,241,234,.45); font: 12px/1.4 ui-monospace, monospace;
             overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
             flex: 1 1 auto; min-width: 0; text-align: right; }
      .empty { color: rgba(244,241,234,.55); margin: 24px 0 0; max-width: 40rem; }
      .empty code { color: #ff4d1c; }
    </style>
    </head>
    <body>
      <div class="top">
        <div>
          <p class="eyebrow">Browser</p>
          <h1>History</h1>
        </div>
        #{clear_all_button(groups)}
      </div>
      <form class="search" method="get" action="/browser/history">
        <input id="q" type="text" name="q" value="#{escape(q)}" placeholder="Search history…"
               autocomplete="off" autofocus />
      </form>
      #{body(q, groups)}
    </body>
    </html>
    """
  end

  defp clear_all_button([]), do: ""

  defp clear_all_button(_groups) do
    """
    <form class="inline" method="post" action="/browser/history/clear"
          onsubmit="return confirm('Clear ALL browsing history?')">
      <input type="hidden" name="scope" value="all" />
      <button class="danger" type="submit">Clear all</button>
    </form>
    """
  end

  defp body("", []) do
    """
    <p class="empty">Nothing here yet — pages you visit show up grouped by day.
    Head <a href="/browser/home" style="color:#ff4d1c">home</a> and browse.</p>
    """
  end

  defp body(q, []), do: ~s(<p class="empty">No matches for “#{escape(q)}”.</p>)

  defp body(_q, groups), do: Enum.map_join(groups, "\n", &day_section/1)

  defp day_section({date, entries}) do
    items = Enum.map_join(entries, "\n", &entry_row/1)

    """
    <div class="dayhead">
      <h2>#{Calendar.strftime(date, "%A, %B %-d, %Y")}</h2>
      <form class="inline" method="post" action="/browser/history/clear"
            onsubmit="return confirm('Clear history for #{Date.to_iso8601(date)}?')">
        <input type="hidden" name="scope" value="day" />
        <input type="hidden" name="date" value="#{Date.to_iso8601(date)}" />
        <button class="danger" type="submit">clear day</button>
      </form>
    </div>
    <ul>
    #{items}
    </ul>
    """
  end

  defp entry_row(entry) do
    """
    <li>
      <span class="when">#{Calendar.strftime(entry.visited_at, "%H:%M")}</span>
      <a href="#{escape(entry.url)}">#{escape(entry.title || entry.url)}</a>
      <span class="url">#{escape(entry.url)}</span>
    </li>
    """
  end

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
