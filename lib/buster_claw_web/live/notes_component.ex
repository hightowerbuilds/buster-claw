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

  Three panes on wide windows, and a two-step rail → editor below `md` with the
  preview behind a toggle below `xl`. Both collapses are class-only; the panes
  are one DOM and one set of ids at every width.
  """

  use BusterClawWeb, :live_component

  import BusterClawWeb.Notes.Editor
  import BusterClawWeb.Notes.Rail

  alias BusterClaw.Notes

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
     |> assign(:preview_open, false)
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
      end

    {:ok, socket}
  end

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

  def handle_event("toggle_preview", _params, socket) do
    {:noreply, assign(socket, :preview_open, not socket.assigns.preview_open)}
  end

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
      {:noreply, assign_draft(socket, body)}
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

  defp save(%{assigns: %{selected: nil}} = socket, _body, _revision), do: {:noreply, socket}

  defp save(socket, body, expected_revision) do
    case Notes.save(socket.assigns.selected, body, expected_revision) do
      {:ok, note} ->
        {:noreply,
         socket
         |> assign_draft(note.body)
         |> assign(:revision, note.revision)
         |> assign(:save_status, :saved)
         |> assign(:save_error, nil)
         |> assign(:conflict, nil)}

      {:error, {:conflict, current}} ->
        {:noreply,
         socket
         |> assign_draft(body)
         |> assign(:save_status, :conflict)
         |> assign(:save_error, nil)
         |> assign(:conflict, current)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_draft(body)
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
  end

  defp assign_draft(socket, body) do
    socket
    |> assign(:body, body)
    |> assign(:editor_form, editor_form(body))
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

  defp reload_notes(socket) do
    stream(socket, :notes, group_headings(Notes.list()), reset: true)
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
    <div id="home-notes" class="flex min-h-0 flex-1 gap-3 lg:gap-4">
      <.rail
        target={@myself}
        notes={@streams.notes}
        selected={@selected}
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
        preview_open={@preview_open}
      />
    </div>
    """
  end
end
