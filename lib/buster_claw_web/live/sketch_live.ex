defmodule BusterClawWeb.SketchLive do
  @moduledoc """
  The Sketch Pad, on its own route.

  ## Why this exists rather than a smaller edit to `StudioLive`

  The Sketch Pad shared `/studio` with the Studio's other two sub-tabs — Mix and
  the Voice Library — and the Studio is being spun out into its own project. The
  dock tab had to stop saying "Studio", but the drawing surface is finished
  (`SKETCH_ROADMAP` Phases 0–4) and had no other door.

  `StudioLive` is 300-odd lines of Mix and Voice state: selection, trims, clip
  data, undo/redo, a recorder, and around thirty `handle_event` clauses, all of
  it hoisted up from components that could not hold it. Reaching into that to
  leave only the sketch would be an unpicking, and an unpicking is the wrong
  thing to attempt on a surface someone is using right now.

  So this is a new door rather than a renovation, and it is small because
  **`SketchComponent` needs nothing from its parent.** It takes no assigns, it
  mounts itself, and it owns all eighteen of its own events — the drawing lives
  on disk rather than in a parent's assign, which is exactly what let it survive
  being discarded on a sub-tab switch. That property, written for a different
  reason, is why this file is thirty lines instead of three hundred.

  `StudioLive` and its panel are now unreachable. They are deliberately left in
  place for the spin-off to take, rather than deleted tonight alongside a live
  UI change.
  """
  use BusterClawWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Sketch")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket}>
      <div class="flex min-h-0 flex-1 flex-col gap-2">
        <h1 class="font-display text-2xl font-black uppercase tracking-tight">Sketch</h1>

        <div class="flex min-h-0 flex-1 flex-col">
          <.live_component module={BusterClawWeb.SketchComponent} id="sketch-pad" />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
