defmodule BusterClawWeb.NotesComponent do
  @moduledoc """
  The homepage Markdown notebook.

  The component owns note selection, editing, preview, and optimistic save
  state. Files remain ordinary workspace Markdown managed by `BusterClaw.Notes`.
  Activity/minutes are intentionally rendered by `ActivityComponent` instead.

  ## Where each save state comes from

  `Unsaved` and `Saving…` cannot both come from here, and pretending otherwise
  is how a status chip starts lying:

    * `Unsaved` is the `NoteEditor` hook's `note_dirty`, because `phx-debounce`
      means the server hears nothing for 700ms after a keystroke.
    * `Saving…` is CSS on LiveView's `phx-change-loading`, because the in-flight
      request is over before any assign made during it could paint.
    * `Saved`, `Conflict`, and `Save failed` are this module's, because only the
      write knows.

  ## Layout

  Two panes — rail and editor — collapsing to a two-step rail → editor below
  `md`. The collapse is class-only; the panes are one DOM and one set of ids at
  every width.

  The editor renders its own Markdown (`daily-growth/archive/08-09-26-notes-editor.md` Phase 1), so there
  is no preview pane and this module holds no rendered HTML. Its only remaining
  Markdown-shaped job is resolving a clicked `[[wiki link]]`, which needs the
  vault index and therefore has to be here.
  """

  use BusterClawWeb, :live_component

  import BusterClawWeb.Notes.Editor
  import BusterClawWeb.Notes.Rail
  import BusterClawWeb.Notes.Switcher

  alias BusterClaw.Notes

  # The switcher is a jump list, not a search results page: past a screenful,
  # more rows are noise. The count of what was left out is shown rather than
  # dropped silently.
  @switcher_limit 20

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:selected, nil)
     |> assign(:body, "")
     |> assign(:revision, nil)
     |> assign(:conflict, nil)
     |> assign(:unsupported, nil)
     |> assign(:save_status, :idle)
     |> assign(:save_error, nil)
     |> assign(:folders, [])
     |> assign(:new_note_form, new_note_form())
     |> assign(:folder_form, folder_form())
     |> assign(:rename_form, rename_form(nil))
     |> assign(:editor_form, editor_form(""))
     |> assign(:folder_form_open, false)
     |> assign(:renaming, false)
     |> assign(:backlinks, [])
     |> assign(:query, "")
     |> assign(:index, [])
     |> assign(:search_form, search_form(""))
     |> assign(:switcher_open, false)
     |> assign(:switcher_form, switcher_form(""))
     |> assign(:switcher_results, [])
     |> assign(:switcher_total, 0)
     |> assign(:switcher_index, 0)
     |> assign(:loaded, false)
     |> stream(:notes, [])}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns.loaded and not Map.has_key?(assigns, :refresh) do
        socket
      else
        Notes.ensure()

        socket
        |> assign(:loaded, true)
        |> load_folders()
        |> reload_notes()
        |> refresh_open_note()
      end

    {:ok, socket}
  end

  # The vault changed — an agent command, another window, an external editor.
  # The list is already back; this decides what it means for the note on screen,
  # and it is the same decision the focus check makes, deliberately: a clean
  # editor adopts the new bytes, a draft in flight gets the conflict banner.
  defp refresh_open_note(%{assigns: %{selected: nil}} = socket), do: socket

  defp refresh_open_note(%{assigns: %{save_status: :conflict}} = socket), do: socket

  defp refresh_open_note(socket),
    do: reconcile(socket, Notes.get(socket.assigns.selected))

  @impl true
  def handle_event("create_note", %{"note" => params}, socket) do
    title = Map.get(params, "title", "")
    folder = Map.get(params, "folder", "")

    case Notes.create(title, folder) do
      {:ok, note} ->
        {:noreply,
         socket
         |> assign(:new_note_form, new_note_form(folder))
         |> assign(:unsupported, nil)
         |> reload_notes()
         |> open(note)}

      {:error, reason} ->
        {:noreply,
         assign(socket, :new_note_form, form_error(params, :note, create_error(reason)))}
    end
  end

  def handle_event("toggle_folder_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:folder_form_open, not socket.assigns.folder_form_open)
     |> assign(:folder_form, folder_form())}
  end

  def handle_event("create_folder", %{"folder" => params}, socket) do
    case Notes.create_folder(Map.get(params, "name", "")) do
      :ok ->
        {:noreply,
         socket
         |> assign(:folder_form_open, false)
         |> assign(:folder_form, folder_form())
         |> load_folders()}

      {:error, reason} ->
        {:noreply,
         assign(socket, :folder_form, form_error(params, :folder, folder_error(reason)))}
    end
  end

  def handle_event("select_note", %{"path" => path}, socket) do
    case Notes.get(path) do
      note when is_map(note) -> {:noreply, socket |> assign(:unsupported, nil) |> open(note)}
      nil -> {:noreply, socket |> clear_selection() |> reload_notes()}
      {:error, reason} -> {:noreply, unsupported(socket, path, reason)}
    end
  end

  def handle_event("close_note", _params, socket) do
    {:noreply, clear_selection(socket)}
  end

  def handle_event("search_notes", %{"search" => params}, socket) do
    query = Map.get(params, "query", "")

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:search_form, search_form(query))
     |> reload_notes()}
  end

  # ⌘N. Clearing the selection is what makes this work on a narrow window, where
  # the rail — and the field about to be focused — is hidden behind the editor.
  def handle_event("new_note", _params, socket) do
    {:noreply, socket |> close_switcher() |> clear_selection()}
  end

  def handle_event("open_switcher", _params, socket) do
    {:noreply,
     socket
     |> assign(:switcher_open, true)
     |> assign(:switcher_form, switcher_form(""))
     |> switcher_results("")}
  end

  def handle_event("close_switcher", _params, socket) do
    {:noreply, close_switcher(socket)}
  end

  def handle_event("switcher_search", %{"switcher" => params}, socket) do
    query = Map.get(params, "query", "")

    {:noreply,
     socket
     |> assign(:switcher_form, switcher_form(query))
     |> switcher_results(query)}
  end

  def handle_event("switcher_move", %{"dir" => dir}, socket) do
    count = length(socket.assigns.switcher_results)

    index =
      case {dir, socket.assigns.switcher_index} do
        {_dir, _current} when count == 0 -> 0
        {"up", current} -> rem(current - 1 + count, count)
        {_down, current} -> rem(current + 1, count)
      end

    {:noreply, assign(socket, :switcher_index, index)}
  end

  def handle_event("switcher_select", _params, socket) do
    case Enum.at(socket.assigns.switcher_results, socket.assigns.switcher_index) do
      %{path: path} -> open_path(close_switcher(socket), path)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("switcher_pick", %{"path" => path}, socket) do
    open_path(close_switcher(socket), path)
  end

  # A `[[wiki link]]` clicked in the editor. The editor sends the raw target and
  # nothing else: resolution needs the vault index and the fuzzy basename match,
  # and a second implementation of that in JavaScript is two sources of truth for
  # what a link means.
  #
  # An unresolved target is created rather than refused, which is the whole point
  # of a wiki link — you write the name first and the note follows.
  def handle_event("follow_link", %{"target" => target}, socket) do
    case Notes.resolve_link(target, socket.assigns.index) do
      nil -> create_link(socket, target)
      path -> open_path(socket, path)
    end
  end

  # Pushed by the `NoteTitle` hook when the operator double-clicks the open
  # note's title (or presses Enter/F2 on it), and by the form's own Cancel. It
  # stayed a toggle when the pencil that used to push it was removed (W1),
  # because Cancel and a second double-click are the same intent.
  def handle_event("toggle_rename", _params, socket) do
    {:noreply,
     socket
     |> assign(:renaming, not socket.assigns.renaming)
     |> assign(:rename_form, rename_form(socket.assigns.selected))}
  end

  def handle_event("rename_note", %{"rename" => params}, socket) do
    path = socket.assigns.selected
    title = Map.get(params, "title", "")
    folder = Map.get(params, "folder", "")

    with {:ok, renamed} <- rename_step(path, title),
         {:ok, moved} <- move_step(renamed.path, folder) do
      {:noreply,
       socket
       |> assign(:renaming, false)
       |> load_folders()
       |> reload_notes()
       |> open(moved)}
    else
      {:error, reason} ->
        {:noreply,
         assign(socket, :rename_form, form_error(params, :rename, rename_error(reason)))}
    end
  end

  def handle_event("save_note", %{"editor" => %{"body" => body}}, socket) do
    # A conflict has stopped autosave. Keep taking the user's typing; just do
    # not hand it to a save that would have to be forced to land.
    if socket.assigns.save_status == :conflict do
      {:noreply, assign_body(socket, body)}
    else
      save(socket, body, socket.assigns.revision)
    end
  end

  def handle_event("note_dirty", _params, socket) do
    if socket.assigns.selected && socket.assigns.save_status != :conflict do
      {:noreply, assign(socket, :save_status, :unsaved)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("check_revision", _params, socket) do
    if socket.assigns.selected && socket.assigns.save_status != :conflict do
      {:noreply, reconcile(socket, Notes.get(socket.assigns.selected))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reload_conflict", _params, socket) do
    case socket.assigns.conflict do
      note when is_map(note) -> {:noreply, open(socket, note)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("overwrite_conflict", _params, socket) do
    save(socket, socket.assigns.body, :force)
  end

  # The rail's right-click menu, past `data-claw-confirm` (W2). `path` is any
  # row's, not necessarily the open note's — which is why the clause below asks
  # rather than assumes before clearing the editor.
  def handle_event("delete_note", %{"path" => path}, socket) do
    case Notes.delete(path) do
      :ok ->
        socket = reload_notes(socket)

        if socket.assigns.selected == path do
          {:noreply, clear_selection(socket)}
        else
          {:noreply, socket}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:save_status, :error)
         |> assign(:save_error, error_message(reason))}
    end
  end

  defp create_link(socket, target) do
    {folder, name} = split_link_title(target)

    case Notes.create(name, folder) do
      {:ok, note} ->
        {:noreply, socket |> reload_notes() |> load_folders() |> open(note)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:save_status, :error)
         |> assign(:save_error, create_error(reason))}
    end
  end

  defp save(%{assigns: %{selected: nil}} = socket, _body, _revision), do: {:noreply, socket}

  defp save(socket, body, expected_revision) do
    case Notes.save(socket.assigns.selected, body, expected_revision) do
      {:ok, note} ->
        {:noreply,
         socket
         |> assign_body(note.body)
         |> assign(:revision, note.revision)
         |> assign(:save_status, :saved)
         |> assign(:save_error, nil)
         |> assign(:conflict, nil)}

      {:error, {:conflict, current}} ->
        {:noreply,
         socket
         |> assign_body(body)
         |> assign(:save_status, :conflict)
         |> assign(:save_error, nil)
         |> assign(:conflict, current)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_body(body)
         |> assign(:save_status, :error)
         |> assign(:save_error, error_message(reason))}
    end
  end

  # Disk moved under an open note. Silent when the editor is clean — that is a
  # refresh, and refusing to show the newer file would be the surprising choice.
  # A draft in flight turns the same fact into the conflict banner instead.
  defp reconcile(socket, %{revision: revision} = note) do
    cond do
      revision == socket.assigns.revision -> socket
      socket.assigns.save_status == :unsaved -> conflicted(socket, note)
      true -> open(socket, note)
    end
  end

  defp reconcile(socket, nil), do: socket |> clear_selection() |> reload_notes()

  defp reconcile(socket, {:error, reason}),
    do: unsupported(socket, socket.assigns.selected, reason)

  defp conflicted(socket, note) do
    socket
    |> assign(:save_status, :conflict)
    |> assign(:conflict, note)
    |> assign(:save_error, nil)
  end

  defp open(socket, note) do
    socket
    |> assign(:selected, note.path)
    |> assign_draft(note.body)
    |> assign(:revision, note.revision)
    |> assign(:save_status, :saved)
    |> assign(:save_error, nil)
    |> assign(:conflict, nil)
    |> assign(:renaming, false)
    |> assign(:unsupported, nil)
    |> assign(:backlinks, Notes.backlinks(note.path))
  end

  defp open_path(socket, path) do
    case Notes.get(path) do
      note when is_map(note) -> {:noreply, open(socket, note)}
      nil -> {:noreply, socket |> clear_selection() |> reload_notes()}
      {:error, reason} -> {:noreply, unsupported(socket, path, reason)}
    end
  end

  # Two ways to take in text, and the difference is load-bearing.
  #
  # `assign_body/2` records what the note now contains WITHOUT re-rendering the
  # form field. Every save takes this path. `assign_draft/2` also re-renders the
  # field, and only a genuine "here is different text" event may: opening a note,
  # reloading the disk version, resolving a conflict, closing the editor.
  #
  # Why the split exists. The `<textarea>` is now hidden and never focused — it
  # is the model behind the contenteditable, not the editor itself. LiveView
  # deliberately does not clobber a FOCUSED input, which is what used to make
  # echoing the saved body back harmless. Unfocused, that protection is gone: the
  # server's copy lands on the client mid-keystroke, the `NoteEditor` hook sees a
  # value it did not write, rebuilds the whole surface, and the caret and the
  # characters typed during the round-trip go with it.
  #
  # That is what "flickering between saved and unsaved in a rough manner" was
  # (operator, 08-09), and it was introduced by hiding the textarea rather than
  # by anything in the save logic. **The client owns the draft; the server
  # confirms it.** A longer debounce would only have made the collision rarer.
  defp assign_body(socket, body), do: assign(socket, :body, body)

  defp assign_draft(socket, body) do
    socket
    |> assign_body(body)
    |> assign(:editor_form, editor_form(body))
  end

  # A link target may name a folder ("Projects/Launch"); creation takes the
  # folder and the title separately, and inventing folders from a link would be
  # a filesystem write nobody asked for.
  defp split_link_title(title) do
    case Path.dirname(title) do
      "." -> {"", title}
      folder -> {folder, Path.basename(title)}
    end
  end

  defp close_switcher(socket) do
    socket
    |> assign(:switcher_open, false)
    |> assign(:switcher_index, 0)
  end

  defp switcher_results(socket, query) do
    all =
      case String.trim(query) do
        "" -> socket.assigns.index
        term -> Notes.search(term)
      end

    socket
    |> assign(:switcher_results, Enum.take(all, @switcher_limit))
    |> assign(:switcher_total, length(all))
    |> assign(:switcher_index, 0)
  end

  defp clear_selection(socket) do
    socket
    |> assign(:selected, nil)
    |> assign(:revision, nil)
    |> assign_draft("")
    |> assign(:save_status, :idle)
    |> assign(:save_error, nil)
    |> assign(:conflict, nil)
    |> assign(:unsupported, nil)
    |> assign(:renaming, false)
  end

  # Too large, not UTF-8, or unreadable: the file exists and stays exactly as it
  # is. The socket never carries its bytes and the editor never opens it.
  defp unsupported(socket, path, reason) do
    socket
    |> clear_selection()
    |> assign(:unsupported, %{path: path, reason: reason})
  end

  defp rename_step(path, title) do
    if Path.rootname(Path.basename(path)) == String.trim(title) do
      current(path)
    else
      Notes.rename(path, title)
    end
  end

  defp move_step(path, folder) do
    if folder_of(path) == folder do
      current(path)
    else
      Notes.move(path, folder)
    end
  end

  defp current(path) do
    case Notes.get(path) do
      note when is_map(note) -> {:ok, note}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  # `index` is the same list the rail streams, kept as a plain assign because a
  # stream cannot be read back and both wiki-link resolution and the switcher
  # need to consult it without re-walking the vault.
  defp reload_notes(socket) do
    index = Notes.list()
    shown = if socket.assigns.query == "", do: index, else: Notes.search(socket.assigns.query)

    socket
    |> assign(:index, index)
    |> stream(:notes, group_headings(shown), reset: true)
  end

  defp load_folders(socket), do: assign(socket, :folders, Notes.folders())

  # One heading per run of same-folder paths, computed here because a stream
  # item cannot see the one before it in the template. Safe because the list is
  # always reset whole; nothing is ever spliced into the middle of a run.
  defp group_headings(notes) do
    notes
    |> Enum.map_reduce(:none, fn note, previous ->
      folder = folder_of(note.path)
      heading = if folder != previous and folder != "", do: folder
      {Map.put(note, :heading, heading), folder}
    end)
    |> elem(0)
  end

  defp folder_of(path) do
    case Path.dirname(path) do
      "." -> ""
      folder -> folder
    end
  end

  defp folder_options(folders), do: [{"Notes root", ""} | Enum.map(folders, &{&1, &1})]

  defp new_note_form(folder \\ ""),
    do: to_form(%{"title" => "", "folder" => folder}, as: :note)

  defp folder_form, do: to_form(%{"name" => ""}, as: :folder)
  defp editor_form(body), do: to_form(%{"body" => body}, as: :editor)
  defp search_form(query), do: to_form(%{"query" => query}, as: :search)
  defp switcher_form(query), do: to_form(%{"query" => query}, as: :switcher)

  defp rename_form(nil), do: to_form(%{"title" => "", "folder" => ""}, as: :rename)

  defp rename_form(path) do
    to_form(
      %{"title" => Path.rootname(Path.basename(path)), "folder" => folder_of(path)},
      as: :rename
    )
  end

  defp form_error(params, as, message),
    do: to_form(params, as: as, errors: [{error_field(as), {message, []}}])

  defp error_field(:folder), do: :name
  defp error_field(_as), do: :title

  defp create_error(:blank), do: "Give the note a title."
  defp create_error(:exists), do: "A note with that title already exists."
  defp create_error(reason), do: error_message(reason)

  defp folder_error(:blank), do: "Give the folder a name."
  defp folder_error(:exists), do: "That folder already exists."
  defp folder_error(:invalid_path), do: "That folder name is not allowed."
  defp folder_error(reason), do: error_message(reason)

  defp rename_error(:blank), do: "Give the note a name."
  defp rename_error(:exists), do: "A note with that name is already there."
  defp rename_error(:folder_not_found), do: "That folder no longer exists."
  defp rename_error(reason), do: error_message(reason)

  defp error_message(:too_large), do: "This note is too large to edit here."
  defp error_message(:folder_not_found), do: "That folder no longer exists."
  defp error_message(:not_found), do: "That note no longer exists."
  defp error_message(_reason), do: "Buster Claw could not save this note."

  defp unsupported_text(%{reason: :too_large}),
    do: "This file is larger than Buster Claw edits in the browser. It is untouched on disk."

  defp unsupported_text(%{reason: :binary}),
    do: "This file is not UTF-8 text, so it cannot be edited as Markdown here."

  defp unsupported_text(_unsupported),
    do: "Buster Claw could not open this file. It is untouched on disk."

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="home-notes"
      phx-hook="NotesKeys"
      phx-target={@myself}
      data-switcher-open={to_string(@switcher_open)}
      class="flex min-h-0 flex-1 gap-3 lg:gap-4"
    >
      <.switcher
        target={@myself}
        open={@switcher_open}
        form={@switcher_form}
        results={@switcher_results}
        total={@switcher_total}
        index={@switcher_index}
      />

      <.rail
        target={@myself}
        notes={@streams.notes}
        selected={@selected}
        search_form={@search_form}
        query={@query}
        collapsed={!is_nil(@selected) or !is_nil(@unsupported)}
        folders={@folders}
        folder_options={folder_options(@folders)}
        new_note_form={@new_note_form}
        folder_form={@folder_form}
        folder_form_open={@folder_form_open}
      />

      <section
        :if={is_nil(@selected) and is_nil(@unsupported)}
        id="notes-empty-state"
        class="ic-panel ic-scanlines hidden min-h-0 flex-1 items-center justify-center p-8 text-center md:flex"
      >
        <div class="max-w-sm">
          <div class="mx-auto flex size-12 items-center justify-center rounded-full border-2 border-base-content/15 bg-base-content/5">
            <.icon name="hero-pencil-square" class="size-6 text-primary" />
          </div>
          <h2 class="mt-4 font-display text-xl font-black uppercase tracking-tight">
            Your Markdown notebook
          </h2>
          <p class="mt-2 font-mono text-xs leading-relaxed text-base-content/55">
            Create a note to start writing. Every page is saved as a plain Markdown file in
            your workspace.
          </p>
        </div>
      </section>

      <section
        :if={@unsupported}
        id="notes-unsupported"
        class="ic-panel flex min-h-0 flex-1 flex-col items-center justify-center gap-3 p-8 text-center"
      >
        <.icon name="hero-lock-closed" class="size-8 text-base-content/35" />
        <h2 class="font-display text-lg font-black uppercase tracking-tight">
          Not editable here
        </h2>
        <p class="max-w-sm font-mono text-xs leading-relaxed text-base-content/60">
          {unsupported_text(@unsupported)}
        </p>
        <p class="font-mono text-[10px] uppercase tracking-wide text-base-content/40">
          {@unsupported.path}
        </p>
        <button
          id="unsupported-back-button"
          type="button"
          phx-click="close_note"
          phx-target={@myself}
          class="rounded-xs border-2 border-base-content/25 px-3 py-1.5 font-mono text-[11px] font-bold uppercase transition hover:border-primary hover:text-primary"
        >
          Back to notes
        </button>
      </section>

      <.editor
        target={@myself}
        selected={@selected}
        body={@body}
        save_status={@save_status}
        save_error={@save_error}
        renaming={@renaming}
        rename_form={@rename_form}
        folder_options={folder_options(@folders)}
        editor_form={@editor_form}
        backlinks={@backlinks}
      />
    </div>
    """
  end
end
