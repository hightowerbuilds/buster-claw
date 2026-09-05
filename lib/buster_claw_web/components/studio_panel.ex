defmodule BusterClawWeb.StudioPanel do
  @moduledoc """
  The Studio's three tabs: `Mix` — the cutting-and-arranging studio — `Voice
  Library`.

  Presentation only. `select_studio_tab` is handled by the parent LiveView
  (`StudioLive`), which owns the `:studio_tab` assign for the same reason it
  always did: this panel renders behind `:if`, so state kept here would not
  survive a tab switch. `BusterClawWeb.Studio.MixState` puts it at length, and the
  wiring lives there.

  > **This said "the home Studio tab" and named `StatusLive` until 08-17.** Both
  > were true until the Studio became its own route (`/studio`) on 08-16 and took
  > its assigns with it — `StatusLive` now holds none of them. The reasoning
  > never changed; only the surface it applies to did, which is exactly the drift
  > a route change leaves behind.

  ## What lives where

  This module is the **rail and the dispatch**, and nothing else — the shape
  `BusterClawWeb.ExplainedPanel` arrived at, copied deliberately:

  | Module | Tab |
  |---|---|
  | `Studio.Registry` | the sub-tabs, labels and blurbs — **add a tab here** |
  | `SoundStudioComponent` | Mix, rendered unchanged (see below) |
  | `Studio.VoiceLibrary` | Voice Library — sidebar + words/sentence/record |
  | `placeholder/1`, below | a sub-tab whose surface is unwritten — **none today** |

  The rail, the parent's event whitelist (via `tab_keys/0`) and the dispatch
  below all read from `Studio.Registry`, so a tab cannot exist in one of them
  and not the others.

  ## Why the rail is above the studio rather than inside it

  `SoundStudioComponent` was `FROZEN` in `scripts/check_file_sizes.sh` when this
  rail was built — capped at exactly its size, unable to gain a line — so a
  sub-tab rail *inside* it was never available. Above it, Mix renders with the
  same id and the same assigns it always had, and that file is not touched.

  It was unfrozen on 08-16 once the phase it was frozen for had been taken, and
  the shape stays anyway: a rail that chooses BETWEEN surfaces does not belong
  inside one of them.

  The rail is deliberately **not** wrapped in an `ic-panel`: each tab body brings
  its own panel (the studio's is `#studio-panel`), and on the homepage
  `.ic-panel` is translucent and blurred so the background shader reads through.
  Nesting one panel inside another would double both.
  """
  use BusterClawWeb, :html

  alias BusterClawWeb.Studio.Registry
  alias BusterClawWeb.Studio.VoiceLibrary

  @doc "Sub-tab keys, in rail order — the parent's `select_studio_tab` whitelist."
  def tab_keys, do: Enum.map(Registry.tabs(), & &1.key)

  attr :tab, :string, required: true

  # Mix's assigns, passed straight through to the frozen component. They are
  # `StatusLive`'s, not this panel's: every one of them must outlive the `:if`
  # that discards the component on a home-tab switch.
  attr :studio_source, :any, required: true
  attr :studio_trim, :any, required: true
  attr :studio_clip, :any, required: true
  attr :studio_clip_data, :any, required: true
  attr :studio_preview, :any, required: true
  attr :studio_clipboard, :any, required: true
  attr :studio_undo, :list, required: true
  attr :studio_redo, :list, required: true

  # Voice's, prepared by `Studio.VoiceState`. `rows` and `check` are derived rather
  # than stored: the LiveView computes them from the loaded report so this panel
  # stays presentation-only and does no filtering of its own.
  attr :voice_report, :any, required: true
  attr :voice_error, :any, required: true
  attr :voice_query, :string, required: true
  attr :voice_sentence, :string, required: true
  attr :voice_rows, :list, required: true
  attr :voice_check, :list, required: true

  attr :voice_section, :string, required: true
  attr :voice_selected, :any, required: true
  attr :voice_takes, :list, required: true
  attr :voice_preview, :any, required: true
  attr :voice_preview_error, :any, required: true
  attr :voice_notice, :any, required: true

  # The recorder's whole state, as ONE assign. Deliberately unlike Voice's
  # scalars above: this is one cohesive thing (a bank, a device, a word, a
  # pending notice), and `status_live.ex` is at its cap for a reason worth not
  # spending on six more attr threads. See `Studio.RecorderState`.
  attr :recorder, :map, required: true

  def studio_panel(assigns) do
    assigns = assign(assigns, tabs: Registry.tabs(), placeholders: Registry.placeholders())

    ~H"""
    <div id="home-studio-tabs" class="flex min-h-0 flex-1 flex-col gap-2">
      <div
        role="tablist"
        aria-label="Studio"
        class="flex shrink-0 flex-wrap gap-1 border-b-2 border-base-content/20"
      >
        <button
          :for={t <- @tabs}
          type="button"
          role="tab"
          title={t.blurb}
          aria-selected={to_string(@tab == t.key)}
          phx-click="select_studio_tab"
          phx-value-tab={t.key}
          class={[
            "-mb-0.5 border-b-2 px-3 py-1.5 font-display text-xs font-bold uppercase tracking-wide transition",
            if(@tab == t.key,
              do: "border-primary text-primary",
              else: "border-transparent text-base-content/55 hover:text-base-content"
            )
          ]}
        >
          {t.label}
        </button>
      </div>

      <%!-- Mix: the existing studio, unchanged. Same id the arranger's
            `send_update/2` addresses, same assigns it has always had. --%>
      <div :if={@tab == "mix"} data-studio-tab="mix" class="flex min-h-0 flex-1 flex-col">
        <.live_component
          module={BusterClawWeb.SoundStudioComponent}
          id="home-studio"
          studio_source={@studio_source}
          studio_trim={@studio_trim}
          studio_clip={@studio_clip}
          studio_clip_data={@studio_clip_data}
          studio_preview={@studio_preview}
          studio_clipboard={@studio_clipboard}
          studio_undo={@studio_undo}
          studio_redo={@studio_redo}
        />
      </div>

      <%!-- Voice Library: browse, build, record. Its assigns are StatusLive's
            for the same reason Mix's are — see `Studio.VoiceState`. --%>
      <div :if={@tab == "voice"} data-studio-tab="voice" class="flex min-h-0 flex-1 flex-col">
        <VoiceLibrary.library
          report={@voice_report}
          error={@voice_error}
          query={@voice_query}
          sentence={@voice_sentence}
          rows={@voice_rows}
          check={@voice_check}
          section={@voice_section}
          selected={@voice_selected}
          takes={@voice_takes}
          preview={@voice_preview}
          preview_error={@voice_preview_error}
          notice={@voice_notice}
          recorder={@recorder}
        />
      </div>

      <.placeholder :for={p <- @placeholders} :if={@tab == p.key} sub_tab={p} />
    </div>
    """
  end

  attr :sub_tab, :map, required: true

  # A sub-tab before its surface exists. `Explained.Stub` was the obvious thing to
  # reuse and does not fit: it renders a deep link into the real tab a tutorial
  # describes, and Voice has no real tab to link to — the feature is what does
  # not exist. So this says what will live here and stops. No stub controls:
  # a dead knob reads as a broken feature, an empty state reads as an empty state.
  defp placeholder(assigns) do
    ~H"""
    <section
      data-studio-tab={@sub_tab.key}
      class="ic-panel flex min-h-0 flex-1 flex-col overflow-y-auto"
    >
      <div class="mx-auto flex max-w-2xl flex-col gap-5 px-6 py-8">
        <div>
          <p class="ic-eyebrow">{@sub_tab.eyebrow}</p>
          <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
            {@sub_tab.label}
          </h2>
        </div>

        <p class="text-sm leading-relaxed text-base-content/80">{@sub_tab.body}</p>

        <p class="font-mono text-xs uppercase tracking-wide text-base-content/45">
          Not built yet — there is nothing to use on this tab.
        </p>
      </div>
    </section>
    """
  end
end
