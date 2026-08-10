defmodule BusterClawWeb.Notes.Rail do
  @moduledoc """
  The Notes file rail: the vault's create surface and its browsable list.

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
    <aside class={[
      "ic-panel flex min-h-0 w-full shrink-0 flex-col overflow-hidden md:w-64 xl:w-72",
      @collapsed && "hidden md:flex"
    ]}>
      <header class="border-b-2 border-base-content/20 px-3 py-3">
        <p class="font-display text-base font-black uppercase tracking-tight">Notes</p>
        <p class="mt-0.5 font-mono text-[10px] uppercase tracking-wide text-base-content/50">
          Markdown files you own
        </p>
      </header>

      <.form
        for={@search_form}
        id="notes-search-form"
        phx-change="search_notes"
        phx-submit="search_notes"
        phx-target={@target}
        class="border-b-2 border-base-content/20 px-3 pt-3"
      >
        <.input
          field={@search_form[:query]}
          id="notes-search"
          type="search"
          phx-debounce="200"
          autocomplete="off"
          aria-label="Search notes by name or contents"
          placeholder="Search notes…"
          class="w-full rounded-xs border-2 border-base-content/20 bg-transparent px-2 py-1.5 font-mono text-xs text-base-content placeholder:text-base-content/35 focus:border-primary focus:outline-none"
        />
      </.form>

      <.form
        for={@new_note_form}
        id="new-note-form"
        phx-submit="create_note"
        phx-target={@target}
        class="border-b-2 border-base-content/20 p-3"
      >
        <.input
          field={@new_note_form[:title]}
          id="new-note-title"
          type="text"
          placeholder="New note title…"
          autocomplete="off"
          class="w-full rounded-xs border-2 border-base-content/20 bg-transparent px-2 py-1.5 font-mono text-xs text-base-content placeholder:text-base-content/35 focus:border-primary focus:outline-none"
        />
        <.input
          :if={@folders != []}
          field={@new_note_form[:folder]}
          id="new-note-folder"
          type="select"
          options={@folder_options}
          aria-label="Folder for the new note"
          class="w-full rounded-xs border-2 border-base-content/20 bg-transparent px-2 py-1.5 font-mono text-[11px] text-base-content focus:border-primary focus:outline-none"
        />
        <div class="mt-1 flex gap-1">
          <button
            id="create-note-button"
            type="submit"
            class="flex flex-1 items-center justify-center gap-1.5 rounded-xs bg-primary px-3 py-2 font-mono text-xs font-bold uppercase text-primary-content transition hover:-translate-y-0.5 hover:shadow-[2px_2px_0_rgb(var(--color-base-content))] active:translate-y-0 active:shadow-none"
          >
            <.icon name="hero-plus" class="size-4" /> New note
          </button>
          <button
            id="new-folder-button"
            type="button"
            phx-click="toggle_folder_form"
            phx-target={@target}
            aria-expanded={to_string(@folder_form_open)}
            title="New folder"
            class="rounded-xs border-2 border-base-content/25 px-2 py-2 text-base-content/70 transition hover:border-primary hover:text-primary"
          >
            <.icon name="hero-folder-plus" class="size-4" />
          </button>
        </div>
      </.form>

      <.form
        :if={@folder_form_open}
        for={@folder_form}
        id="new-folder-form"
        phx-submit="create_folder"
        phx-target={@target}
        class="border-b-2 border-base-content/20 p-3"
      >
        <.input
          field={@folder_form[:name]}
          id="new-folder-name"
          type="text"
          placeholder="Folder name…"
          autocomplete="off"
          class="w-full rounded-xs border-2 border-base-content/20 bg-transparent px-2 py-1.5 font-mono text-xs text-base-content placeholder:text-base-content/35 focus:border-primary focus:outline-none"
        />
        <button
          id="create-folder-button"
          type="submit"
          class="mt-1 w-full rounded-xs border-2 border-base-content/25 px-3 py-1.5 font-mono text-[11px] font-bold uppercase transition hover:border-primary hover:text-primary"
        >
          Create folder
        </button>
      </.form>

      <ul id="notes-list" phx-update="stream" class="min-h-0 flex-1 overflow-y-auto p-1.5">
        <li id="notes-list-empty" class="hidden only:block px-3 py-8 text-center">
          <.icon name="hero-document-text" class="mx-auto size-7 text-base-content/25" />
          <p class="mt-2 font-mono text-xs text-base-content/50">
            {if @query == "", do: "No notes yet.", else: "No notes match."}
          </p>
        </li>
        <li :for={{id, note} <- @notes} id={id}>
          <p
            :if={note.heading}
            data-note-heading={note.heading}
            class="mt-2 flex items-center gap-1 px-2 pb-1 font-mono text-[9px] font-bold uppercase tracking-wide text-base-content/40 first:mt-0"
          >
            <.icon name="hero-folder" class="size-3" />{note.heading}
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
              "group flex w-full items-center gap-2 rounded-xs px-2.5 py-2 text-left transition",
              if(@selected == note.path,
                do: "bg-primary/12 text-primary",
                else: "text-base-content/75 hover:bg-base-content/7 hover:text-base-content"
              )
            ]}
            title={note.path}
          >
            <.icon
              name={if(note.supported, do: "hero-document-text", else: "hero-lock-closed")}
              class="size-4 shrink-0 opacity-55"
            />
            <span class="min-w-0 flex-1">
              <span class={[
                "block truncate font-mono text-xs font-bold",
                not note.supported && "text-base-content/45"
              ]}>
                {note.title}
              </span>
              <span
                :if={not note.supported}
                class="block truncate font-mono text-[9px] uppercase text-base-content/40"
              >
                Too large to edit
              </span>
              <span
                :if={Map.get(note, :snippet)}
                class="block truncate font-mono text-[10px] font-normal text-base-content/50"
              >
                {note.snippet}
              </span>
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
        class="fixed z-50 min-w-44 border-2 border-base-content/30 bg-base-100 shadow-lg"
      >
        <button
          id="notes-ctx-delete"
          type="button"
          data-ctx-delete
          phx-click="delete_note"
          phx-target={@target}
          class="block w-full px-3 py-2 text-left font-mono text-xs font-bold uppercase text-error transition hover:bg-error/10"
        >
          Delete note
        </button>
      </div>
    </aside>
    """
  end
end
