defmodule BusterClawWeb.JournalComponent do
  @moduledoc """
  The minutes of the day, as an embeddable `Phoenix.LiveComponent` — the
  homepage "Notes" sub-tab.

  Left rail: the list of days that have minutes (newest first). Main pane: the
  selected day rendered as markdown, with a composer underneath that appends an
  operator-marked entry to **today** — the journal is chronological, so there is
  no retro-editing surface; your item lands at the end of today's document
  regardless of which day you were reading. Agent entries arrive through the
  `journal_append` command; `BusterClawWeb.StatusLive` subscribes to
  `BusterClaw.Journal` updates and pings this component (`send_update` with a
  fresh `:refresh` value) so the open pane updates live.

  The composer `<textarea>` sits in a `phx-update="ignore"` wrapper keyed by
  `@composer_rev`: the client owns the draft while agent appends re-render the
  reading view, and bumping the rev after a successful append remounts the
  textarea empty.
  """
  use BusterClawWeb, :live_component

  alias BusterClaw.Journal
  alias BusterClaw.Markdown

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:selected, nil)
     |> assign(:composer_rev, 0)
     |> assign(:loaded, false)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      if socket.assigns.loaded and not Map.has_key?(assigns, :refresh) do
        socket
      else
        socket |> assign(:loaded, true) |> reload()
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("select_day", %{"name" => name}, socket) do
    {:noreply, socket |> assign(:selected, name) |> reload()}
  end

  def handle_event("add_entry", %{"text" => text}, socket) do
    case Journal.append(text, :operator) do
      {:ok, day} ->
        # Jump to today (where the entry landed) and remount the composer empty.
        {:noreply,
         socket
         |> assign(:selected, day.name)
         |> assign(:composer_rev, socket.assigns.composer_rev + 1)
         |> reload()}

      {:error, :blank} ->
        {:noreply, socket}
    end
  end

  # (Re)load the day list and the selected day's body. Selection falls back to
  # today so a fresh day opens on its (possibly still empty) document.
  defp reload(socket) do
    selected = socket.assigns.selected || Journal.today_name()

    socket
    |> assign(:days, Journal.list())
    |> assign(:selected, selected)
    |> assign(:day, Journal.get(selected))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 gap-4">
      <%!-- Left rail: the days that have minutes, newest first. --%>
      <aside class="ic-panel flex w-64 shrink-0 flex-col overflow-hidden">
        <p class="border-b-2 border-base-content/20 p-3 font-mono text-xs font-bold uppercase tracking-wide text-base-content/70">
          Daily minutes
        </p>

        <ul class="min-h-0 flex-1 overflow-y-auto">
          <li :if={@days == []} class="px-3 py-4 text-center font-mono text-xs text-base-content/50">
            No minutes yet.
          </li>
          <li :for={day <- @days}>
            <button
              type="button"
              phx-click="select_day"
              phx-value-name={day.name}
              phx-target={@myself}
              class={[
                "flex w-full items-baseline justify-between border-b border-base-content/10 px-3 py-2 text-left font-mono text-xs transition",
                if(@selected == day.name,
                  do: "bg-primary/10 text-primary",
                  else: "text-base-content/80 hover:bg-base-content/5"
                )
              ]}
            >
              <span>{day.name}</span>
              <span
                :if={day.name == Journal.today_name()}
                class="text-[10px] uppercase text-base-content/50"
              >
                today
              </span>
            </button>
          </li>
        </ul>
      </aside>

      <%!-- Main pane: the day's minutes + the operator composer. --%>
      <section class="flex min-h-0 flex-1 flex-col gap-2">
        <header class="flex items-baseline justify-between gap-3">
          <h2 class="truncate font-display text-lg font-black uppercase tracking-tight">
            {@selected}
          </h2>
          <p class="shrink-0 font-mono text-[10px] uppercase text-base-content/50">
            Agent minutes + your items
          </p>
        </header>

        <article
          :if={@day}
          id="journal-reading"
          class="ic-panel prose prose-sm min-h-0 max-w-none flex-1 overflow-y-auto p-4 dark:prose-invert"
        >
          {raw(Markdown.to_html(@day.body))}
        </article>

        <div
          :if={is_nil(@day)}
          class="ic-panel ic-scanlines flex min-h-0 flex-1 items-center justify-center p-8 text-center"
        >
          <p class="font-mono text-sm text-base-content/55">
            No minutes for this day yet. The document starts with the first entry.
          </p>
        </div>

        <form
          id="journal-composer-form"
          phx-submit="add_entry"
          phx-target={@myself}
          class="flex items-end gap-2"
        >
          <div id={"journal-composer-#{@composer_rev}"} phx-update="ignore" class="min-w-0 flex-1">
            <textarea
              name="text"
              rows="2"
              spellcheck="true"
              placeholder="Add your own item to today's minutes… markdown supported."
              class="ic-panel w-full resize-none bg-transparent p-3 font-mono text-sm leading-relaxed focus:outline-none"
            ></textarea>
          </div>
          <button
            type="submit"
            class="shrink-0 rounded-xs bg-primary px-3 py-2 font-mono text-xs font-bold uppercase text-primary-content transition hover:opacity-85"
          >
            Add
          </button>
        </form>
      </section>
    </div>
    """
  end
end
