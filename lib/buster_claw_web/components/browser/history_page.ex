defmodule BusterClawWeb.Browser.HistoryPage do
  @moduledoc """
  The in-app browser's history, grouped by day, with a search box and the two
  clear buttons.

  Markup only; `BusterClawWeb.BrowserHistoryPageController` does the grouping.

  The clear buttons carry `data-claw-confirm`, serviced by the shared
  interceptor in `assets/js/lib/claw_confirm.js`. They must never go back to
  `onsubmit="return confirm(…)"`: there is no WKUIDelegate in this shell, so
  `window.confirm()` returns false and cancels the submit — which is exactly how
  both buttons were silently dead in the packaged app until 08-08.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Browser.Layout

  alias BusterClawWeb.Browser.Layout

  @css """
  body { padding-bottom: 24px; }
  .top { display: flex; align-items: baseline; justify-content: space-between;
         max-width: 60rem; }
  h1 { margin: 6px 0 0; }
  form.inline { display: inline; }
  button.danger { border-radius: 4px; padding: 5px 9px; letter-spacing: normal;
                  line-height: 1; }
  form.search { margin: 18px 0 0; max-width: 60rem; }
  #q { width: 100%; max-width: 32rem; padding: 9px 12px;
       background: rgba(244,241,234,.04); border: 1px solid rgba(244,241,234,.16);
       border-radius: 6px; color: var(--fg);
       font: 14px/1 -apple-system, system-ui, sans-serif; }
  #q:focus { outline: none; border-color: rgba(255,77,28,.6); }
  #q::placeholder { color: rgba(244,241,234,.4); }
  .dayhead { display: flex; align-items: baseline; justify-content: space-between;
             max-width: 60rem; margin: 32px 0 0;
             border-bottom: 2px solid rgba(244,241,234,.15); padding-bottom: 4px; }
  h2 { margin: 0; }
  ul { margin: 4px 0 0; max-width: 60rem; }
  li { border-top: 0; border-bottom: 1px solid rgba(244,241,234,.1); display: flex;
       align-items: baseline; gap: 12px; padding: 9px 4px; }
  .when { flex: 0 0 auto; width: 3rem; color: rgba(244,241,234,.4);
          font: 12px/1.4 var(--mono); }
  li a { display: inline; padding: 0; font-weight: 600; flex: 0 1 auto;
         min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .url { flex: 1 1 auto; min-width: 0; text-align: right; }
  .empty { margin: 24px 0 0; }
  .empty a { display: inline; padding: 0; color: var(--accent); }
  """

  defp css, do: @css

  @doc """
  Render the history page to a binary.

  Takes `%{query: String.t(), groups: [{Date.t(), [entry]}]}`. Not declared with
  `attr`: this is called by hand from a controller, where `attr` never validates.
  """
  def html(assigns) do
    ~H"""
    <.browser_page title="History" eyebrow={nil} css={css()}>
      <div class="top">
        <div>
          <p class="eyebrow">Browser</p>
          <h1>History</h1>
        </div>

        <form
          :if={@groups != []}
          class="inline"
          method="post"
          action="/browser/history/clear"
          data-claw-confirm="Clear ALL browsing history?"
        >
          <input type="hidden" name="scope" value="all" />
          <button class="danger" type="submit">Clear all</button>
        </form>
      </div>

      <form class="search" method="get" action="/browser/history">
        <input
          id="q"
          type="text"
          name="q"
          value={@query}
          placeholder="Search history…"
          autocomplete="off"
          autofocus
        />
      </form>

      <p :if={@groups == [] and @query == ""} class="empty">
        Nothing here yet — pages you visit show up grouped by day.
        Head <a href="/browser/home">home</a> and browse.
      </p>

      <p :if={@groups == [] and @query != ""} class="empty">
        No matches for “{@query}”.
      </p>

      <.day :for={group <- @groups} group={group} />
    </.browser_page>
    """
    |> Layout.to_html()
  end

  attr :group, :any, required: true

  defp day(%{group: {date, entries}} = assigns) do
    assigns = Map.merge(assigns, %{date: date, entries: entries})

    ~H"""
    <div class="dayhead">
      <h2>{Calendar.strftime(@date, "%A, %B %-d, %Y")}</h2>
      <form
        class="inline"
        method="post"
        action="/browser/history/clear"
        data-claw-confirm={"Clear history for #{Date.to_iso8601(@date)}?"}
      >
        <input type="hidden" name="scope" value="day" />
        <input type="hidden" name="date" value={Date.to_iso8601(@date)} />
        <button class="danger" type="submit">clear day</button>
      </form>
    </div>

    <ul>
      <li :for={entry <- @entries}>
        <span class="when">{Calendar.strftime(entry.visited_at, "%H:%M")}</span>
        <a href={entry.url}>{entry.title || entry.url}</a>
        <span class="url">{entry.url}</span>
      </li>
    </ul>
    """
  end
end
