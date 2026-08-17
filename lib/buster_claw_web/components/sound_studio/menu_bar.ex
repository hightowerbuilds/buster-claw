defmodule BusterClawWeb.SoundStudio.MenuBar do
  @moduledoc """
  The Mix tab's menu bar — a desktop-app file bar across the top of the tracks.

  Replaced the sidebar on 08-16. The sidebar was a permanent column holding the
  source catalog, the import form and the fold state; the tracks got what was
  left. **Arranging is the activity this tab exists for, and it was the thing
  with the least room.** Menus cost width only while open.

  ## Where each control went, because nothing was allowed to be orphaned

  | Was | Now |
  |---|---|
  | Sidebar source list | **Open** (mixes) and **Material** (everything else) |
  | Sidebar import form + drop zone | **File → Import audio**, and the status strip below the bar |
  | Sidebar `install_bundled` | **File → Restore built-in sounds** |
  | Sidebar group folding | **deleted** — a submenu has nothing to fold |
  | Music library manager | **deleted 08-16** — see below |
  | Tab-bar `New mix` / `Import` | **File**, so one surface owns the verbs |

  ## There is no Library menu, and that was a product decision

  It held two rows. `Manage music library` opened `MusicComponent` — upload,
  delete, queue, play-all — and that whole surface was deleted on 08-16: the
  Studio is for making things, and maintaining a collection is not making
  something. `Restore built-in sounds` was never music at all (it copies bundled
  *chimes* into the workspace), so it moved to File and the menu went.

  **Music itself did not go.** Tracks are still in `Material` as clip sources,
  because chopping a song into a mix IS the creative work this tab is for. The
  dock player is untouched. What went is the Studio as a place you *administer*
  audio rather than cut it.

  ## Render and Delete are NOT here, and that is the interesting omission

  Both were in the File menu for about an hour. They came out because the
  arranger's header already has them, sitting beside the mix they act on — and a
  second door to one action is precisely how this repo lost a clip's effect
  chain on 08-16, when paste and duplicate each had their own idea of what
  copying meant.

  A file bar wants an Export item and it is tempting to add one. The test to
  apply first: **is the existing control contextual?** Render and Delete only
  mean anything while a mix is open, and the arranger is where a mix is open.
  New, Open and Import are not contextual, which is why they belong up here.

  ## Two owners, and getting it wrong is silent

  Half of these events are the **component's** (`new_mix`, `render_mix`,
  `delete_mix`, `install_bundled`, the upload pair) and half are the
  **LiveView's** (`select_studio_source`, undo/redo, the clip verbs). A missing
  `phx-target` sends a component event to the LiveView, where it falls through
  to no clause and does nothing at all — no crash, no message. Every item below
  therefore states its owner rather than inheriting one, and `@myself` is passed
  in rather than assumed.

  ## Why `<details>` rather than a hook that owns the DOM

  Each menu is a `<details>`/`<summary>` pair, so opening and closing is the
  browser's job and every item stays a real `phx-click` LiveView sends. The hook
  (`StudioMenuBar`) does one thing — close menus on outside-click, Escape, or
  after a choice — and never writes markup. That keeps this the opposite of the
  note editor's two failed designs: **the server still owns the content.**

  A LiveView re-render drops the `open` attribute, which closes the menus. That
  is the behaviour you want after picking something, and it is why choosing an
  item needs no explicit close.

  ## The known limit, stated rather than discovered

  **A long list inside a dropdown is a menu you scroll for a minute.** The
  Material submenus cap their height and scroll, which is honest but not good at
  200 tracks. If the Music library gets big, the answer is a search field in the
  submenu (or a picker overlay), not a taller menu — and that is a real decision
  rather than a tweak, so it is written here instead of half-built.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Notifications.StudioMix
  alias BusterClawWeb.SoundStudio.Catalog

  attr :myself, :any, required: true, doc: "the component's target — see the two-owners note"
  attr :groups, :list, required: true
  attr :selected, :any, default: nil
  attr :mix, :any, default: nil
  attr :uploads, :any, required: true
  attr :note, :any, default: nil
  # A COUNT, not a list — `SoundStudioComponent` assigns
  # `length(Sound.missing_from_workspace())`. Typed `:integer` so the next
  # reader does not repeat the assumption that cost a crash here.
  attr :missing_bundled, :integer, default: 0
  attr :studio_undo, :list, default: []
  attr :studio_redo, :list, default: []
  attr :studio_clip, :any, default: nil
  attr :studio_clipboard, :any, default: nil

  def menu_bar(assigns) do
    assigns =
      assigns
      |> assign(:mixes, group_items(assigns.groups, "mix"))
      |> assign(:material, Catalog.addable_groups(assigns.groups))
      |> assign(:mix_open?, match?(%StudioMix{}, assigns.mix))

    ~H"""
    <div
      id="studio-menu-bar"
      phx-hook="StudioMenuBar"
      class="flex shrink-0 flex-col border-b-2 border-base-content/20"
    >
      <div role="menubar" class="flex flex-wrap items-stretch">
        <.menu id="studio-menu-file" label="File">
          <%!-- The one form in here. It stays a form because a mix needs a NAME,
                and a menu item that opens a modal to collect one is two clicks
                for a text field. --%>
          <form
            id="studio-new-mix"
            phx-submit="new_mix"
            phx-target={@myself}
            class="flex items-center gap-1 px-2 py-1.5"
          >
            <input
              type="text"
              name="name"
              placeholder="new mix name"
              autocomplete="off"
              aria-label="Name for the new mix"
              class="input input-bordered input-xs w-36 font-mono text-[11px]"
            />
            <button type="submit" class="btn btn-primary btn-xs font-mono uppercase">New</button>
          </form>

          <.sep />

          <.submenu label="Open" empty="No mixes yet">
            <.item
              :for={item <- @mixes}
              label={item.label}
              sub={item.sub}
              source={item}
              current={selected?(@selected, item)}
              click="select_studio_source"
              value={item.id}
            />
          </.submenu>

          <.sep />
          <%!-- `JS.dispatch` rather than a server round trip: the file picker
                must open inside the user's own click gesture or the browser
                refuses it. --%>
          <%!-- The hint is not decoration: the sidebar's drop zone used to say
                where a file lands, and dropping that would have made Import the
                one action in here whose result you cannot predict. --%>
          <.item
            label="Import audio…"
            hint="to studio/"
            click={JS.dispatch("click", to: "#studio-import input[type=file]")}
          />
          <%!-- Chimes, not music, which is why it survived the music library's
                deletion and moved here rather than going with it. A one-off
                workspace repair, and it retires itself once nothing is
                missing. --%>
          <.item
            :if={@missing_bundled > 0}
            label="Restore built-in sounds"
            hint={"#{@missing_bundled} missing"}
            click="install_bundled"
            target={@myself}
          />
        </.menu>

        <.menu id="studio-menu-edit" label="Edit">
          <.item label="Undo" click="studio_undo" disabled={@studio_undo == []} />
          <.item label="Redo" click="studio_redo" disabled={@studio_redo == []} />
          <.sep />
          <.item label="Copy clip" click="studio_copy" disabled={is_nil(@studio_clip)} />
          <.item label="Paste clip" click="studio_paste" disabled={is_nil(@studio_clipboard)} />
          <.item
            label="Remove clip"
            click="studio_delete_clip"
            disabled={is_nil(@studio_clip)}
            danger
          />
        </.menu>

        <.menu id="studio-menu-material" label="Material">
          <.submenu
            :for={group <- @material}
            label={group.label}
            empty={"No #{String.downcase(group.label)}"}
          >
            <.item
              :for={item <- group.items}
              label={item.label}
              sub={item.sub}
              source={item}
              current={selected?(@selected, item)}
              click="select_studio_source"
              value={item.id}
            />
          </.submenu>
        </.menu>
      </div>

      <%!-- The upload's machinery, which used to live in the sidebar. The input
            is hidden and opened by File → Import audio; everything else here is
            feedback and appears only when there is something to say. --%>
      <form
        id="studio-import"
        phx-change="validate_import"
        phx-submit="validate_import"
        phx-target={@myself}
        class="contents"
      >
        <.live_file_input upload={@uploads.import} class="hidden" />
      </form>

      <div
        :if={@note || @uploads.import.entries != []}
        class="flex flex-wrap items-center gap-3 border-t border-base-content/10 px-2 py-1"
      >
        <p :if={@note} class={["font-mono text-[11px]", note_class(@note)]}>{note_text(@note)}</p>

        <div :for={entry <- @uploads.import.entries} class="flex items-center gap-2">
          <span class="font-mono text-[11px] text-base-content/70">{entry.client_name}</span>
          <span class="font-mono text-[11px] tabular-nums text-primary">{entry.progress}%</span>
          <button
            type="button"
            phx-click="cancel_import"
            phx-value-ref={entry.ref}
            phx-target={@myself}
            aria-label={"Cancel importing #{entry.client_name}"}
            class="text-base-content/40 hover:text-primary"
          >
            ×
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  # One top-level menu. `details` gives click-to-open for free; the hook only
  # closes it. `list-none` kills the disclosure triangle without touching the
  # semantics screen readers get from the element.
  defp menu(assigns) do
    ~H"""
    <details id={@id} data-studio-menu class="relative">
      <summary
        role="menuitem"
        class="cursor-pointer list-none px-3 py-1.5 font-display text-xs font-bold uppercase tracking-wide text-base-content/70 transition marker:hidden hover:bg-base-content/10 hover:text-base-content"
      >
        {@label}
      </summary>
      <div
        role="menu"
        class="absolute left-0 top-full z-30 min-w-56 border-2 border-base-content/25 bg-base-100 py-1 shadow-lg"
      >
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  attr :label, :string, required: true
  attr :empty, :string, default: "Nothing here"
  slot :inner_block, required: true

  # A nested list. It opens on hover AND is a real `details`, so it works with a
  # pointer and with a keyboard. `max-h` + scroll is the honest handling of a
  # long library — see the moduledoc's note on why that is a limit rather than a
  # solution.
  defp submenu(assigns) do
    ~H"""
    <details class="group/sub">
      <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-3 py-1.5 font-mono text-[11px] text-base-content/80 marker:hidden hover:bg-base-content/10">
        {@label}
        <span aria-hidden="true" class="text-base-content/40">▸</span>
      </summary>
      <div class="max-h-64 overflow-y-auto border-l-2 border-base-content/15 pl-1">
        {render_slot(@inner_block)}
        <p class="hidden px-3 py-1.5 font-mono text-[11px] text-base-content/40 only:block">
          {@empty}
        </p>
      </div>
    </details>
    """
  end

  attr :label, :string, required: true
  attr :sub, :string, default: nil
  attr :hint, :string, default: nil
  attr :click, :any, required: true
  attr :value, :string, default: nil
  attr :target, :any, default: nil, doc: "nil means the LiveView owns this event"
  attr :current, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :danger, :boolean, default: false
  attr :confirm, :string, default: nil

  attr :source, :map,
    default: nil,
    doc: "the catalog item, when this row IS a source — carries the context menu"

  # `source` is the half of this component that is not about menus at all.
  #
  # The sidebar's rows were the right-click target for rename / delete / info /
  # new-audio (`Overlays.context_menu` finds them by `data-studio-source`), and
  # deleting the sidebar would have deleted those four verbs with it — silently,
  # because a context menu that never opens raises nothing. Porting the data
  # attributes onto the menu item keeps the hook working against the row that
  # replaced the row.
  defp item(assigns) do
    ~H"""
    <button
      type="button"
      role="menuitem"
      phx-click={@click}
      phx-value-id={@value}
      phx-target={@target}
      data-claw-confirm={@confirm}
      data-studio-source={@source && @source.id}
      data-source-label={@source && @source.label}
      data-deletable={@source && deletable?(@source) && "true"}
      data-sourceable={@source && sourceable?(@source) && "true"}
      disabled={@disabled}
      aria-current={(@current && "true") || nil}
      class={[
        "flex w-full items-center justify-between gap-3 px-3 py-1.5 text-left font-mono text-[11px] transition",
        "disabled:cursor-not-allowed disabled:text-base-content/25",
        @danger && "text-primary hover:bg-primary hover:text-primary-content",
        !@danger && "text-base-content/80 hover:bg-base-content/10 hover:text-base-content",
        @current && "font-bold text-primary"
      ]}
    >
      <span class="truncate">{@label}</span>
      <span :if={@sub || @hint} class="shrink-0 text-[10px] text-base-content/40">
        {@hint || @sub}
      </span>
    </button>
    """
  end

  defp sep(assigns) do
    ~H"""
    <div class="my-1 border-t border-base-content/15"></div>
    """
  end

  # `@selected` is the catalog ITEM, not its id — the sidebar compared
  # `@selected.id == item.id` and comparing against the struct is how a menu
  # highlights nothing at all.
  defp selected?(%{id: id}, %{id: id}), do: true
  defp selected?(_selected, _item), do: false

  defp sourceable?(%{path: path}) when is_binary(path), do: true
  defp sourceable?(_item), do: false

  # Only the workspace layer is ever removable: a bundled sound has no file of
  # ours to delete, so offering it would be a menu item that fails.
  defp deletable?(%{kind: :import}), do: true
  defp deletable?(%{kind: :mix}), do: true
  defp deletable?(%{kind: :music}), do: true
  defp deletable?(%{kind: :sound, sub: "yours"}), do: true
  defp deletable?(_item), do: false

  defp group_items(groups, key) do
    case Enum.find(groups, &(&1.key == key)) do
      %{items: items} -> items
      _ -> []
    end
  end

  defp note_text({_kind, text}), do: text
  defp note_text(text) when is_binary(text), do: text
  defp note_text(_other), do: nil

  defp note_class({:error, _text}), do: "text-primary"
  defp note_class(_other), do: "text-base-content/60"
end
