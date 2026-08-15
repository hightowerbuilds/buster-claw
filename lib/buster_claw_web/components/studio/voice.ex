defmodule BusterClawWeb.Studio.Voice do
  @moduledoc """
  The Studio's **Voice** sub-tab: the Ramshackle surface (`STUDIO_ROADMAP` VI.1).

  Presentation only. Every assign belongs to `StatusLive` and is prepared by
  `BusterClawWeb.Status.Voice`, for the reason the whole home tab works that way:
  this renders behind `:if`, so state kept here would not survive a glance at
  Chat.

  ## What it shows today

  Two of VI.1's three panes, and the pair that need no microphone:

    * **Vocabulary** — the library of words, by take count, searchable.
    * **Sentence check** — can the corpus say this phrase, and how well.

  The one number this surface exists to make unmissable: **a word with one take
  is a quotation, not a cut-up.** Splicing a word that exists exactly once
  reproduces the speaker saying it at the one pitch and pace they used; there was
  no choice to make and nothing was assembled. Single-take words are therefore
  marked everywhere they appear, not tucked into a legend.

  ## What is deliberately absent

  **Pane 2 — takes, waveform, audition.** It needs a route serving a take's
  audio, which is its own surface. Browsing a corpus you cannot yet hear is
  still worth having, and it is why this ships before the recorder does.

  **A record button.** Nothing in this app captures audio yet
  (`STUDIO_ROADMAP` V.6–V.8), and the tab says so rather than offering a control
  that would do nothing — the same standard the placeholder it replaces held
  itself to.
  """
  use BusterClawWeb, :html

  attr :report, :any, required: true
  attr :error, :any, required: true
  attr :query, :string, required: true
  attr :sentence, :string, required: true
  attr :rows, :list, required: true
  attr :check, :list, required: true

  def voice(assigns) do
    ~H"""
    <div id="studio-voice" class="ic-panel flex min-h-0 flex-1 flex-col gap-3 p-3">
      <div class="flex shrink-0 flex-wrap items-baseline justify-between gap-2">
        <div>
          <p class="font-mono text-[0.65rem] uppercase tracking-[0.2em] text-base-content/50">
            Ramshackle
          </p>
          <h2 class="font-display text-lg font-black uppercase tracking-tight">
            Your words
          </h2>
        </div>

        <div class="flex items-center gap-2">
          <span :if={@report} class="font-mono text-[0.7rem] text-base-content/60">
            {@report.distinct_words} words · {@report.total_takes} takes · {@report.indexed_sources} sources
          </span>
          <button
            type="button"
            phx-click="voice_refresh"
            class="rounded border-2 border-base-content/30 px-3 py-1.5 text-xs font-semibold transition hover:bg-base-200"
          >
            Re-read
          </button>
        </div>
      </div>

      <p :if={@error} class="shrink-0 text-sm text-error">
        The corpus could not be read: {inspect(@error)}
      </p>

      <p
        :if={@report && @report.indexed_sources == 0}
        class="shrink-0 text-sm text-base-content/60"
      >
        No indexed sources yet. Words appear here once a recording has been
        indexed — a dev workspace legitimately has none, since the corpus lives
        under the configured DataZone.
      </p>

      <div class="grid min-h-0 flex-1 gap-3 lg:grid-cols-2">
        <.vocabulary_pane report={@report} query={@query} rows={@rows} />
        <.sentence_pane report={@report} sentence={@sentence} check={@check} />
      </div>

      <p class="shrink-0 border-t border-base-content/15 pt-2 font-mono text-[0.65rem] text-base-content/45">
        Recording is not built yet (STUDIO_ROADMAP V.6–V.8). These words came from
        voicemails that were already here.
      </p>
    </div>
    """
  end

  attr :report, :any, required: true
  attr :query, :string, required: true
  attr :rows, :list, required: true

  defp vocabulary_pane(assigns) do
    ~H"""
    <section class="flex min-h-0 flex-col gap-2 rounded border-2 border-base-content/15 p-2">
      <div class="flex shrink-0 items-center justify-between gap-2">
        <h3 class="font-display text-sm font-black uppercase tracking-tight">Vocabulary</h3>
        <span :if={@report} class="font-mono text-[0.65rem] text-base-content/50">
          {@report.cuttable} cuttable · {length(@report.single_take)} single take
        </span>
      </div>

      <%!-- `phx-submit` is not optional here even though nothing submits: a
            single-input form with no submit handler is submitted NATIVELY by the
            browser on Enter, which navigates the page, remounts the LiveView and
            drops the operator back on the Chat tab. Found in the packaged app
            08-15 (DMG-review-8-15, finding 3). LiveView tests drive
            `render_change/2` and cannot produce a native submit, so the suite
            could not have caught it. --%>
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
          <li
            :for={{word, takes} <- @rows}
            class="flex items-center justify-between gap-2 px-1 py-1"
          >
            <span class="truncate font-mono text-sm">{word}</span>

            <span
              :if={takes == 1}
              title="One take — this can be quoted, but not cut."
              class="shrink-0 rounded bg-warning/20 px-1.5 py-0.5 font-mono text-[0.6rem] font-bold uppercase tracking-wide text-warning"
            >
              1 · quote only
            </span>
            <span
              :if={takes > 1}
              class="shrink-0 font-mono text-[0.7rem] text-base-content/55"
            >
              {takes}
            </span>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :report, :any, required: true
  attr :sentence, :string, required: true
  attr :check, :list, required: true

  defp sentence_pane(assigns) do
    assigns =
      assign(assigns, :summary, BusterClawWeb.Status.Voice.sentence_summary(assigns.check))

    ~H"""
    <section class="flex min-h-0 flex-col gap-2 rounded border-2 border-base-content/15 p-2">
      <h3 class="shrink-0 font-display text-sm font-black uppercase tracking-tight">
        Can it say this?
      </h3>

      <%!-- Same reason as the filter above. Enter is the natural gesture for
            "make this", so it holds that place: today it re-grades the phrase,
            and it is where assembly lands when V.7 gives the tab something to
            build with. --%>
      <form phx-change="voice_sentence" phx-submit="voice_sentence" class="shrink-0">
        <input
          type="text"
          name="sentence"
          value={@sentence}
          placeholder="Type a phrase…"
          autocomplete="off"
          phx-debounce="200"
          class="w-full rounded border-2 border-base-content/20 bg-base-100 px-2 py-1.5 text-sm"
        />
      </form>

      <p :if={@check != []} class="shrink-0 font-mono text-[0.7rem] text-base-content/60">
        {@summary.cuttable} cuttable · {@summary.quotable} quote only · {@summary.missing} missing
      </p>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <p :if={@report && @check == []} class="px-1 py-3 text-sm text-base-content/50">
          Type a phrase to see which of its words this corpus can cut, which it can
          only quote, and which it has never heard.
        </p>

        <div class="flex flex-wrap gap-1.5 p-1">
          <span
            :for={row <- @check}
            title={chip_title(row)}
            class={[
              "rounded px-2 py-1 font-mono text-xs",
              chip_class(row.verdict)
            ]}
          >
            {row.text}<span class="ml-1 opacity-70">{row.takes}</span>
          </span>
        </div>
      </div>
    </section>
    """
  end

  # Missing is the loudest on purpose: it is the only verdict a recording can
  # change, so it is what a donor passage gets written from.
  defp chip_class(:missing), do: "bg-error/25 text-error"
  defp chip_class(:quotable), do: "bg-warning/20 text-warning"
  defp chip_class(:cuttable), do: "bg-success/15 text-success"

  defp chip_title(%{verdict: :missing, word: word}),
    do: "#{word}: no take. Only a recording can add this one."

  defp chip_title(%{verdict: :quotable, word: word}),
    do: "#{word}: one take. Quotable, but splicing it is not a cut-up."

  defp chip_title(%{verdict: :cuttable, word: word, takes: takes}),
    do: "#{word}: #{takes} takes to choose between."
end
