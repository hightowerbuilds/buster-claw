defmodule BusterClawWeb.Notes.Editor do
  @moduledoc """
  The Notes editor pane: title bar, move form, conflict banner, textarea, preview.

  Pure markup; every save decision is `NotesComponent`'s. The pane is also the
  `NoteEditor` hook's root, which is why the conflict banner lives inside it —
  "Copy my draft" reaches the textarea through the same hook that owns ⌘S.

  Below `xl` the preview is behind the toggle rather than beside the editor; the
  panes are one DOM at every width, and only classes change.
  """
  use BusterClawWeb, :html

  attr :target, :any, required: true, doc: "the owning LiveComponent's @myself"
  attr :selected, :string, default: nil
  attr :body, :string, required: true
  attr :save_status, :atom, required: true
  attr :save_error, :string, default: nil
  attr :renaming, :boolean, required: true
  attr :rename_form, :any, required: true
  attr :folder_options, :list, required: true
  attr :editor_form, :any, required: true
  attr :preview_open, :boolean, required: true
  attr :preview_html, :string, required: true
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
            <h2 class="truncate font-display text-lg font-black uppercase tracking-tight">
              {Path.basename(@selected)}
            </h2>
            <p class="truncate font-mono text-[10px] text-base-content/45">{@selected}</p>
          </div>
        </div>
        <div class="flex items-center gap-2">
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
          <button
            id="toggle-preview-button"
            type="button"
            phx-click="toggle_preview"
            phx-target={@target}
            aria-pressed={to_string(@preview_open)}
            class="rounded-xs border-2 border-base-content/25 px-2.5 py-1 font-mono text-[10px] font-bold uppercase transition hover:border-primary hover:text-primary xl:hidden"
          >
            {if @preview_open, do: "Write", else: "Preview"}
          </button>
          <button
            id="rename-note-button"
            type="button"
            phx-click="toggle_rename"
            phx-target={@target}
            aria-expanded={to_string(@renaming)}
            aria-label={"Rename or move #{@selected}"}
            class="rounded-xs border-2 border-base-content/25 p-1.5 text-base-content/70 transition hover:border-primary hover:text-primary"
          >
            <.icon name="hero-pencil" class="size-4" />
          </button>
          <button
            id="delete-note-button"
            type="button"
            phx-click="delete_note"
            phx-value-path={@selected}
            phx-target={@target}
            data-claw-confirm={"Permanently delete \"#{@selected}\"? This cannot be undone."}
            class="rounded-xs border-2 border-error/35 p-1.5 text-error transition hover:border-error hover:bg-error/10"
            aria-label={"Delete #{@selected}"}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
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
          <.input
            field={@rename_form[:title]}
            id="rename-note-title"
            type="text"
            label="Name"
            autocomplete="off"
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

      <div class="grid min-h-0 flex-1 gap-3 xl:grid-cols-2">
        <.form
          for={@editor_form}
          id="note-editor-form"
          data-note-editor
          phx-change="save_note"
          phx-submit="save_note"
          phx-target={@target}
          class={["flex min-h-0 flex-col", @preview_open && "hidden xl:flex"]}
        >
          <.input
            field={@editor_form[:body]}
            id="note-editor"
            type="textarea"
            phx-debounce="700"
            spellcheck="true"
            aria-label="Markdown note editor"
            placeholder="Start writing… Markdown supported. ⌘S saves now."
            class="ic-panel min-h-72 w-full flex-1 resize-none bg-transparent p-4 font-mono text-sm leading-relaxed text-base-content placeholder:text-base-content/30 focus:border-primary focus:outline-none"
          />
        </.form>

        <article
          id="note-preview"
          aria-label="Markdown preview"
          class={[
            "ic-panel prose prose-sm min-h-72 max-w-none overflow-y-auto p-4 dark:prose-invert",
            not @preview_open && "hidden xl:block"
          ]}
        >
          <p :if={String.trim(@body) == ""} class="font-mono text-xs text-base-content/40">
            Your rendered Markdown will appear here.
          </p>
          <%!-- Sanitized in `Markdown.to_html/1` before it ever reaches here; a
                note may be agent-authored or imported, so its HTML is never
                trusted. Wiki links arrive as `#note/…` fragments the NoteEditor
                hook intercepts — inert rather than a 404 if that hook is gone. --%>
          <div :if={String.trim(@body) != ""} data-note-links>{raw(@preview_html)}</div>

          <section :if={@backlinks != []} id="note-backlinks" class="not-prose mt-6">
            <h3 class="font-mono text-[10px] font-bold uppercase tracking-wide text-base-content/45">
              Linked from
            </h3>
            <ul class="mt-1.5 flex flex-col gap-1">
              <li :for={note <- @backlinks}>
                <button
                  type="button"
                  phx-click="select_note"
                  phx-value-path={note.path}
                  phx-target={@target}
                  class="flex w-full items-center gap-1.5 rounded-xs px-2 py-1 text-left font-mono text-xs text-base-content/70 transition hover:bg-base-content/7 hover:text-base-content"
                >
                  <.icon name="hero-arrow-uturn-left" class="size-3 shrink-0 opacity-55" />
                  <span class="truncate">{note.path}</span>
                </button>
              </li>
            </ul>
          </section>
        </article>
      </div>
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
