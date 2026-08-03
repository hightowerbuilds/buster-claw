defmodule BusterClawWeb.SoundStudio.Arranger do
  @moduledoc """
  The multi-track arranger: toolbar, transport, ruler, track stack, and the
  clip blocks themselves.

  Extracted from `SoundStudioComponent` (CODE_QUALITY_REFACTOR Phase 3B, 08-03)
  — the last and largest block of a `render/1` that had reached 826 lines. It
  came out after the sidebar and the overlays because it is the most entangled:
  nine assigns, and the only one of the three that owns geometry.

  Everything it needs is now an `attr`, which is the point. Reading this
  module's attribute list tells you exactly what an arrangement is made of;
  reading it inside the old `render/1` told you nothing, because every assign
  in the Studio was in scope.

  ## The track palette

  Hazard orange stays first, joined by a signal blue and a green in the same
  saturation family. Three, cycling, for up to eight tracks — a DAW colors
  tracks so the eye can follow material across the arrangement, and two clips
  from the same track must read as siblings.

  The color hangs off the track's **label letter**, not its list position:
  positions renumber when a middle track is deleted, and a track that changed
  color because a NEIGHBOR died would break exactly the visual memory the
  palette exists to serve. Labels are assigned once at creation and never
  reused while the track lives, so A is always hazard, B always blue, C always
  green, D hazard again.

  Inline styles rather than Tailwind classes, deliberately: the clip blocks
  already carry `style=` for their geometry, so this adds no new CSP surface,
  and it spares the JIT-safelist dance that dynamic class names would need.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.SoundStudio.Catalog
  import BusterClawWeb.SoundStudio.Format

  alias BusterClaw.Notifications.StudioMix

  @track_palette ["#FF4D1C", "#1C9BFF", "#2FD068"]

  attr :myself, :any, required: true
  attr :mix, :any, required: true, doc: "the open StudioMix, or nil"
  attr :selected, :any, required: true
  attr :groups, :list, required: true, doc: "the source catalog, for clip URLs and the add menu"
  attr :note, :any, required: true
  attr :studio_clip, :any, required: true, doc: "the selected clip id"
  attr :studio_clipboard, :any, required: true
  attr :studio_undo, :list, required: true
  attr :studio_redo, :list, required: true

  @doc "The arranger surface. Renders nothing unless a mix is open."
  def arranger(assigns) do
    ~H"""
    <%!-- The arranger. Tracks sum, so a bed on one and hits on another are
          heard together — that is the whole reason tracks exist rather than
          one long row. --%>
    <%!-- The shortcut hook lives HERE, inside the arranger, so the chords
          exist only while an mix is open — nothing binds ⌘Z or ⌘C anywhere
          else in the app. It reads what is actionable off these two data
          attributes rather than guessing, so ⌘C over ordinary page text
          still does what the browser does. --%>
    <div
      :if={@selected && @selected.kind == :mix && @mix}
      id="studio-keys"
      phx-hook="StudioKeys"
      data-clip-selected={to_string(not is_nil(@studio_clip))}
      data-clipboard={to_string(not is_nil(@studio_clipboard))}
      class="flex min-h-0 flex-1 flex-col gap-3"
    >
      <header class="flex flex-wrap items-baseline justify-between gap-2">
        <div class="min-w-0">
          <h2 class="truncate text-lg font-bold tracking-tight">{@mix.name}</h2>
          <p class="font-mono text-xs text-base-content/50">
            {length(@mix.tracks)} {if length(@mix.tracks) == 1, do: "track", else: "tracks"} · {length(
              StudioMix.clips(@mix)
            )} clips · {ms(StudioMix.duration_ms(@mix))}
          </p>
        </div>
        <div class="flex shrink-0 items-center gap-1">
          <%!-- Undo and redo are buttons as well as shortcuts: a
                keyboard-only feature is an invisible one, and these also
                give the state (how deep the stack goes) somewhere to show. --%>
          <button
            type="button"
            phx-click="studio_undo"
            disabled={@studio_undo == []}
            class="btn btn-ghost btn-xs font-mono uppercase disabled:opacity-30"
            title="Undo (⌘Z)"
          >
            ↶ Undo
          </button>
          <button
            type="button"
            phx-click="studio_redo"
            disabled={@studio_redo == []}
            class="btn btn-ghost btn-xs font-mono uppercase disabled:opacity-30"
            title="Redo (⇧⌘Z)"
          >
            ↷ Redo
          </button>
          <%!-- The transport. Keyed by the open mix so switching
                remounts the hook — destroyed() closes the AudioContext,
                and a stale score can never keep sounding over a new
                arrangement. Play is instant and file-less; Render stays
                the bounce. --%>
          <button
            type="button"
            id={"studio-audition-#{:erlang.phash2(@mix.name)}"}
            phx-hook="StudioAudition"
            data-arranger={arranger_dom_id(@mix)}
            class="btn btn-ghost btn-xs font-mono uppercase"
            title="Hear the arrangement without rendering it"
          >
            ▶ Play
          </button>
          <button
            type="button"
            phx-click="render_mix"
            phx-target={@myself}
            class="btn btn-primary btn-xs font-mono uppercase"
          >
            Render
          </button>
          <button
            type="button"
            phx-click="delete_mix"
            phx-target={@myself}
            data-claw-confirm={"Delete the mix #{@mix.name}? The clips it uses are not touched."}
            class="btn btn-ghost btn-xs font-mono uppercase text-base-content/40 hover:text-error"
          >
            Delete
          </button>
        </div>
      </header>

      <%!-- Add a clip — at the TOP, because it is how a mix starts.
            Everything below it (ruler, tracks, clips) is the result of
            using it, and a control you need first should not be the last
            thing on the page. A plain form rather than drag-from-the-
            sidebar: the sidebar's job is selection, and one control that
            always works beats a gesture that only works from certain
            rows. --%>
      <form
        phx-submit="add_clip"
        phx-target={@myself}
        class="flex flex-wrap items-center gap-2 border-b-2 border-base-content/15 pb-3"
      >
        <label class="font-mono text-[10px] font-bold uppercase tracking-widest text-base-content/40">
          Add clip
        </label>
        <select
          name="source"
          aria-label="Clip source"
          class="select select-bordered select-xs min-w-0 flex-1 font-mono text-[11px]"
        >
          <optgroup :for={group <- addable_groups(@groups)} label={group.label}>
            <option :for={item <- group.items} value={item.id}>{item.label}</option>
          </optgroup>
        </select>
        <select
          name="track"
          aria-label="Destination track"
          class="select select-bordered select-xs font-mono text-[11px]"
        >
          <option :for={track <- @mix.tracks} value={track.id}>Track {track.label}</option>
        </select>
        <button type="submit" class="btn btn-primary btn-xs font-mono uppercase">
          Add
        </button>
      </form>

      <%!-- Ruler. Positions are computed server-side; the hook is told only
            the ruler's length, so the geometry lives in one language. The
            spacer matches the control clusters below — ticks must align
            with the clip REGIONS, which start after the clusters. --%>
      <div class="flex">
        <div class="w-28 shrink-0"></div>
        <div class="relative h-4 min-w-0 flex-1 border-b border-base-content/20">
          <span
            :for={tick <- StudioMix.ticks(StudioMix.view_ms(@mix))}
            style={"left: #{tick.pct}%"}
            class="absolute top-0 -translate-x-1/2 font-mono text-[9px] text-base-content/35"
          >
            {tick.label}
          </span>
        </div>
      </div>

      <%!-- The track stack. Each row is a left control cluster and a clip
            region — the Pro Tools shape, so per-track controls (delete
            now; mute and solo when they come) have a home that grows
            without covering the clips. [data-track] is ONLY the region:
            the drag hook divides pointer X by that rect's width, and a
            row-wide rect would land every drop early by a cluster. --%>
      <div
        id={arranger_dom_id(@mix)}
        phx-hook="TrackArrange"
        phx-target={@myself}
        data-view-ms={StudioMix.view_ms(@mix)}
        class="relative flex select-none flex-col gap-1"
      >
        <%!-- The playhead. Hidden until the transport runs; the hook owns
              its position outright and re-asserts every frame, so a patch
              that re-hides it mid-play loses within 16ms. --%>
        <div
          data-playhead
          class="pointer-events-none absolute z-10 hidden w-px bg-base-content/80"
        >
        </div>
        <div :for={track <- @mix.tracks} class="flex items-stretch">
          <div
            style={"border-left-color: #{track_color(track)}"}
            class="flex w-28 shrink-0 flex-col justify-between border-2 border-l-4 border-r-0 border-base-content/15 bg-base-content/[0.06] px-2 py-1"
          >
            <span
              style={"color: #{track_color(track)}"}
              class="truncate font-mono text-[10px] font-bold uppercase tracking-wider"
            >
              Track {track.label}
            </span>
            <div class="flex items-center justify-between gap-1.5">
              <div class="flex items-center gap-1">
                <%!-- The DAW pair. M fills neutral (silenced is an absence,
                      not an alarm); S fills the palette green — the one
                      hue that already means "this one sounds". aria-pressed
                      because these are toggles, not actions. --%>
                <button
                  type="button"
                  phx-click="toggle_mute"
                  phx-value-id={track.id}
                  phx-target={@myself}
                  aria-pressed={to_string(track.muted)}
                  aria-label={"Mute track #{track.label}"}
                  title={"Mute track #{track.label}"}
                  class={[
                    "h-4 w-4 border font-mono text-[9px] font-bold leading-none transition",
                    if(track.muted,
                      do: "border-base-content/60 bg-base-content/70 text-base-100",
                      else: "border-base-content/25 text-base-content/40 hover:border-base-content/50"
                    )
                  ]}
                >
                  M
                </button>
                <button
                  type="button"
                  phx-click="toggle_solo"
                  phx-value-id={track.id}
                  phx-target={@myself}
                  aria-pressed={to_string(track.soloed)}
                  aria-label={"Solo track #{track.label}"}
                  title={"Solo track #{track.label}"}
                  class={[
                    "h-4 w-4 border font-mono text-[9px] font-bold leading-none transition",
                    if(track.soloed,
                      do: "border-[#2FD068] bg-[#2FD068] text-base-100",
                      else: "border-base-content/25 text-base-content/40 hover:border-base-content/50"
                    )
                  ]}
                >
                  S
                </button>
              </div>

              <button
                :if={length(@mix.tracks) > 1}
                type="button"
                phx-click="remove_track"
                phx-value-id={track.id}
                phx-target={@myself}
                data-claw-confirm={
                  track.clips != [] &&
                    "Delete track #{track.label} and the #{length(track.clips)} clips on it?"
                }
                class="font-mono text-[10px] text-base-content/30 transition hover:text-error"
                aria-label={"Delete track #{track.label}"}
                title={"Delete track #{track.label}"}
              >
                ✕
              </button>
            </div>
          </div>

          <%!-- A silenced region dims: the arrangement always shows what
                the mix will contain, whether the silence came from this
                track's own M or from someone else's S. --%>
          <div
            data-track
            data-track-id={track.id}
            data-audible={to_string(StudioMix.audible?(@mix, track))}
            class={[
              "relative h-14 min-w-0 flex-1 border-2 border-base-content/15 bg-base-content/[0.03] data-[track-target]:border-primary/60",
              not StudioMix.audible?(@mix, track) && "opacity-40"
            ]}
          >
            <%!-- Fill and border come from the TRACK (siblings must read
                  as siblings); selection stays the hazard ring, one color
                  for "you are holding this" no matter what it is. The
                  8-digit hex suffixes are alpha: B3 ≈ 70%, 80 = 50%,
                  40 = 25%. --%>
            <div
              :for={clip <- track.clips}
              data-clip
              data-clip-id={clip.id}
              data-start-ms={clip.start_ms}
              data-src={clip_src(@groups, clip)}
              style={"left: #{StudioMix.position_pct(clip.start_ms, StudioMix.view_ms(@mix))}%; width: #{StudioMix.width_pct(clip.duration_ms, StudioMix.view_ms(@mix))}%; border-color: #{track_color(track)}B3; background-color: #{track_color(track)}#{if @studio_clip == clip.id, do: "80", else: "40"}"}
              class={[
                "absolute inset-y-2 cursor-grab overflow-hidden rounded-xs border px-1 active:cursor-grabbing",
                @studio_clip == clip.id && "ring-2 ring-primary"
              ]}
              title={clip_title(clip)}
            >
              <span class="pointer-events-none block truncate font-mono text-[9px] leading-4 text-base-content/80">
                {clip_label(clip)}
              </span>
            </div>
          </div>
        </div>

        <%!-- Where a new track appears is where the button sits. Disabled
              rather than hidden at the cap: a control that vanishes reads
              as a bug, one that explains itself reads as a limit. --%>
        <button
          type="button"
          phx-click="add_track"
          phx-target={@myself}
          disabled={length(@mix.tracks) >= StudioMix.max_tracks()}
          title={
            if length(@mix.tracks) >= StudioMix.max_tracks(),
              do: "An mix holds at most #{StudioMix.max_tracks()} tracks",
              else: "Add a track"
          }
          class="btn btn-ghost btn-xs w-28 justify-start font-mono uppercase disabled:opacity-30"
        >
          + Track
        </button>
      </div>

      <p class="font-mono text-[10px] text-base-content/40">
        Drag clips along a track or between tracks · click one to select it · <kbd>⌘C</kbd>/<kbd>⌘V</kbd> copy and paste ·
        <kbd>⌫</kbd>
        removes · <kbd>⌘Z</kbd>
        undoes
        <span :if={@studio_clipboard} class="text-primary">
          · copied: {@studio_clipboard.source |> String.split(":", parts: 2) |> List.last()}
        </span>
      </p>

      <p
        :if={@note}
        class={[
          "font-mono text-xs",
          elem(@note, 0) == :error && "text-error",
          elem(@note, 0) == :info && "text-base-content/60"
        ]}
      >
        {elem(@note, 1)}
      </p>
    </div>
    """
  end

  defp track_color(%{label: <<c>>}) when c in ?A..?Z do
    Enum.at(@track_palette, rem(c - ?A, length(@track_palette)))
  end

  # A hand-edited file can carry any label ("?" is the parser's fallback); an
  # unknown one gets the house color rather than a crash.
  defp track_color(_track), do: hd(@track_palette)

  # One place computes the arranger's DOM id: the container carries it, and the
  # transport button points at it by data attribute.
  defp arranger_dom_id(%StudioMix{name: name}), do: "studio-arranger-#{:erlang.phash2(name)}"
end
