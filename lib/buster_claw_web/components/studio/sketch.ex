defmodule BusterClawWeb.Studio.Sketch do
  @moduledoc """
  The Sketch Pad's toolbar and status line. State lives in
  `BusterClawWeb.SketchComponent`; the surface is `Studio.SketchSvg`.

  ## The toolbar is LiveView state now, not hook state

  In the first version the hook held the colour, the size and the eraser, and
  painted its own pressed styling. Phase 1 moved the document to the server, and
  splitting the toolbar across both layers would have left two places deciding
  what is active — which is the shape of the bug Phase 0 had just fixed. A click
  is rare enough that a round trip is free; a `pointermove` is not, which is why
  drawing is still the browser's (see `SketchComponent`).

  ## The eraser changed meaning, and had to

  It used to paint the panel's background colour, which is the only erase a
  bitmap allows. On a document that would create ground-coloured **elements** —
  marks that look erased, are still in the file, and would be read back to the
  model as strokes in Phase 2. It deletes now.
  """
  use BusterClawWeb, :html

  # Drawing colours, chosen to read on the Industrial ground. Deliberately NOT
  # the app's validated series palette (`archive/08-08-26-scene3d-roadmap.md`):
  # that one exists so adjacent DATA SERIES stay distinguishable under
  # colour-vision deficiency, and borrowing it here would put a measured artifact
  # to a use it was never measured for.
  @colors ~w(#F4F1EA #FF4D1C #1C9BFF #2FD068 #121212)

  # Three sizes rather than a slider: a slider implies precision this has no way
  # to honour, and three is enough to tell a line from a fill.
  @widths [2, 6, 16]

  def colors, do: @colors
  def widths, do: @widths
  def default_color, do: hd(@colors)
  def default_width, do: hd(@widths)

  attr :target, :any, required: true
  attr :tool, :atom, required: true
  attr :color, :string, required: true
  attr :width, :integer, required: true
  attr :selected, :string, default: nil
  attr :undoable, :boolean, default: false

  def toolbar(assigns) do
    assigns = assign(assigns, colors: @colors, widths: @widths)

    ~H"""
    <header class="flex flex-wrap items-center gap-4 border-b-2 border-base-content/20 px-4 py-2">
      <div class="flex items-center gap-1.5">
        <span class="ic-eyebrow">Colour</span>
        <%!-- Pressed styling lives behind `data-[active]:`, so the active look is
              one attribute rather than a set of classes something has to keep in
              step. Picking a colour also picks up the pen — see the component. --%>
        <button
          :for={{c, i} <- Enum.with_index(@colors)}
          type="button"
          phx-click="color"
          phx-value-color={c}
          phx-target={@target}
          data-sketch-color={c}
          data-active={(@tool == :draw and c == @color) || nil}
          aria-pressed={to_string(@tool == :draw and c == @color)}
          aria-label={"Colour #{i + 1}"}
          style={"background-color: #{c}"}
          class="size-6 rounded-xs border-2 border-base-content/25 transition hover:border-base-content/60 data-[active]:border-primary"
        >
        </button>
      </div>

      <div class="flex items-center gap-1.5">
        <span class="ic-eyebrow">Size</span>
        <button
          :for={w <- @widths}
          type="button"
          phx-click="width"
          phx-value-width={w}
          phx-target={@target}
          data-sketch-size={w}
          data-active={w == @width || nil}
          aria-pressed={to_string(w == @width)}
          aria-label={"Brush size #{w}"}
          class={[
            "grid size-6 place-items-center rounded-xs border-2 transition",
            "border-base-content/25 text-base-content/60 hover:border-base-content/60",
            "data-[active]:border-primary data-[active]:text-primary"
          ]}
        >
          <span class="rounded-full bg-current" style={"width:#{w}px;height:#{w}px"}></span>
        </button>
      </div>

      <div class="flex items-center gap-1.5">
        <span class="ic-eyebrow">Tool</span>
        <.tool_button target={@target} tool={:erase} active={@tool} label="Erase" />
        <.tool_button target={@target} tool={:select} active={@tool} label="Select" />
      </div>

      <div class="ml-auto flex items-center gap-2">
        <button
          :if={@selected}
          type="button"
          phx-click="delete_selected"
          phx-target={@target}
          class={[button_class(), "border-primary/50 text-primary"]}
        >
          Delete
        </button>
        <button
          type="button"
          phx-click="undo"
          phx-target={@target}
          disabled={not @undoable}
          class={[button_class(), "disabled:opacity-35"]}
        >
          Undo
        </button>
        <%!-- Clear keeps the house confirm even though undo now exists: undo is
              one step of many and this is all of them at once. --%>
        <button
          type="button"
          phx-click="clear"
          phx-target={@target}
          data-sketch-clear
          data-claw-confirm="Clear the whole sketch? Undo can bring it back."
          class={[
            button_class(),
            "border-primary/50 text-primary hover:bg-primary hover:text-primary-content"
          ]}
        >
          Clear
        </button>
      </div>
    </header>
    """
  end

  attr :notice, :string, default: nil
  attr :count, :integer, required: true
  attr :name, :string, required: true

  def status(assigns) do
    ~H"""
    <footer class="flex items-center gap-3 border-t-2 border-base-content/20 px-4 py-1.5">
      <p class="font-mono text-[0.62rem] uppercase tracking-wider text-base-content/45">
        {@name}.json · {@count} {ngettext("mark", "marks", @count)} · saved as you draw
      </p>
      <p :if={@notice} class="font-mono text-[0.62rem] text-primary">{@notice}</p>
    </footer>
    """
  end

  attr :target, :any, required: true
  attr :tool, :atom, required: true
  attr :active, :atom, required: true
  attr :label, :string, required: true

  defp tool_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="tool"
      phx-value-tool={@tool}
      phx-target={@target}
      data-sketch-tool={@tool}
      data-active={@tool == @active || nil}
      aria-pressed={to_string(@tool == @active)}
      class={[button_class(), "data-[active]:border-primary data-[active]:text-primary"]}
    >
      {@label}
    </button>
    """
  end

  defp button_class do
    "rounded-xs border-2 border-base-content/25 px-2.5 py-1 font-mono text-[0.66rem] " <>
      "uppercase tracking-wider text-base-content/70 transition hover:border-base-content/60"
  end
end
