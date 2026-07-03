defmodule BusterClawWeb.HistoryLive do
  @moduledoc """
  Browsing history for the embedded browser (roadmap Phase 2.3): day-grouped,
  searchable (FTS-ranked via `BusterClaw.BrowserHistory.search/2`), with
  per-day and full clears. Entries deep-link back into the browser.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.BrowserHistory

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "History")
     |> assign(:query, "")
     |> reload()}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:query, q) |> reload()}
  end

  def handle_event("clear_day", %{"date" => iso}, socket) do
    with {:ok, date} <- Date.from_iso8601(iso),
         {:ok, from} <- DateTime.new(date, ~T[00:00:00], "Etc/UTC"),
         {:ok, to} <- DateTime.new(Date.add(date, 1), ~T[00:00:00], "Etc/UTC") do
      BrowserHistory.clear_range(from, to)
    end

    {:noreply, reload(socket)}
  end

  def handle_event("clear_all", _params, socket) do
    BrowserHistory.clear()
    {:noreply, reload(socket)}
  end

  defp reload(socket) do
    groups =
      case String.trim(socket.assigns.query) do
        "" ->
          BrowserHistory.grouped_by_day()

        q ->
          case BrowserHistory.search(q, limit: 200) do
            {:ok, entries} ->
              entries
              |> Enum.group_by(&DateTime.to_date(&1.visited_at))
              |> Enum.sort_by(fn {date, _} -> date end, {:desc, Date})

            _ ->
              []
          end
      end

    assign(socket, :groups, groups)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-between gap-4">
        <div>
          <p class="font-mono text-[11px] font-bold uppercase tracking-[0.12em] text-base-content/50">
            Browser
          </p>
          <h1 class="text-2xl font-black tracking-tight">History</h1>
        </div>
        <button
          :if={@groups != []}
          phx-click="clear_all"
          data-confirm="Clear ALL browsing history?"
          class="border-2 border-base-content/20 px-3 py-1.5 font-mono text-xs font-semibold hover:border-error hover:text-error"
        >
          Clear all
        </button>
      </div>

      <form phx-change="search" phx-submit="search" class="mt-2">
        <input
          type="text"
          name="q"
          value={@query}
          placeholder="Search history…"
          autocomplete="off"
          phx-debounce="200"
          class="w-full max-w-xl border-2 border-base-content/20 bg-base-200 px-3 py-2 font-mono text-sm outline-none focus:border-base-content/50"
        />
      </form>

      <p :if={@groups == []} class="mt-8 text-sm text-base-content/60">
        <%= if String.trim(@query) == "" do %>
          Nothing here yet — pages you visit in the browser will show up grouped by day.
        <% else %>
          No matches for “{@query}”.
        <% end %>
      </p>

      <section :for={{date, entries} <- @groups} class="mt-8">
        <div class="flex items-center justify-between border-b-2 border-base-content/15 pb-1">
          <h2 class="font-mono text-xs font-bold uppercase tracking-[0.08em] text-base-content/55">
            {Calendar.strftime(date, "%A, %B %-d, %Y")}
          </h2>
          <button
            phx-click="clear_day"
            phx-value-date={Date.to_iso8601(date)}
            data-confirm={"Clear history for #{date}?"}
            class="font-mono text-[11px] text-base-content/40 hover:text-error"
          >
            clear day
          </button>
        </div>
        <ul>
          <li
            :for={entry <- entries}
            class="flex items-baseline gap-3 border-b border-base-content/10 py-2"
          >
            <span class="w-12 shrink-0 font-mono text-xs text-base-content/40">
              {Calendar.strftime(entry.visited_at, "%H:%M")}
            </span>
            <.link
              navigate={~p"/browse?url=#{entry.url}"}
              class="min-w-0 flex-1 truncate font-semibold hover:text-primary"
            >
              {entry.title || entry.url}
            </.link>
            <span class="hidden max-w-[24rem] truncate font-mono text-xs text-base-content/40 sm:block">
              {entry.url}
            </span>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
