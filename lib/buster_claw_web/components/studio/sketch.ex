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

  alias BusterClaw.Sketch.Element

  # Drawing colours, chosen to read on the Industrial ground. Deliberately NOT
  # the app's validated series palette (`archive/08-08-26-scene3d-roadmap.md`):
  # that one exists so adjacent DATA SERIES stay distinguishable under
  # colour-vision deficiency, and borrowing it here would put a measured artifact
  # to a use it was never measured for.
  @colors ~w(#F4F1EA #FF4D1C #1C9BFF #2FD068 #121212)

  # Three sizes rather than a slider: a slider implies precision this has no way
  # to honour, and three is enough to tell a line from a fill.
  @widths [2, 6, 16]

  # The label size the operator gets when they pick up the text tool.
  # Deliberately not `hd(Element.text_sizes())`: `Element`'s own default is the
  # smallest because a model that omits `size` should get the quietest thing it
  # could have meant, whereas someone who just reached for the tool wants a
  # label they can read. Asserted to be one of the offered sizes in the tests —
  # a number here that the toolbar cannot press would leave no button lit.
  @default_text_size 18

  def colors, do: @colors
  def widths, do: @widths
  def default_color, do: hd(@colors)
  def default_width, do: hd(@widths)
  def text_sizes, do: Element.text_sizes()
  def default_text_size, do: @default_text_size

  # Colour belongs to the pen AND to the label, so picking one may not silently
  # put the text tool down — but it must still put the eraser down. One list,
  # read by the toolbar's pressed state and by the component's `color` event, so
  # the two cannot disagree about what "a colour is in use" means.
  @colored_tools ~w(draw text)a
  def colored_tools, do: @colored_tools

  attr :target, :any, required: true
  attr :tool, :atom, required: true
  attr :color, :string, required: true
  attr :width, :integer, required: true
  attr :selected, :string, default: nil
  attr :undoable, :boolean, default: false
  attr :text_size, :integer, default: @default_text_size

  def toolbar(assigns) do
    assigns =
      assign(assigns, colors: @colors, widths: @widths, text_sizes: Element.text_sizes())

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
          data-active={(@tool in colored_tools() and c == @color) || nil}
          aria-pressed={to_string(@tool in colored_tools() and c == @color)}
          aria-label={"Colour #{i + 1}"}
          style={"background-color: #{c}"}
          class="size-6 rounded-xs border-2 border-base-content/25 transition hover:border-base-content/60 data-[active]:border-primary"
        >
        </button>
      </div>

      <%!-- Hidden while the text tool is up, because the label sizes take its
            place there and a toolbar showing two different "Size" groups makes
            you read both to find out which one you are about to change. --%>
      <div :if={@tool != :text} class="flex items-center gap-1.5">
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
        <.tool_button target={@target} tool={:text} active={@tool} label="Text" />
        <.tool_button target={@target} tool={:erase} active={@tool} label="Erase" />
        <.tool_button target={@target} tool={:select} active={@tool} label="Select" />
      </div>

      <%!-- Type here, then click the canvas to place it.

            This is the whole text input mechanism, and it is a deliberate floor
            rather than a first step towards an in-canvas editor. An editor on
            the surface means a foreign object with its own caret, its own
            selection and its own focus lifecycle, sitting inside a subtree
            LiveView re-renders on every commit — and this repo has already paid
            for two editors that shipped green and were unusable (Notes). The
            rule that worked there was "the browser owns editing", and a plain
            input is the smallest thing that obeys it.

            So the field is NOT a server assign. `phx-update="ignore"` and no
            `value`: what is in the box belongs to the browser until the click
            that places it, at which point the hook reads it and pushes it once
            — the same split the in-flight stroke already uses, and the reason
            there is no draft to round-trip on every keystroke. --%>
      <div :if={@tool == :text} class="flex items-center gap-1.5">
        <span class="ic-eyebrow">Label</span>
        <div id="studio-sketch-text-draft" phx-update="ignore">
          <input
            type="text"
            data-sketch-text
            maxlength="200"
            placeholder="Type, then click to place"
            aria-label="Label text"
            class={[
              "w-52 rounded-xs border-2 border-base-content/25 bg-base-100 px-2 py-1",
              "font-mono text-[0.7rem] text-base-content",
              "placeholder:text-base-content/35 focus:border-primary focus:outline-none"
            ]}
          />
        </div>
        <button
          :for={s <- @text_sizes}
          type="button"
          phx-click="text_size"
          phx-value-size={s}
          phx-target={@target}
          data-sketch-text-size={s}
          data-active={s == @text_size || nil}
          aria-pressed={to_string(s == @text_size)}
          aria-label={"Label size #{s}"}
          class={[
            button_class(),
            "data-[active]:border-primary data-[active]:text-primary"
          ]}
        >
          {s}
        </button>
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
  attr :model_count, :integer, default: 0
  attr :name, :string, required: true

  def status(assigns) do
    ~H"""
    <footer class="flex items-center gap-3 border-t-2 border-base-content/20 px-4 py-1.5">
      <p class="font-mono text-[0.62rem] uppercase tracking-wider text-base-content/45">
        {@name}.json · {@count} {ngettext("mark", "marks", @count)} · saved as you draw
      </p>
      <%!-- The legend for D7's tick. A marker nobody can name is a smudge, and
            the count is also the only place the boundary D6 enforces is stated
            in words: these are the ones the model may take back. Absent when
            the model has drawn nothing, so a solo sketch says nothing about a
            collaborator who is not there. --%>
      <p
        :if={@model_count > 0}
        class="flex items-center gap-1.5 font-mono text-[0.62rem] uppercase tracking-wider text-primary/80"
      >
        <span class="inline-block size-1.5 bg-primary" aria-hidden="true"></span>
        {@model_count} by the model
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
