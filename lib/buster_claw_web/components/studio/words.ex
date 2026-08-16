defmodule BusterClawWeb.Studio.Words do
  @moduledoc """
  The Voice Library's **Words** pane: what this voice can say, and what it
  sounds like (`STUDIO_ROADMAP` VI.1, panes 1 and 2).

  ## Pane 2 existed the whole time

  VI.1 listed *"takes, waveform, audition"* as deliberately absent because it
  "needs a route serving a take's audio, which is its own surface". That turned
  out to be false, and pleasantly so: `/studio/file/:name` has served any studio
  source with byte ranges since the Studio shipped, and a **take is a slice of a
  source** — `start_ms` to `end_ms` in a file the browser can already fetch. The
  missing piece was never a route. It was the arithmetic to play part of a file,
  which is twenty lines of WebAudio in `voice_audition.js`.

  Recorded because "this needs its own surface" is the kind of estimate that
  keeps a feature unbuilt for weeks at zero cost to whoever wrote it.

  ## One take is a quotation, not a cut-up

  The single most useful thing this pane shows. Splicing a word that exists
  exactly once reproduces the speaker saying it at the one pitch and pace they
  used; there was no choice to make and nothing was assembled. So single-take
  words are marked everywhere they appear, never tucked into a legend — and the
  take list says the same thing again when you open one.
  """
  use BusterClawWeb, :html

  attr :report, :any, required: true
  attr :query, :string, required: true
  attr :rows, :list, required: true
  attr :selected, :any, required: true
  attr :takes, :list, required: true

  def words(assigns) do
    ~H"""
    <div class="grid min-h-0 flex-1 gap-3 lg:grid-cols-2">
      <section class="flex min-h-0 flex-col gap-2">
        <h3 class="shrink-0 font-display text-sm font-black uppercase tracking-tight">
          Vocabulary
        </h3>

        <%!-- `phx-submit` is not optional even though nothing submits: a
              single-input form with no submit handler is submitted NATIVELY by
              the browser on Enter, which navigates the page, remounts the
              LiveView and drops the operator back on the Chat tab. Found in the
              packaged app 08-15 (DMG-review-8-15, finding 3). LiveView tests
              drive `render_change/2` and cannot produce a native submit, so the
              suite could not have caught it. --%>
        <form phx-change="voice_search" phx-submit="voice_search" class="shrink-0">
          <input
            type="text"
            name="query"
            value={@query}
            placeholder="Filter words…"
            autocomplete="off"
            phx-debounce="150"
            class="w-full rounded border-2 border-base-content/20 bg-base-100 px-2 py-1.5 text-sm"
          />
        </form>

        <div class="min-h-0 flex-1 overflow-y-auto">
          <p :if={@report && @rows == []} class="px-1 py-3 text-sm text-base-content/50">
            No word matches that.
          </p>

          <ul class="divide-y divide-base-content/10">
            <li :for={{word, takes} <- @rows}>
              <button
                type="button"
                phx-click="voice_select"
                phx-value-word={word}
                aria-current={@selected == word && "true"}
                class={[
                  "flex w-full items-center justify-between gap-2 px-1 py-1 text-left transition hover:bg-base-200",
                  @selected == word && "bg-base-200"
                ]}
              >
                <span class="truncate font-mono text-sm">{word}</span>

                <span
                  :if={takes == 1}
                  title="One take — this can be quoted, but not cut."
                  class="shrink-0 rounded bg-warning/20 px-1.5 py-0.5 font-mono text-[0.6rem] font-bold uppercase tracking-wide text-warning"
                >
                  1 · quote only
                </span>
                <span :if={takes > 1} class="shrink-0 font-mono text-[0.7rem] text-base-content/55">
                  {takes}
                </span>
              </button>
            </li>
          </ul>
        </div>
      </section>

      <.takes selected={@selected} takes={@takes} />
    </div>
    """
  end

  attr :selected, :any, required: true
  attr :takes, :list, required: true

  # Pane 2. The hook owns playback and nothing else — the list itself is
  # server-rendered, so `phx-update="ignore"` would be wrong here (it was the bug
  # found on the recorder the same day). Each button carries the source and the
  # slice; `voice_audition.js` fetches, decodes and plays that range.
  defp takes(assigns) do
    ~H"""
    <section id="voice-takes" phx-hook="VoiceAudition" class="flex min-h-0 flex-col gap-2">
      <h3 class="shrink-0 font-display text-sm font-black uppercase tracking-tight">
        {(@selected && "Takes of “#{@selected}”") || "Takes"}
      </h3>

      <p :if={is_nil(@selected)} class="px-1 py-3 text-sm text-base-content/50">
        Pick a word to hear the takes this voice has of it.
      </p>

      <p
        :if={@selected && length(@takes) == 1}
        class="shrink-0 rounded border-2 border-warning/40 bg-warning/10 px-2 py-1.5 text-xs text-warning"
      >
        One take. This word can be quoted, but splicing it is not a cut-up —
        every sentence using it will sound identical here.
      </p>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <ul class="divide-y divide-base-content/10">
          <li
            :for={{hit, i} <- Enum.with_index(@takes, 1)}
            class={[
              "flex items-center gap-2 px-1 py-1.5",
              hit.preferred? && "bg-primary/10"
            ]}
          >
            <button
              type="button"
              data-play
              data-source={hit.source}
              data-start={hit.word.start_ms}
              data-end={hit.word.end_ms}
              title="Play this take"
              class="flex min-w-0 flex-1 items-center gap-2 text-left transition hover:text-primary"
            >
              <span class="shrink-0 font-mono text-[0.7rem] text-base-content/40">{i}</span>
              <span class="truncate font-mono text-xs">{hit.source}</span>
              <span class="shrink-0 font-mono text-[0.65rem] text-base-content/45">
                {round(hit.word.end_ms - hit.word.start_ms)} ms · {confidence(hit.word.confidence)}
              </span>
            </button>

            <%!-- "Use this one" is a toggle, not a radio group: clicking the
                  chosen take again clears the choice and hands the decision back
                  to `Cutup.Select`. A radio would have no off. --%>
            <button
              type="button"
              phx-click={(hit.preferred? && "voice_unprefer") || "voice_prefer"}
              phx-value-source={hit.source}
              phx-value-start={hit.word.start_ms}
              title={
                (hit.preferred? && "Used for this word — click to let the lattice choose again") ||
                  "Always use this take for this word"
              }
              aria-pressed={to_string(hit.preferred?)}
              class={[
                "shrink-0 rounded border-2 px-1.5 py-0.5 font-mono text-[0.6rem] font-bold uppercase tracking-wide transition",
                if(hit.preferred?,
                  do: "border-primary bg-primary/20 text-primary",
                  else: "border-base-content/20 text-base-content/45 hover:border-primary/50"
                )
              ]}
            >
              {(hit.preferred? && "using") || "use"}
            </button>

            <%!-- No confirmation dialog, deliberately: `Cutup.Takes.delete/2`
                  keeps the audio unless the file was recorded for this one word,
                  and the notice above says which happened. A modal for an action
                  that is usually reversible trains people to click through. --%>
            <button
              type="button"
              phx-click="voice_delete"
              phx-value-source={hit.source}
              phx-value-start={hit.word.start_ms}
              title="Delete this take"
              class="shrink-0 rounded border-2 border-transparent px-1.5 py-0.5 font-mono text-[0.7rem] text-base-content/35 transition hover:border-error/40 hover:text-error"
            >
              ✕
            </button>
          </li>
        </ul>
      </div>

      <p
        :if={@selected && length(@takes) > 1}
        class="shrink-0 border-t border-base-content/15 pt-1.5 font-mono text-[0.6rem] leading-relaxed text-base-content/45"
      >
        With no take marked <span class="font-bold">using</span>, the lattice picks
        per sentence — it weighs how well each take joins its neighbours, so the
        best one can differ by phrase.
      </p>
    </section>
    """
  end

  # Confidence is a RANK, not a measurement — `Cutup.Types` is explicit that it
  # orders takes rather than quantifying them. Rendered as a short label so it
  # cannot be read as a percentage of anything.
  defp confidence(value) when value >= 1.0, do: "marked"
  defp confidence(value) when value >= 0.9, do: "high"
  defp confidence(value) when value >= 0.7, do: "fair"
  defp confidence(_value), do: "low"
end
