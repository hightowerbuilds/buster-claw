defmodule BusterClawWeb.NotesComponent do
  @moduledoc """
  A simple Obsidian-style note surface, as an embeddable `Phoenix.LiveComponent`.

  Left rail: the list of notes plus a "new note" title field. Main pane: a
  markdown editor beside a live reading view. Notes are plain `.md` files managed
  by `BusterClaw.Notes`; the editor autosaves on a short debounce.

  Embedded by `BusterClawWeb.StatusLive` under the homepage "Notes" sub-tab. Like
  the calendar component, every binding sets `phx-target={@myself}` so events reach
  this component rather than the host LiveView, and the note list is (re)loaded on
  mount — so switching away and back picks up any notes the agent wrote to
  `notes/` in the meantime.

  The editor `<textarea>` sits in a `phx-update="ignore"` wrapper keyed by the
  note name: the client owns the text (no cursor jumps as the server re-renders
  the reading view on each change), and selecting a different note swaps the id,
  which remounts the textarea with the new note's body.
  """
  use BusterClawWeb, :live_component

  alias BusterClaw.Markdown
  alias BusterClaw.Notes

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:selected, nil)
     |> assign(:body, "")
     |> assign(:note_form, new_form())
     |> assign(:loaded, false)}
  end

  @impl true
  def update(_assigns, socket) do
    socket =
      if socket.assigns.loaded do
        socket
      else
        Notes.ensure()
        socket |> assign(:notes, Notes.list()) |> assign(:loaded, true)
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("create_note", %{"note" => %{"title" => title}}, socket) do
    case Notes.create(title) do
      {:ok, name} ->
        {:noreply, socket |> assign(:note_form, new_form()) |> open(name)}

      {:error, :exists} ->
        # Don't clobber an existing note; just open it.
        {:noreply, open(socket, title)}

      {:error, :blank} ->
        {:noreply, socket}
    end
  end

  def handle_event("select_note", %{"name" => name}, socket) do
    {:noreply, open(socket, name)}
  end

  def handle_event("edit_body", %{"body" => body}, socket) do
    case socket.assigns.selected do
      nil ->
        {:noreply, socket}

      name ->
        case Notes.save(name, body) do
          {:ok, _note} -> {:noreply, assign(socket, :body, body)}
          # The note vanished under us (deleted elsewhere) — drop back to the list.
          {:error, _} -> {:noreply, reset_selection(socket)}
        end
    end
  end

  def handle_event("delete_note", %{"name" => name}, socket) do
    Notes.delete(name)
    socket = assign(socket, :notes, Notes.list())

    socket =
      if socket.assigns.selected == name, do: reset_selection(socket), else: socket

    {:noreply, socket}
  end

  # Load a note into the editor, refreshing the list so a just-created note shows.
  defp open(socket, name) do
    case Notes.get(name) do
      nil ->
        assign(socket, :notes, Notes.list())

      note ->
        socket
        |> assign(:notes, Notes.list())
        |> assign(:selected, note.name)
        |> assign(:body, note.body)
    end
  end

  defp reset_selection(socket) do
    socket |> assign(:selected, nil) |> assign(:body, "")
  end

  defp new_form, do: to_form(%{"title" => ""}, as: :note)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 gap-4">
      <%!-- Left rail: new-note field + the note list. --%>
      <aside class="ic-panel flex w-64 shrink-0 flex-col overflow-hidden">
        <.form
          for={@note_form}
          id="new-note-form"
          phx-submit="create_note"
          phx-target={@myself}
          class="flex gap-2 border-b-2 border-base-content/20 p-3"
        >
          <input
            type="text"
            name="note[title]"
            value={@note_form[:title].value}
            placeholder="New note title…"
            autocomplete="off"
            class="min-w-0 flex-1 rounded-xs border-2 border-base-content/20 bg-transparent px-2 py-1 font-mono text-xs focus:border-primary focus:outline-none"
          />
          <button
            type="submit"
            class="shrink-0 rounded-xs bg-primary px-2 py-1 font-mono text-xs font-bold uppercase text-primary-content transition hover:opacity-85"
            aria-label="Create note"
          >
            +
          </button>
        </.form>

        <ul class="min-h-0 flex-1 overflow-y-auto">
          <li :if={@notes == []} class="px-3 py-4 text-center font-mono text-xs text-base-content/50">
            No notes yet.
          </li>
          <li :for={note <- @notes}>
            <button
              type="button"
              phx-click="select_note"
              phx-value-name={note.name}
              phx-target={@myself}
              class={[
                "block w-full truncate border-b border-base-content/10 px-3 py-2 text-left font-mono text-xs transition",
                if(@selected == note.name,
                  do: "bg-primary/10 text-primary",
                  else: "text-base-content/80 hover:bg-base-content/5"
                )
              ]}
              title={note.name}
            >
              {note.name}
            </button>
          </li>
        </ul>
      </aside>

      <%!-- Main pane: editor + live reading view, or an empty prompt. --%>
      <section :if={@selected} class="flex min-h-0 flex-1 flex-col gap-2">
        <header class="flex items-center justify-between gap-3">
          <h2 class="truncate font-display text-lg font-black uppercase tracking-tight">
            {@selected}
          </h2>
          <button
            type="button"
            phx-click="delete_note"
            phx-value-name={@selected}
            phx-target={@myself}
            data-claw-confirm={"Delete \"#{@selected}\"?"}
            class="shrink-0 rounded-xs border-2 border-error/40 px-3 py-1 font-mono text-xs text-error transition hover:border-error"
          >
            Delete
          </button>
        </header>

        <div class="grid min-h-0 flex-1 gap-4 lg:grid-cols-2">
          <form
            id="note-editor-form"
            phx-change="edit_body"
            phx-target={@myself}
            class="flex min-h-0 flex-col"
          >
            <div id={"note-editor-#{@selected}"} phx-update="ignore" class="flex min-h-0 flex-1">
              <textarea
                name="body"
                phx-debounce="500"
                spellcheck="true"
                placeholder="Start writing… markdown supported."
                class="ic-panel min-h-64 w-full flex-1 resize-none bg-transparent p-4 font-mono text-sm leading-relaxed focus:outline-none"
              >{@body}</textarea>
            </div>
          </form>

          <article class="ic-panel prose prose-sm min-h-64 max-w-none overflow-y-auto p-4 dark:prose-invert">
            {raw(Markdown.to_html(@body))}
          </article>
        </div>
      </section>

      <section
        :if={is_nil(@selected)}
        class="ic-panel ic-scanlines flex min-h-0 flex-1 items-center justify-center p-8 text-center"
      >
        <p class="font-mono text-sm text-base-content/55">
          Select a note, or create one to start writing.
        </p>
      </section>
    </div>
    """
  end
end
