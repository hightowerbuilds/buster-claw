defmodule BusterClawWeb.Notes.Toolbar do
  @moduledoc """
  The Notes formatting toolbar.

  ## It never reaches the server

  Every button carries `data-note-cmd` and nothing else — no `phx-click`, no
  `phx-target`. The `NoteEditor` hook handles the click, runs the matching
  transform from `assets/js/lib/note_commands.js` against the Markdown string,
  and writes the result back through the same path a keystroke takes.

  That is deliberate. Formatting is a text edit like any other, and routing it
  through the server would put a round-trip between pressing Bold and seeing
  bold — on a surface whose whole point is that it responds like a word
  processor. The save that follows is the ordinary debounced one.

  It also means **this module renders no state**. Which buttons look pressed is
  decided in the browser from the caret's position (`activeCommands/2`) and
  applied as a `data-active` attribute; the server does not know and does not
  need to.

  ## The list lives in two languages, so a test holds them together

  `commands/0` here and `NOTE_COMMANDS` there must name the same set: a button
  whose `data-note-cmd` has no transform is a dead button, and a transform with
  no button is unreachable. Neither shows up as a failure anywhere else —
  `render_hook/3` never loads the JS. `NotesToolbarLockstepTest` is what makes
  that a build failure instead of a bug report.

  ## Why `mousedown` matters more than `click`

  Pressing a toolbar button would ordinarily move focus out of the
  contenteditable and collapse the selection — so Bold would arrive with nothing
  selected. The hook cancels `mousedown` on these buttons for exactly that
  reason. It is the one piece of this component's behaviour that lives somewhere
  else, and it is why the buttons need no `tabindex` games here.
  """
  use BusterClawWeb, :html

  # Groups are visual only; the lockstep test flattens them. Order within a group
  # is the order a hand reaches for them, not the order they were built.
  @groups [
    [
      %{cmd: "h1", label: "Heading 1", text: "H1"},
      %{cmd: "h2", label: "Heading 2", text: "H2"},
      %{cmd: "h3", label: "Heading 3", text: "H3"}
    ],
    [
      %{cmd: "bold", label: "Bold", text: "B", class: "font-black"},
      %{cmd: "italic", label: "Italic", text: "I", class: "italic font-serif"},
      %{cmd: "strike", label: "Strikethrough", text: "S", class: "line-through"},
      %{cmd: "code", label: "Inline code", icon: "hero-code-bracket"}
    ],
    [
      %{cmd: "link", label: "Link", icon: "hero-link"}
    ],
    [
      %{cmd: "bullet", label: "Bulleted list", icon: "hero-list-bullet"},
      %{cmd: "ordered", label: "Numbered list", icon: "hero-numbered-list"},
      %{cmd: "task", label: "Task", icon: "hero-check-circle"}
    ],
    [
      %{cmd: "quote", label: "Quote", icon: "hero-chat-bubble-bottom-center-text"},
      %{cmd: "fence", label: "Code block", icon: "hero-code-bracket-square"},
      %{cmd: "hr", label: "Divider", icon: "hero-minus"}
    ]
  ]

  # The chords the hook claims, shown in the tooltip so they are discoverable
  # without a manual. Only these three: ⌘B/⌘I/⌘K are universal, and inventing a
  # chord for "numbered list" is how a shortcut sheet nobody reads gets written.
  @chords %{"bold" => "⌘B", "italic" => "⌘I", "link" => "⌘K"}

  @doc "Every command the toolbar offers, flattened. Read by the lockstep test."
  def commands, do: Enum.flat_map(@groups, & &1)

  @doc "The Notes formatting toolbar."
  def toolbar(assigns) do
    assigns = assign(assigns, :groups, @groups)

    ~H"""
    <div
      id="note-toolbar"
      role="toolbar"
      aria-label="Formatting"
      aria-controls="note-surface"
      class="flex flex-wrap items-center gap-1 border-b-2 border-base-content/15 pb-2"
    >
      <div :for={{group, index} <- Enum.with_index(@groups)} class="flex items-center gap-0.5">
        <span
          :if={index > 0}
          aria-hidden="true"
          class="mx-1 h-4 w-px shrink-0 bg-base-content/15"
        >
        </span>
        <button
          :for={command <- group}
          id={"note-cmd-#{command.cmd}"}
          type="button"
          data-note-cmd={command.cmd}
          aria-label={label_for(command)}
          aria-pressed="false"
          title={label_for(command)}
          class={[
            "flex size-7 items-center justify-center rounded-xs border-2 border-transparent",
            "font-mono text-[11px] font-bold uppercase text-base-content/65 transition",
            "hover:border-base-content/25 hover:text-base-content",
            "data-[active]:border-primary data-[active]:text-primary",
            Map.get(command, :class)
          ]}
        >
          <.icon :if={command[:icon]} name={command.icon} class="size-4" />
          <span :if={command[:text]}>{command.text}</span>
        </button>
      </div>
    </div>
    """
  end

  defp label_for(%{cmd: cmd, label: label}) do
    case Map.fetch(@chords, cmd) do
      {:ok, chord} -> "#{label} (#{chord})"
      :error -> label
    end
  end
end
