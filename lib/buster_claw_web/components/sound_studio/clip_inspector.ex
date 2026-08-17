defmodule BusterClawWeb.SoundStudio.ClipInspector do
  @moduledoc """
  What can be done to the selected clip: remove it, and shape how it sounds.

  ## Why this exists as its own module

  Two reasons, and the second is the one that still holds.
  `SoundStudioComponent` was `FROZEN` in `check_file_sizes.sh` when this was
  built and could not gain a line, so a growing surface had to live beside it.
  That freeze ended 08-16. What has not changed is that this is the
  **extension point**: every effect the Studio ever grows renders here
  without this file changing, because it renders `Studio.Effects.catalog/0`.

  Adding an effect is a catalog entry and an `apply_one/2` clause. It appears in
  this panel, saves into the mix, applies on render, and is audible in preview,
  with nothing here or in the arranger touched.

  ## Its events bubble to `StatusLive`, and that is where undo comes from

  Every control here is a plain `phx-click` with **no** `phx-target`, so the
  event reaches the parent LiveView rather than the component. That is not an
  oversight: `Studio.MixState.mutate_open_mix/2` is the one path every arrangement
  change goes through, and it is what records the previous state for ⌘Z. An
  effect added through the component would have been the first mix change in the
  Studio that could not be undone.

  ## Remove was always there. It just had no button.

  `StudioMix.remove_clip/2` and its handler have existed since the arranger did —
  reachable **only** by selecting a clip and pressing ⌫. That is a real feature
  that reads as a missing one, which is the same thing as missing for anybody who
  has not read `studio_keys.js`. The keyboard path still works and is still the
  faster one; this is the discoverable half.

  ## It is DOCKED, not stacked

  `sticky bottom-0` with its own background, because the arranger's wrapper is
  `flex-1 min-h-0` inside a scrolling column: it compresses below its content
  height and the tracks spill past it. A plain sibling therefore renders UNDER
  that spill — measured at 27px of overlap in the browser, with the clip's name
  sitting on top of the arranger's hint line.

  Docking fixes the overlap and is the better shape anyway: the inspector acts on
  the selected clip, so it should stay in view while the arrangement scrolls
  behind it.

  ## What the panel deliberately does not do

  **It does not redraw the clip's block when an effect changes its length.** A
  reverb tail and a speed change both alter how long a clip sounds, and the
  timeline keeps showing the source span it takes — see `Studio.Effects` on why
  chasing the rendered length makes the arranger jump under a dragging hand. The
  panel says so instead, next to the effects that cause it.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Notifications.Studio.Effects
  alias BusterClaw.Notifications.StudioMix
  alias BusterClawWeb.SoundStudio.Format

  attr :clip, :any, required: true, doc: "the selected clip map, or nil"
  attr :preview, :any, required: true, doc: "%{version: n} once a preview has been rendered"

  def inspector(assigns) do
    ~H"""
    <aside
      :if={@clip}
      id="studio-clip-inspector"
      phx-hook="VoiceAudition"
      class="sticky bottom-0 z-10 flex shrink-0 flex-col gap-2 border-t-2 border-base-content/25 bg-base-100/95 px-3 py-2 backdrop-blur"
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="font-mono text-[0.65rem] uppercase tracking-[0.2em] text-base-content/50">
          Clip
        </span>
        <span class="min-w-0 flex-1 truncate font-mono text-xs">{Format.clip_label(@clip)}</span>

        <%!-- Preview plays the clip THROUGH ITS CHAIN, rendered by the same code
              the mixdown uses. The transport's Play does not — it schedules raw
              sources — so this is the only way to hear an effect without
              rendering the whole mix. Versioned because the file keeps one name
              and the browser would otherwise replay the previous chain. --%>
        <button
          type="button"
          phx-click="studio_preview_clip"
          class="rounded border-2 border-base-content/30 px-2 py-0.5 font-mono text-[0.65rem] font-semibold uppercase tracking-wide transition hover:bg-base-200"
        >
          Render preview
        </button>

        <button
          :if={@preview}
          type="button"
          data-play
          data-source={@preview.name}
          data-version={@preview.version}
          class="rounded border-2 border-success/50 px-2 py-0.5 font-mono text-[0.65rem] font-bold uppercase tracking-wide text-success transition hover:bg-success/20"
        >
          ▶ Hear it
        </button>

        <button
          type="button"
          phx-click="studio_delete_clip"
          data-claw-confirm={"Remove #{Format.clip_label(@clip)} from the mix?"}
          title="Remove this clip from the mix (⌫)"
          class="rounded border-2 border-transparent px-2 py-0.5 font-mono text-[0.65rem] font-semibold uppercase tracking-wide text-base-content/40 transition hover:border-error/40 hover:text-error"
        >
          Remove
        </button>
      </div>

      <div class="flex flex-wrap items-center gap-1.5">
        <span class="font-mono text-[0.6rem] uppercase tracking-wide text-base-content/40">
          Add
        </span>

        <%!-- Rendered from the catalog, so a new effect appears here by existing. --%>
        <button
          :for={entry <- Effects.catalog()}
          type="button"
          phx-click="studio_add_effect"
          phx-value-type={entry.type}
          title={entry.blurb}
          class="rounded border-2 border-base-content/20 px-2 py-0.5 font-mono text-[0.65rem] transition hover:border-primary/60 hover:text-primary"
        >
          {entry.label}
        </button>
      </div>

      <p
        :if={StudioMix.chain(@clip) == []}
        class="font-mono text-[0.6rem] text-base-content/40"
      >
        No effects — this clip renders as its source.
      </p>

      <%!-- The chain, in order, because order is audible: reverb-then-reverse is
            a swell into the note and reverse-then-reverb is a note with a tail. --%>
      <ol class="flex flex-col gap-1">
        <li
          :for={{effect, position} <- Enum.with_index(StudioMix.chain(@clip))}
          class="flex flex-wrap items-center gap-2 rounded border border-base-content/15 px-2 py-1"
        >
          <span class="shrink-0 font-mono text-[0.6rem] text-base-content/35">{position + 1}</span>
          <span class="shrink-0 font-mono text-[0.7rem] font-bold">{effect_label(effect)}</span>

          <.param
            :for={{key, range} <- params(effect)}
            position={position}
            name={key}
            range={range}
            value={effect.params[key]}
          />

          <button
            type="button"
            phx-click="studio_remove_effect"
            phx-value-position={position}
            title="Remove this effect"
            class="ml-auto shrink-0 rounded px-1 font-mono text-[0.7rem] text-base-content/35 transition hover:text-error"
          >
            ✕
          </button>
        </li>
      </ol>

      <p
        :if={lengthens?(@clip)}
        class="font-mono text-[0.6rem] leading-relaxed text-base-content/45"
      >
        This chain changes how long the clip sounds. The block on the timeline is
        the source it takes, not where the sound stops — a tail carries past it,
        and the render sums the overlap.
      </p>
    </aside>
    """
  end

  attr :position, :integer, required: true
  attr :name, :string, required: true
  attr :range, :any, required: true
  attr :value, :any, required: true

  # `phx-change` on a form rather than the input, so the value arrives named.
  # A range input fires continuously while dragging; the debounce is what keeps
  # that from writing the mix file forty times a second.
  defp param(assigns) do
    {min, max, _default} = assigns.range
    assigns = assign(assigns, min: min, max: max)

    ~H"""
    <form phx-change="studio_set_effect_param" phx-submit="studio_set_effect_param">
      <input type="hidden" name="position" value={@position} />
      <input type="hidden" name="key" value={@name} />
      <label class="flex items-center gap-1">
        <span class="font-mono text-[0.6rem] text-base-content/50">{@name}</span>
        <input
          type="range"
          name="value"
          min={@min}
          max={@max}
          step="0.01"
          value={@value}
          phx-debounce="120"
          class="h-1 w-20 accent-primary"
        />
        <span class="w-8 font-mono text-[0.6rem] tabular-nums text-base-content/60">
          {:erlang.float_to_binary(@value * 1.0, decimals: 2)}
        </span>
      </label>
    </form>
    """
  end

  defp params(%{type: type}) do
    case Effects.entry(type) do
      nil -> []
      %{params: params} -> Enum.sort_by(params, fn {key, _range} -> key end)
    end
  end

  defp effect_label(%{type: type}) do
    case Effects.entry(type) do
      nil -> type
      %{label: label} -> label
    end
  end

  # Only these two change the rendered length today. Asked of the catalog rather
  # than hardcoded per clip so a future time-stretch says so by existing.
  defp lengthens?(clip) do
    Enum.any?(StudioMix.chain(clip), &(&1.type in ~w(reverb speed)))
  end
end
