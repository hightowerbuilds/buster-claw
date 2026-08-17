defmodule BusterClawWeb.Studio.Sentence do
  @moduledoc """
  The Voice Library's **Sentence** pane: can this voice say it, and what does it
  sound like when it tries (`STUDIO_ROADMAP` VI.1, and the payoff of Part III).

  Two states, and the order matters. **Grading is free and instant** — it looks
  each word up in the report already loaded, so it runs on every keystroke and
  tells you what is missing before you ask for anything. **Building is not** —
  it selects between takes, splices, and writes a file — so it happens when you
  press the button.

  That split is the reason a missing word is visible before a build is attempted:
  the failure this pane exists to prevent is spending a splice to learn what a
  chip could have told you.

  ## Building goes through the same code an agent uses

  `Studio.VoiceState.build_preview/1` calls `Cutup.Sentence.build/2`, which is what
  `sound_sentence` calls. There is no web-layer splicer: two builders would have
  drifted on padding, fades and take choice, which are exactly the things that
  decide whether the result is audible.

  The preview overwrites one fixed file rather than accumulating numbered ones.
  A sentence preview is scratch — not a take, not part of the corpus.
  """
  use BusterClawWeb, :html

  attr :report, :any, required: true
  attr :sentence, :string, required: true
  attr :check, :list, required: true
  attr :preview, :any, required: true
  attr :preview_error, :any, required: true

  def sentence(assigns) do
    assigns =
      assign(assigns, :summary, BusterClawWeb.Studio.VoiceState.sentence_summary(assigns.check))

    ~H"""
    <section id="voice-sentence" phx-hook="VoiceAudition" class="flex min-h-0 flex-1 flex-col gap-2">
      <h3 class="shrink-0 font-display text-sm font-black uppercase tracking-tight">
        Can it say this?
      </h3>

      <%!-- Same native-submit trap as the word filter. Enter is the natural
            gesture for "make this", so it holds that place: it builds. --%>
      <form phx-change="voice_sentence" phx-submit="voice_preview" class="shrink-0">
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

      <div :if={@check != []} class="flex shrink-0 flex-wrap items-center gap-2">
        <span class="font-mono text-[0.7rem] text-base-content/60">
          {@summary.cuttable} cuttable · {@summary.quotable} quote only · {@summary.missing} missing
        </span>

        <button
          type="button"
          phx-click="voice_preview"
          disabled={@summary.missing > 0}
          title={
            (@summary.missing > 0 && "Every word needs at least one take before this can be built.") ||
              "Splice the takes and play the result"
          }
          class={[
            "rounded border-2 px-3 py-1 font-display text-xs font-bold uppercase tracking-wide transition",
            if(@summary.missing > 0,
              do: "cursor-not-allowed border-base-content/20 text-base-content/35",
              else: "border-primary text-primary hover:bg-primary/10"
            )
          ]}
        >
          Build &amp; play
        </button>
      </div>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <p :if={@report && @check == []} class="px-1 py-3 text-sm text-base-content/50">
          Type a phrase to see which of its words this voice can cut, which it can
          only quote, and which it has never said.
        </p>

        <%!-- Every chip is a door, and which door depends on the verdict — see
              `chip_event/1`. A word that exists opens in Words with its takes;
              a word that does not arms the recorder for it, because a recording
              is the only thing that changes a `missing`. --%>
        <div class="flex flex-wrap gap-1.5 p-1">
          <button
            :for={row <- @check}
            type="button"
            phx-click={chip_event(row.verdict)}
            phx-value-word={row.word}
            title={chip_title(row)}
            class={[
              "rounded px-2 py-1 font-mono text-xs transition hover:ring-2 hover:ring-current/40",
              chip_class(row.verdict)
            ]}
          >
            {row.text}<span class="ml-1 opacity-70">{row.takes}</span>
          </button>
        </div>
      </div>

      <p
        :if={@preview_error}
        class="shrink-0 rounded border-2 border-error/40 bg-error/10 px-2 py-1.5 text-sm text-error"
      >
        {build_error(@preview_error)}
      </p>

      <%!-- The built file is a real source, so it plays through the same route
            and the same hook a take does — `data-start` omitted means "the whole
            file", which is what a sentence is. --%>
      <div
        :if={@preview}
        class="flex shrink-0 items-center gap-2 rounded border-2 border-success/40 bg-success/10 px-2 py-1.5"
      >
        <button
          type="button"
          data-play
          data-source={@preview.name}
          data-version={@preview.version}
          class="rounded border-2 border-success/50 px-2 py-1 font-display text-xs font-bold uppercase tracking-wide text-success transition hover:bg-success/20"
        >
          ▶ Play
        </button>
        <span class="min-w-0 truncate font-mono text-[0.7rem] text-success">
          “{@preview.phrase}”
        </span>
      </div>
    </section>
    """
  end

  # Missing is the loudest on purpose: it is the only verdict a recording can
  # change, so it is what a donor passage gets written from.
  defp chip_class(:missing), do: "bg-error/25 text-error"
  defp chip_class(:quotable), do: "bg-warning/20 text-warning"
  defp chip_class(:cuttable), do: "bg-success/15 text-success"

  # A `missing` word cannot be opened in Words — there is nothing there to show.
  # It leads to the recorder instead, which is the only place it can stop being
  # missing.
  defp chip_event(:missing), do: "voice_record_word"
  defp chip_event(_verdict), do: "voice_open_word"

  # The tooltip says where the chip GOES, not only what it means. Two
  # destinations from chips that differ only by colour would otherwise be a
  # surprise the second time rather than a shortcut.
  defp chip_title(%{verdict: :missing, word: word}),
    do: "#{word}: no take. Click to record one."

  defp chip_title(%{verdict: :quotable, word: word}),
    do: "#{word}: one take. Click to hear it. Quotable, but splicing it is not a cut-up."

  defp chip_title(%{verdict: :cuttable, word: word, takes: takes}),
    do: "#{word}: #{takes} takes. Click to hear them and pick one."

  # `Cutup.Sentence` names the words it could not find, and naming them is the
  # whole value — "no takes" is not actionable and "you have no take of zebra" is.
  defp build_error({:words_not_found, words}),
    do: "Not built: this voice has no take of #{Enum.join(words, ", ")}. Record one."

  defp build_error(:no_takes), do: "Not built: none of those words is in this voice yet."
  defp build_error(:empty_phrase), do: "Type a phrase first."
  defp build_error(reason), do: "Not built: #{inspect(reason)}."
end
