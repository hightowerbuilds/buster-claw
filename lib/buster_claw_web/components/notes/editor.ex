defmodule BusterClawWeb.Notes.Editor do
  @moduledoc """
  The Notes editor pane: title bar, move form, conflict banner, writing surface.

  Pure markup; every save decision is `NotesComponent`'s. The pane is also the
  `NoteEditor` hook's root, which is why the conflict banner lives inside it —
  "Copy my draft" reaches the model through the same hook that owns ⌘S.

  ## The header has no command buttons, on purpose

  It carried a pencil (rename) and a trash can (delete) until the operator walk
  (`daily-growth/archive/08-09-26-notes-editor.md` W1/W2). Both were the shape you reach for when you are
  thinking about the *form* rather than the *document*: a word processor renames
  by its title and deletes from its file list, and it does not park a destructive
  control two centimetres from the text you are typing.

  So rename is a double-click on the `<h2>` (`NoteTitle` hook → the same
  `toggle_rename` event the pencil pushed), and delete moved to a right-click on
  the rail's rows (`Notes.Rail`). Neither server handler changed.

  ## Two elements, one of them invisible

  The `<textarea>` is the **model**: server-rendered, form-serialized, and the
  only thing `save_note` ever sees. It is `hidden` and never focused.

  The contenteditable beside it is the **view** — the live-preview surface the
  `NoteEditor` hook fills from that textarea, one `<div>` per line. It carries
  `phx-update="ignore"` because the hook owns its children; the server reaches it
  only by changing the textarea, which the hook watches.

  Keeping the textarea rather than replacing it with a `push_event` channel is
  what leaves autosave, `phx-debounce`, the revision check and the whole conflict
  design untouched by this feature (`daily-growth/archive/08-09-26-notes-editor.md` D4).

  There is no preview pane. The surface *is* the preview — headings render as
  headings — so a second rendering of the same text beside it was two of the
  same thing (D7).
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Notes.Toolbar

  attr :target, :any, required: true, doc: "the owning LiveComponent's @myself"
  attr :selected, :string, default: nil
  attr :body, :string, required: true
  attr :save_status, :atom, required: true
  attr :save_error, :string, default: nil
  attr :renaming, :boolean, required: true
  attr :rename_form, :any, required: true
  attr :folder_options, :list, required: true
  attr :editor_form, :any, required: true
  attr :backlinks, :list, required: true

  @doc "The Notes editor pane."
  def editor(assigns) do
    ~H"""
    <section
      :if={@selected}
      id="notes-editor-pane"
      phx-hook="NoteEditor"
      phx-target={@target}
      data-save-state={@save_status}
      data-note-path={@selected}
      class="flex min-h-0 min-w-0 flex-1 flex-col gap-2"
    >
      <header class="flex flex-wrap items-center justify-between gap-2 border-b-2 border-base-content/15 pb-2">
        <div class="flex min-w-0 items-center gap-2">
          <button
            id="close-note-button"
            type="button"
            phx-click="close_note"
            phx-target={@target}
            aria-label="Back to all notes"
            class="rounded-xs border-2 border-base-content/25 p-1.5 text-base-content/70 transition hover:border-primary hover:text-primary md:hidden"
          >
            <.icon name="hero-arrow-left" class="size-4" />
          </button>
          <div class="min-w-0">
            <%!-- The title IS the rename control (W1). `tabindex` + the
                  `NoteTitle` hook's Enter/F2 keep it operable without a
                  pointer; `select-none` is load-bearing rather than cosmetic,
                  because a double-click on text otherwise selects the word it
                  landed on before the form appears. --%>
            <h2
              id="note-title"
              phx-hook="NoteTitle"
              phx-target={@target}
              tabindex="0"
              aria-keyshortcuts="F2"
              title="Double-click to rename or move this note (Enter or F2 when focused)"
              class="cursor-pointer select-none truncate font-display text-lg font-black uppercase tracking-tight focus-visible:outline-2 focus-visible:outline-primary"
            >
              {Path.basename(@selected)}
            </h2>
            <p class="truncate font-mono text-[10px] text-base-content/45">{@selected}</p>
          </div>
        </div>
        <p
          id="note-save-status"
          data-state={@save_status}
          class={[
            "rounded-full border px-2.5 py-1 font-mono text-[10px] font-bold uppercase tracking-wide",
            status_class(@save_status)
          ]}
        >
          <span data-note-state>{status_text(@save_status)}</span>
          <span data-note-saving>Saving…</span>
        </p>
      </header>

      <.form
        :if={@renaming}
        for={@rename_form}
        id="rename-note-form"
        phx-submit="rename_note"
        phx-target={@target}
        class="flex flex-wrap items-end gap-2 border-2 border-base-content/20 bg-base-content/4 px-3 py-2"
      >
        <div class="min-w-40 flex-1">
          <%!-- The gesture that opens this form does not focus anything by
                itself, so the field takes the focus on mount. That is also the
                only feedback a keyboard user gets that F2 worked: a heading
                cannot carry `aria-expanded`, and inventing a button role for it
                would cost the heading its own. --%>
          <.input
            field={@rename_form[:title]}
            id="rename-note-title"
            type="text"
            label="Name"
            autocomplete="off"
            phx-mounted={JS.focus()}
            class="w-full rounded-xs border-2 border-base-content/20 bg-transparent px-2 py-1.5 font-mono text-xs focus:border-primary focus:outline-none"
          />
        </div>
        <div class="min-w-36">
          <.input
            field={@rename_form[:folder]}
            id="rename-note-folder"
            type="select"
            label="Folder"
            options={@folder_options}
            class="w-full rounded-xs border-2 border-base-content/20 bg-transparent px-2 py-1.5 font-mono text-[11px] focus:border-primary focus:outline-none"
          />
        </div>
        <div class="mb-2 flex gap-2">
          <button
            id="rename-note-submit"
            type="submit"
            class="rounded-xs bg-primary px-3 py-1.5 font-mono text-[11px] font-bold uppercase text-primary-content transition hover:-translate-y-0.5 active:translate-y-0"
          >
            Move
          </button>
          <button
            id="rename-note-cancel"
            type="button"
            phx-click="toggle_rename"
            phx-target={@target}
            class="rounded-xs border-2 border-base-content/25 px-3 py-1.5 font-mono text-[11px] font-bold uppercase transition hover:border-primary hover:text-primary"
          >
            Cancel
          </button>
        </div>
      </.form>

      <div
        :if={@save_status == :conflict}
        id="note-conflict"
        role="alert"
        class="flex flex-wrap items-center justify-between gap-3 border-2 border-warning/40 bg-warning/10 px-3 py-2"
      >
        <p class="font-mono text-xs text-base-content/80">
          This file changed outside the editor. Autosave has stopped, and your draft is still
          here and has not been overwritten.
        </p>
        <div class="flex gap-2">
          <button
            id="copy-draft-button"
            type="button"
            data-note-copy-draft
            class="rounded-xs border-2 border-base-content/25 px-2.5 py-1 font-mono text-[10px] font-bold uppercase transition hover:bg-base-content/8"
          >
            Copy my draft
          </button>
          <button
            id="reload-note-button"
            type="button"
            phx-click="reload_conflict"
            phx-target={@target}
            class="rounded-xs border-2 border-base-content/25 px-2.5 py-1 font-mono text-[10px] font-bold uppercase transition hover:bg-base-content/8"
          >
            Reload disk version
          </button>
          <button
            id="overwrite-note-button"
            type="button"
            phx-click="overwrite_conflict"
            phx-target={@target}
            data-claw-confirm="Overwrite the newer disk version with your draft?"
            class="rounded-xs border-2 border-warning/50 px-2.5 py-1 font-mono text-[10px] font-bold uppercase text-warning transition hover:bg-warning/10"
          >
            Overwrite
          </button>
        </div>
      </div>

      <p :if={@save_error} id="note-save-error" role="alert" class="font-mono text-xs text-error">
        {@save_error}
      </p>

      <.toolbar />

      <.form
        for={@editor_form}
        id="note-editor-form"
        data-note-editor
        phx-change="save_note"
        phx-submit="save_note"
        phx-target={@target}
        class="relative flex min-h-0 flex-1 flex-col"
      >
        <%!-- The model. Hidden and never focused: it exists to be serialized by
              `phx-change` and patched by the server, which is exactly what it did
              when it was also the visible editor. --%>
        <textarea
          id="note-editor"
          name="editor[body]"
          hidden
          tabindex="-1"
          aria-hidden="true"
          phx-debounce="700"
        >{Phoenix.HTML.Form.normalize_value("textarea", @editor_form[:body].value)}</textarea>

        <%!-- The view. Empty on the server on purpose — the hook renders every
              line from the textarea, so `phx-update="ignore"` is the contract and
              not a workaround. --%>
        <div
          id="note-surface"
          data-note-surface
          phx-update="ignore"
          contenteditable="true"
          role="textbox"
          aria-multiline="true"
          aria-label="Markdown note editor"
          spellcheck="true"
          class="ic-panel ic-note-surface min-h-72 w-full flex-1 overflow-y-auto p-6 focus:border-primary focus:outline-none"
        >
        </div>

        <p
          :if={String.trim(@body) == ""}
          id="note-placeholder"
          aria-hidden="true"
          class="pointer-events-none absolute left-6 top-6 font-mono text-sm text-base-content/30"
        >
          Start writing… ⌘S saves now.
        </p>
      </.form>

      <section :if={@backlinks != []} id="note-backlinks" class="shrink-0">
        <h3 class="font-mono text-[10px] font-bold uppercase tracking-wide text-base-content/45">
          Linked from
        </h3>
        <ul class="mt-1.5 flex flex-wrap gap-1.5">
          <li :for={note <- @backlinks}>
            <button
              type="button"
              phx-click="select_note"
              phx-value-path={note.path}
              phx-target={@target}
              class="flex items-center gap-1.5 rounded-xs border-2 border-base-content/15 px-2 py-1 text-left font-mono text-xs text-base-content/70 transition hover:border-primary hover:text-base-content"
            >
              <.icon name="hero-arrow-uturn-left" class="size-3 shrink-0 opacity-55" />
              <span class="truncate">{note.path}</span>
            </button>
          </li>
        </ul>
      </section>
    </section>
    """
  end

  defp status_text(:idle), do: "Choose a note"
  defp status_text(:unsaved), do: "Unsaved"
  defp status_text(:saved), do: "Saved"
  defp status_text(:conflict), do: "Conflict"
  defp status_text(:error), do: "Save failed"

  defp status_class(:conflict), do: "border-warning/40 bg-warning/10 text-warning"
  defp status_class(:error), do: "border-error/40 bg-error/10 text-error"
  defp status_class(:unsaved), do: "border-base-content/25 bg-base-content/5 text-base-content/70"
  defp status_class(_status), do: "border-success/30 bg-success/8 text-success"
end
