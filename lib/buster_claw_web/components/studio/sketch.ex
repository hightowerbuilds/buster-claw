defmodule BusterClawWeb.Studio.Sketch do
  @moduledoc """
  The Sketch Pad — a canvas you can draw on, and nothing else yet.

  ## Deliberately the smallest thing in the Studio

  Mix and Voice Library each arrived behind a roadmap with measured constraints.
  This one is meant to start by *existing*: a canvas, five colours, three brush
  sizes, an eraser, and clear. No saving, no layers, no undo, no export.

  That is a scoping decision rather than an unfinished one, and it is written
  down because this repo has a standing rule about the difference — a surface
  that honestly says what it is beats one with dead knobs on it. **There is no
  Save button, because there is nowhere to save to yet.** When there is, it will
  be a `sketch_*` command and a workspace path, and the argument for where those
  live belongs in a roadmap rather than in a button somebody added because the
  toolbar looked empty.

  ## The browser owns the drawing

  Every pixel lives in the canvas element, managed by the `SketchPad` hook.
  Nothing about a stroke round-trips to the server, and the element carries
  `phx-update="ignore"` so LiveView never re-renders it out from under the hook.

  This is the same rule the Notes editor arrived at after two failed designs:
  **do not build a parallel model beside the DOM.** A sketch is pixels; the
  server has no opinion about pixels and should not be sent them sixty times a
  second to prove it.

  The cost, stated rather than discovered later: **a reload loses the drawing.**
  That follows directly from the choice above and is the honest trade for a
  first version — the alternative is persistence, which is the next thing this
  needs and is a bigger decision than a canvas.
  """
  use BusterClawWeb, :html

  # The five-slot palette is deliberately NOT the app's validated series palette
  # (recorded in `archive/08-08-26-scene3d-roadmap.md`). That one exists so
  # adjacent *data series* stay distinguishable under colour-vision deficiency;
  # these are drawing colours, chosen to read on the Industrial ground. Reaching
  # for the series palette here would put a validated artifact to a use it was
  # never measured for, which is how a guarantee quietly stops being one.
  @colors ~w(#F4F1EA #FF4D1C #1C9BFF #2FD068 #121212)

  # Three sizes rather than a slider: a slider implies precision this has no way
  # to honour, and three is enough to tell a line from a fill.
  @sizes [2, 6, 16]

  def sketch(assigns) do
    assigns = assign(assigns, colors: @colors, sizes: @sizes)

    ~H"""
    <section
      id="studio-sketch"
      data-studio-tab="sketch"
      class="ic-panel flex min-h-0 flex-1 flex-col overflow-hidden"
    >
      <header class="flex flex-wrap items-center gap-4 border-b-2 border-base-content/20 px-4 py-2">
        <div class="flex items-center gap-1.5">
          <span class="ic-eyebrow">Colour</span>
          <button
            :for={{c, i} <- Enum.with_index(@colors)}
            type="button"
            data-sketch-color={c}
            aria-label={"Colour #{i + 1}"}
            style={"background-color: #{c}"}
            class={[
              "size-6 rounded-xs border-2 transition",
              if(i == 0,
                do: "border-primary",
                else: "border-base-content/25 hover:border-base-content/60"
              )
            ]}
          >
          </button>
        </div>

        <div class="flex items-center gap-1.5">
          <span class="ic-eyebrow">Size</span>
          <button
            :for={{s, i} <- Enum.with_index(@sizes)}
            type="button"
            data-sketch-size={s}
            aria-label={"Brush size #{s}"}
            class={[
              "grid size-6 place-items-center rounded-xs border-2 transition",
              if(i == 0,
                do: "border-primary text-primary",
                else: "border-base-content/25 text-base-content/60 hover:border-base-content/60"
              )
            ]}
          >
            <span class="rounded-full bg-current" style={"width:#{s}px;height:#{s}px"}></span>
          </button>
        </div>

        <div class="ml-auto flex items-center gap-2">
          <button
            type="button"
            data-sketch-eraser
            class="rounded-xs border-2 border-base-content/25 px-2.5 py-1 font-mono text-[0.66rem] uppercase tracking-wider text-base-content/70 transition hover:border-base-content/60"
          >
            Eraser
          </button>
          <%!-- Clear is the one destructive control here and it takes the house
                confirm, unlike the dock's Stand down: this one has no undo and
                nothing to restore from, which is exactly when asking is right. --%>
          <button
            type="button"
            data-sketch-clear
            data-claw-confirm="Clear the sketch? There is no undo yet."
            class="rounded-xs border-2 border-primary/50 px-2.5 py-1 font-mono text-[0.66rem] uppercase tracking-wider text-primary transition hover:bg-primary hover:text-primary-content"
          >
            Clear
          </button>
        </div>
      </header>

      <%!-- `phx-update="ignore"` is load-bearing: the hook owns every pixel in
            here and a LiveView re-render would wipe the drawing. The wrapper is
            what the hook measures, so the canvas can be sized in device pixels
            while CSS lays it out. --%>
      <div
        id="studio-sketch-surface"
        phx-hook="SketchPad"
        phx-update="ignore"
        class="relative min-h-0 flex-1 bg-base-200"
      >
        <canvas data-sketch-canvas class="block size-full touch-none"></canvas>
      </div>

      <footer class="border-t-2 border-base-content/20 px-4 py-1.5">
        <p class="font-mono text-[0.62rem] uppercase tracking-wider text-base-content/45">
          Experimental · nothing is saved yet, and a reload clears the page
        </p>
      </footer>
    </section>
    """
  end
end
