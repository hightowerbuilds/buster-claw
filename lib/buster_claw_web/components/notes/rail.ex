defmodule BusterClawWeb.Notes.Rail do
  @moduledoc """
  The Notes file rail: the vault's create surface and its browsable list, and
  the sidebar toggle (`rail_toggle/1`) that hides it.

  Pure markup over what `NotesComponent` already decided. Even the folder options
  arrive ready-made, so the rail and the editor's move form cannot disagree about
  what a folder is called.

  Below `md` the rail is the whole pane and collapses once a note is open, which
  is the first half of the two-step narrow layout.

  ## Deleting lives here

  Since the operator walk (`daily-growth/archive/08-09-26-notes-editor.md` W2) the only way to delete a
  note is to right-click its row: the trash can that used to sit beside the
  writing surface destroyed the file you were looking at, and `data-claw-confirm`
  made that survivable rather than safe. The list is where a file manager puts
  it, and a note you are not looking at can be deleted without opening it.
  """
  use BusterClawWeb, :html

  attr :target, :any, required: true, doc: "the owning LiveComponent's @myself"
  attr :notes, :list, required: true, doc: "the :notes stream"
  attr :selected, :string, default: nil
  attr :open, :boolean, required: true, doc: "the operator's sidebar toggle"
  attr :collapsed, :boolean, required: true, doc: "hide below md — a note is open"
  attr :folders, :list, required: true
  attr :folder_options, :list, required: true
  attr :new_note_form, :any, required: true
  attr :folder_form, :any, required: true
  attr :folder_form_open, :boolean, required: true
  attr :search_form, :any, required: true
  attr :query, :string, required: true

  @doc "The Notes file rail."
  def rail(assigns) do
    ~H"""
    <%!-- Minimal, after the chat's Minimal skin (10-17): mono throughout, one
          hairline to the right, inputs drawn as a left bar that turns primary
          on focus, no nested panels, no scanlines. Hidden entirely when the
          operator closes the sidebar (`open`), and below `md` while a note is
          open (`collapsed`). --%>
    <aside
      id="notes-rail"
      class={[
        "flex min-h-0 w-full shrink-0 flex-col overflow-hidden font-mono md:w-56 md:border-r md:border-base-content/15 md:pr-2 xl:w-64",
        cond do
          not @open -> "hidden"
          @collapsed -> "hidden md:flex"
          true -> "flex"
        end
      ]}
    >
      <div class="flex items-center gap-1 pb-1.5">
        <span class="flex-1 text-[0.625rem] font-semibold uppercase tracking-[0.12em] text-base-content/50">
          Notes
        </span>
        <button
          id="new-folder-button"
          type="button"
          phx-click="toggle_folder_form"
          phx-target={@target}
          aria-expanded={to_string(@folder_form_open)}
          title="New folder"
          class="grid size-6 place-items-center text-base-content/50 transition hover:text-primary"
        >
          <.icon name="hero-folder-plus" class="size-3.5" />
        </button>
        <.rail_toggle :if={@open} target={@target} open={true} />
      </div>

      <.form
        for={@search_form}
        id="notes-search-form"
        phx-change="search_notes"
        phx-submit="search_notes"
        phx-target={@target}
      >
        <.input
          field={@search_form[:query]}
          id="notes-search"
          type="search"
          phx-debounce="200"
          autocomplete="off"
          aria-label="Search notes by name or contents"
          placeholder="search…"
          class={bar_input()}
        />
      </.form>

      <%!-- One line: type a title, press Enter. The `+` is the same submit for
            a pointer. --%>
      <.form
        for={@new_note_form}
        id="new-note-form"
        phx-submit="create_note"
        phx-target={@target}
        class="pb-1"
      >
        <div class="flex items-center gap-1">
          <div class="min-w-0 flex-1">
            <.input
              field={@new_note_form[:title]}
              id="new-note-title"
              type="text"
              placeholder="new note…"
              autocomplete="off"
              aria-label="New note title"
              class={bar_input()}
            />
          </div>
          <button
            id="create-note-button"
            type="submit"
            title="Create note (Enter)"
            aria-label="Create note"
            class="mb-2 grid size-6 shrink-0 place-items-center border border-primary text-primary transition hover:bg-primary hover:text-primary-content"
          >
            <.icon name="hero-plus" class="size-3.5" />
          </button>
        </div>
        <.input
          :if={@folders != []}
          field={@new_note_form[:folder]}
          id="new-note-folder"
          type="select"
          options={@folder_options}
          aria-label="Folder for the new note"
          class="w-full border-0 border-l-2 border-base-content/20 bg-transparent px-2 py-1 font-mono text-[0.6875rem] text-base-content/70 focus:border-primary focus:outline-none"
        />
      </.form>

      <.form
        :if={@folder_form_open}
        for={@folder_form}
        id="new-folder-form"
        phx-submit="create_folder"
        phx-target={@target}
        class="flex items-center gap-1 pb-1"
      >
        <div class="min-w-0 flex-1">
          <.input
            field={@folder_form[:name]}
            id="new-folder-name"
            type="text"
            placeholder="folder name…"
            autocomplete="off"
            aria-label="New folder name"
            class={bar_input()}
          />
        </div>
        <button
          id="create-folder-button"
          type="submit"
          class="mb-2 shrink-0 border border-base-content/30 px-1.5 py-0.5 text-[0.625rem] font-semibold uppercase tracking-[0.08em] transition hover:border-primary hover:text-primary"
        >
          Add
        </button>
      </.form>

      <ul
        id="notes-list"
        phx-update="stream"
        class="min-h-0 flex-1 overflow-y-auto border-t border-base-content/15 pt-1"
      >
        <li id="notes-list-empty" class="hidden only:block px-2 py-4 text-xs text-base-content/45">
          {if @query == "", do: "No notes yet.", else: "No notes match."}
        </li>
        <li :for={{id, note} <- @notes} id={id}>
          <p
            :if={note.heading}
            data-note-heading={note.heading}
            class="mt-2 px-2 pb-0.5 text-[0.5625rem] font-semibold uppercase tracking-[0.12em] text-base-content/40 first:mt-0"
          >
            {note.heading}/
          </p>
          <%!-- `data-note-row` is the right-click surface, and it carries the
                path rather than being a bare marker: the menu is rendered once,
                outside the stream, so the row is the only place the hook can
                learn which note it is acting on. It duplicates `phx-value-path`
                deliberately — the switcher and the backlink chips carry that
                attribute too, and a right-click on those must stay native. --%>
          <button
            id={"open-#{id}"}
            type="button"
            phx-click="select_note"
            phx-value-path={note.path}
            phx-target={@target}
            data-note-row={note.path}
            aria-current={@selected == note.path && "page"}
            class={[
              "block w-full border-l-2 px-2 py-1 text-left transition",
              if(@selected == note.path,
                do: "border-primary text-base-content",
                else:
                  "border-transparent text-base-content/65 hover:border-base-content/25 hover:text-base-content"
              )
            ]}
            title={note.path}
          >
            <span class={[
              "block truncate text-xs",
              @selected == note.path && "font-semibold",
              not note.supported && "text-base-content/40"
            ]}>
              {note.title}
            </span>
            <span
              :if={not note.supported}
              class="block truncate text-[0.5625rem] uppercase text-base-content/40"
            >
              too large to edit
            </span>
            <span
              :if={Map.get(note, :snippet)}
              class="block truncate text-[0.625rem] text-base-content/45"
            >
              {note.snippet}
            </span>
          </button>
        </li>
      </ul>

      <%!-- The rail's right-click menu (W2). Rendered once, positioned and
            shown by the hook, and under `phx-update="ignore"` because the hook
            writes the half of the delete button that depends on which row was
            pressed.

            That button is the editor header's old trash can, moved verbatim:
            `phx-click`, `phx-target` and the confirm are the server's, and only
            `phx-value-path` + the message's note name are the hook's. LiveView
            and `claw_confirm` both read attributes at click time, so nothing
            here needs `pushEventTo` — which also means the confirmed delete is
            the exact code path that shipped, not a second one. --%>
      <div
        id="notes-ctx"
        phx-hook="NoteContextMenu"
        phx-update="ignore"
        hidden
        class="fixed z-50 min-w-40 border border-base-content/30 bg-base-100 shadow-lg"
      >
        <button
          id="notes-ctx-delete"
          type="button"
          data-ctx-delete
          phx-click="delete_note"
          phx-target={@target}
          class="block w-full px-3 py-1.5 text-left font-mono text-xs text-error transition hover:bg-error/10"
        >
          Delete note
        </button>
      </div>
    </aside>
    """
  end

  attr :target, :any, required: true
  attr :open, :boolean, required: true, doc: "whether the sidebar is open now"

  @doc """
  The sidebar toggle. One id, rendered in exactly one place at a time — the
  rail's own header while it is open, the editor's (or the empty state's) while
  it is closed — so the button is always where the eye already is. ⌘\\ does the
  same from anywhere in the panel (`NotesKeys`).
  """
  def rail_toggle(assigns) do
    ~H"""
    <button
      id="notes-rail-toggle"
      type="button"
      phx-click="toggle_rail"
      phx-target={@target}
      aria-controls="notes-rail"
      aria-expanded={to_string(@open)}
      title={if @open, do: "Hide sidebar (⌘\\)", else: "Show sidebar (⌘\\)"}
      class="grid size-6 shrink-0 place-items-center text-base-content/50 transition hover:text-primary"
    >
      <.icon
        name={if @open, do: "hero-chevron-double-left", else: "hero-bars-3"}
        class="size-3.5"
      />
    </button>
    """
  end

  # The chat Minimal skin's input: no box, a left bar that turns primary on
  # focus. Shared by every text field in the rail so they cannot drift apart.
  defp bar_input,
    do:
      "w-full border-0 border-l-2 border-base-content/20 bg-transparent px-2 py-1 font-mono text-xs text-base-content placeholder:text-base-content/35 focus:border-primary focus:outline-none"
end
