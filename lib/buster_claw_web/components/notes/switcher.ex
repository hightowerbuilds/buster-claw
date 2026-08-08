defmodule BusterClawWeb.Notes.Switcher do
  @moduledoc """
  The ⌘P note switcher: type, arrow, Enter.

  A combobox rather than a list of links, because it is driven from the keyboard
  first. The input keeps focus the whole time and owns `aria-activedescendant`;
  the highlighted row is a real `option` with `aria-selected`, so a screen reader
  announces the row the arrow keys moved to without focus ever leaving the field.

  Selection state lives in `NotesComponent` — the `NotesKeys` hook only says
  "up", "down", or "pick", which keeps the keyboard and the mouse pointing at
  exactly the same index.
  """
  use BusterClawWeb, :html

  attr :target, :any, required: true, doc: "the owning LiveComponent's @myself"
  attr :open, :boolean, required: true
  attr :form, :any, required: true
  attr :results, :list, required: true
  attr :total, :integer, required: true
  attr :index, :integer, required: true

  @doc "The ⌘P switcher overlay."
  def switcher(assigns) do
    ~H"""
    <div
      :if={@open}
      id="note-switcher"
      class="fixed inset-0 z-50 flex items-start justify-center bg-base-300/70 p-4 pt-[12vh]"
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-label="Jump to a note"
        class="ic-panel flex max-h-[60vh] w-full max-w-xl flex-col overflow-hidden"
      >
        <.form
          for={@form}
          id="note-switcher-form"
          phx-change="switcher_search"
          phx-target={@target}
          class="border-b-2 border-base-content/20 p-2"
        >
          <.input
            field={@form[:query]}
            id="note-switcher-input"
            type="text"
            phx-debounce="150"
            autocomplete="off"
            role="combobox"
            aria-expanded="true"
            aria-controls="note-switcher-results"
            aria-activedescendant={active_id(@results, @index)}
            aria-label="Search notes by name or contents"
            placeholder="Jump to a note…"
            class="w-full rounded-xs border-2 border-base-content/20 bg-transparent px-3 py-2 font-mono text-sm text-base-content placeholder:text-base-content/35 focus:border-primary focus:outline-none"
          />
        </.form>

        <ul
          id="note-switcher-results"
          role="listbox"
          aria-label="Matching notes"
          class="min-h-0 flex-1 overflow-y-auto p-1.5"
        >
          <li
            :if={@results == []}
            class="px-3 py-6 text-center font-mono text-xs text-base-content/50"
          >
            No notes match.
          </li>
          <li
            :for={{note, row} <- Enum.with_index(@results)}
            id={"switcher-#{note.id}"}
            role="option"
            aria-selected={to_string(row == @index)}
          >
            <button
              type="button"
              phx-click="switcher_pick"
              phx-value-path={note.path}
              phx-target={@target}
              class={[
                "flex w-full flex-col gap-0.5 rounded-xs px-2.5 py-2 text-left transition",
                if(row == @index,
                  do: "bg-primary/15 text-primary",
                  else: "text-base-content/75 hover:bg-base-content/7"
                )
              ]}
            >
              <span class="truncate font-mono text-xs font-bold">{note.title}</span>
              <span class="truncate font-mono text-[10px] text-base-content/45">{note.path}</span>
              <span
                :if={Map.get(note, :snippet)}
                class="truncate font-mono text-[10px] text-base-content/55"
              >
                {note.snippet}
              </span>
            </button>
          </li>
        </ul>

        <footer class="flex items-center justify-between border-t-2 border-base-content/20 px-3 py-1.5 font-mono text-[10px] uppercase tracking-wide text-base-content/45">
          <span>↑↓ move · ⏎ open · esc close</span>
          <%!-- The cap is stated, never silent: a switcher that quietly drops
                results teaches you the note is gone. --%>
          <span :if={@total > length(@results)}>
            {length(@results)} of {@total}
          </span>
        </footer>
      </div>
    </div>
    """
  end

  defp active_id(results, index) do
    case Enum.at(results, index) do
      %{id: id} -> "switcher-#{id}"
      _ -> nil
    end
  end
end
