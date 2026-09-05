defmodule BusterClawWeb.Vox.Chimes do
  @moduledoc """
  Vox2B's **What it says** panel: one editable line per notification routing key,
  and the button that speaks the whole set.

  Extracted from `BusterClawWeb.VoxComponent` on 09-05 to fund the render chip
  below. That is the file-size gate working rather than being worked around —
  `vox_component.ex` is FROZEN, so a new feature is paid for by taking a panel
  out instead of by raising a number. It is also the first cut of
  `VOX_TAB_ROADMAP` Phase 3, which wants a module per panel, and this one is the
  easiest to lift: it reads `@chimes`, `@engine` and two notes, and owns no state.

  ## The set is one job, not sixteen

  `Speak them` renders all sixteen lines in a single engine invocation, so there
  is one chip for the set rather than a spinner per row. That is not a UI
  shortcut — it is the shape of the work. One model load for sixteen lines
  against sixteen model loads was measured at roughly half the wall clock, and
  `VoxComponent.handle_event("chime-render-all", …)` carries the numbers.
  """
  use BusterClawWeb, :html

  alias BusterClawWeb.Vox.Progress

  @doc "The chime-lines panel. `since` is nil unless a set render is in flight."
  attr :chimes, :list, required: true
  attr :engine, :map, required: true
  attr :note, :string, default: nil
  attr :since, :integer, default: nil
  attr :target, :any, required: true

  def panel(assigns) do
    ~H"""
    <section class="ic-vox-section">
      <h3>What it says</h3>
      <p class="ic-vox-hint">
        One line per notification. Each is made once and kept, so nothing renders while a timer
        is going off.
      </p>

      <form phx-submit="chime-lines-save" phx-target={@target} class="flex flex-col gap-3">
        <div class="ic-vox-lines">
          <%!-- Three columns rather than sixteen flex rows that each decide
                their own width: at this density the labels not lining up is
                the first thing the eye catches.

                The per-row wrapper is `display: contents` so the three cells
                are the grid's items, not the wrapper. `:for` has to wrap SOME
                element, and the tempting one — `<template>` — is a trap: its
                contents are inert, so the rows would render invisible and the
                inputs would never submit, while every string assertion in the
                suite still passed because the markup is present in the HTML. --%>
          <div :for={row <- @chimes} class="ic-vox-line">
            <span class="font-mono text-[0.6875rem] uppercase tracking-wide text-base-content/55">
              {row.label}
            </span>
            <input
              type="text"
              name={"lines[#{row.key}]"}
              value={row.line}
              maxlength="120"
              class="input input-bordered input-xs min-w-0 text-sm"
            />
            <span class="w-4 text-primary">
              <.icon :if={row.installed?} name="hero-check" class="size-3.5" />
            </span>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <button type="submit" class="btn btn-primary btn-xs">Save lines</button>
          <button
            type="button"
            phx-click="chime-lines-reset"
            phx-target={@target}
            class="btn btn-ghost btn-xs"
          >
            Reset
          </button>
          <button
            type="button"
            phx-click="chime-render-all"
            phx-target={@target}
            disabled={not @engine.available? or @since != nil}
            class="btn btn-ghost btn-xs"
          >
            Speak them
          </button>

          <%!-- The chip REPLACES the note while the set is being made. Showing
                both would put a live clock beside the sentence that started it
                ("Making all 16 — one model load for the set"), which reads as two
                different claims about the same job. --%>
          <Progress.chip :if={@since} id="vox-chime-progress" since={@since} label="Making 16" />
          <span :if={is_nil(@since)} class="ic-vox-note">{@note}</span>
        </div>

        <p :if={not @engine.available?} class="ic-vox-note">
          Editing works without an engine — speaking them needs one.
        </p>
      </form>
    </section>
    """
  end
end
