defmodule BusterClawWeb.SoundStudio.Sidebar do
  @moduledoc """
  The Sound Studio's left rail: every source the studio can open, grouped and
  foldable, plus the import dropzone at its foot.

  Extracted from `SoundStudioComponent` (CODE_QUALITY_REFACTOR Phase 3B, 08-03).
  Its two private helpers came with it because nothing else used them —
  `visible_items/2` is the fold, and `upload_error/1` turns Phoenix's upload
  error atoms into sentences a person can act on.

  **`max_entries` is passed in rather than read from a module attribute here.**
  The number belongs to the `allow_upload` that enforces it; a second copy in
  this module would be a message that could disagree with the limit it
  describes.
  """
  use BusterClawWeb, :html

  attr :myself, :any, required: true
  attr :groups, :list, required: true, doc: "source groups, in rail order"
  attr :selected, :any, required: true, doc: "the selected source id, or nil"
  attr :studio_collapsed, :any, required: true, doc: "MapSet/list of folded group keys"
  attr :missing_bundled, :any, required: true, doc: "bundled sounds not yet on disk"
  attr :note, :any, required: true, doc: "{kind, message} status line, or nil"
  attr :uploads, :map, required: true
  attr :max_entries, :integer, required: true, doc: "the allow_upload limit, for the error copy"

  @doc "The sidebar rail."
  def sidebar(assigns) do
    ~H"""
    <nav
      class="flex w-56 shrink-0 flex-col gap-3 overflow-y-auto border-r-2 border-base-content/20 pr-2"
      aria-label="Audio sources"
    >
      <div :for={group <- @groups} class="flex flex-col">
        <%!-- The whole heading is the hinge, so the hit target is the width of
              the sidebar rather than a caret. The count stays visible while
              folded — collapsed, it IS the summary: "Music 47". Handled by
              StatusLive (no phx-target), because the collapsed set lives
              there for the same reason the selection does. --%>
        <h3 class="sticky top-0 z-[1] bg-base-100">
          <button
            type="button"
            phx-click="toggle_studio_group"
            phx-value-key={group.key}
            aria-expanded={to_string(group.key not in @studio_collapsed)}
            class="flex w-full items-center gap-1 py-1 text-left font-mono text-[10px] font-bold uppercase tracking-widest text-base-content/40 transition hover:text-base-content/70"
          >
            <span class={[
              "inline-block transition-transform",
              group.key in @studio_collapsed && "-rotate-90"
            ]}>
              ▾
            </span>
            {group.label}
            <span class="text-base-content/25">{length(group.items)}</span>
          </button>
        </h3>

        <p
          :if={group.items == [] and group.key not in @studio_collapsed}
          class="px-1 py-1 font-mono text-[11px] text-base-content/30"
        >
          none yet
        </p>

        <%!-- `aria-current` is a token attribute, not a boolean one: HEEx
              renders `={true}` as a BARE attribute, which is invalid ARIA and
              announces nothing. The explicit string is the contract. --%>
        <button
          :for={item <- visible_items(group, @studio_collapsed)}
          type="button"
          phx-click="select_studio_source"
          phx-value-id={item.id}
          data-studio-source={item.id}
          data-source-label={item.label}
          data-deletable={deletable?(item) && "true"}
          data-sourceable={sourceable?(item) && "true"}
          aria-current={(@selected && @selected.id == item.id && "true") || nil}
          class={[
            "group flex flex-col items-start gap-0 border-l-2 px-2 py-1 text-left transition",
            if(@selected && @selected.id == item.id,
              do: "border-primary bg-primary/10",
              else: "border-transparent hover:border-base-content/30 hover:bg-base-content/5"
            )
          ]}
        >
          <span class="w-full truncate text-sm text-base-content">{item.label}</span>
          <span :if={item.sub} class="w-full truncate font-mono text-[10px] text-base-content/40">
            {item.sub}
          </span>
        </button>
      </div>

      <%!-- The ways in moved up to the tab bar (`toolbar/1`); what remains
            pinned here is the import machinery and its feedback. The file
            input must stay RENDERED for LiveView uploads to work, so it is
            hidden rather than removed — the toolbar's Import button clicks
            it by selector. No phx-submit: auto_upload consumes each file as
            it completes. --%>
      <form
        id="studio-import"
        phx-change="validate_import"
        phx-target={@myself}
        class="sticky bottom-0 flex flex-col gap-1.5 border-t-2 border-base-content/20 bg-base-100/80 pt-2 backdrop-blur"
      >
        <.live_file_input upload={@uploads.import} class="hidden" />

        <p class="font-mono text-[10px] leading-tight text-base-content/40">
          Imports land in <code>studio/</code> in your workspace — you can also
          drop files there in Finder.
        </p>

        <%!-- Offered, never automatic: SOUND_ROADMAP forbids seeding the
              workspace at boot, because a copy that reappears is how "delete
              that sound" becomes a bug report. The operator asking is a
              different act from the app deciding. --%>
        <button
          :if={@missing_bundled > 0}
          type="button"
          phx-click="install_bundled"
          phx-target={@myself}
          class="btn btn-ghost btn-xs w-full justify-start font-mono text-[10px] uppercase"
          title="Copy the built-in chimes into your sounds/ folder so you can edit them"
        >
          ↓ Copy {@missing_bundled} built-in to sounds/
        </button>

        <div :for={entry <- @uploads.import.entries} class="flex items-center gap-1.5">
          <span class="min-w-0 flex-1 truncate font-mono text-[10px] text-base-content/60">
            {entry.client_name}
          </span>
          <progress class="progress progress-primary w-10" value={entry.progress} max="100">
          </progress>
          <button
            type="button"
            phx-click="cancel_import"
            phx-value-ref={entry.ref}
            phx-target={@myself}
            class="font-mono text-[10px] text-base-content/40 hover:text-error"
            aria-label={"Cancel #{entry.client_name}"}
          >
            ✕
          </button>
        </div>

        <p :for={err <- upload_errors(@uploads.import)} class="font-mono text-[10px] text-error">
          {upload_error(err, @max_entries)}
        </p>

        <p
          :for={
            {entry, err} <-
              Enum.flat_map(@uploads.import.entries, fn e ->
                Enum.map(upload_errors(@uploads.import, e), &{e, &1})
              end)
          }
          class="font-mono text-[10px] text-error"
        >
          {entry.client_name}: {upload_error(err, @max_entries)}
        </p>

        <p
          :if={@note}
          class={[
            "font-mono text-[10px]",
            elem(@note, 0) == :error && "text-error",
            elem(@note, 0) == :info && "text-base-content/60"
          ]}
        >
          {elem(@note, 1)}
        </p>
      </form>
    </nav>
    """
  end

  # A folded group renders no items — the fold IS the filter, so nothing
  # downstream has to know about collapsed state.
  defp visible_items(group, collapsed) do
    if group.key in collapsed, do: [], else: group.items
  end

  # A real file on disk has facts worth showing and can become a clip. An
  # arrangement is neither — it is a list of references to these — and the music
  # library manager is not a mix at all.
  defp sourceable?(%{path: path}) when is_binary(path), do: true
  defp sourceable?(_item), do: false

  # Only the workspace layer is ever removable: a bundled sound has no file of
  # ours to delete, so offering it would be a menu item that fails.
  defp deletable?(%{kind: :import}), do: true
  defp deletable?(%{kind: :mix}), do: true
  defp deletable?(%{kind: :music}), do: true
  defp deletable?(%{kind: :sound, sub: "yours"}), do: true
  defp deletable?(_item), do: false

  # Phoenix hands back atoms; a person needs a sentence and a next move.
  defp upload_error(:too_large, _max), do: "That file is larger than 100 MB."
  defp upload_error(:not_accepted, _max), do: "Audio files only."
  defp upload_error(:too_many_files, max), do: "#{max} files at a time, maximum."
  defp upload_error(_other, _max), do: "Upload failed."
end
