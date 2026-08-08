defmodule BusterClaw.Notifications.Cutup.Align do
  @moduledoc """
  Forced alignment for the poor: a transcript, the spans of speech it must fit
  into, and one assumption — that people talk at a constant rate — turned into a
  `t:BusterClaw.Notifications.Cutup.Types.word/0` list an index can hold
  (STUDIO_ROADMAP Part II/III, the bootstrap under `Cutup.Index`).

  **This is the crude one, and it is supposed to be.** `Cutup.Types` says so
  already: query-by-example needs a seed, DTW can find every *other* take of a
  word but only once it has been handed one, and somebody has to produce the
  first instance. The alternative to this module is a person marking words by ear
  with a waveform display. So the bar it has to clear is not "accurate" — it is
  "closer than nothing, and honest about which of its guesses are bad".

  ## The two halves, and why neither is enough alone

  A **transcript** gives the word *sequence* — what was said, in order — and no
  times at all. **VAD** gives where speech *is* — `Cutup.Vad.spans/2` — and no
  idea which word is which. Each is exactly the half the other is missing, and
  the whole method is: distribute the sequence across the activity.

  ## The flattened timeline

  Not a running offset with a carry, which needs a special case at every span
  edge and grows one bug per edge. Instead:

      1. concatenate the spans into one virtual timeline of total speech
         duration T -- span 1 occupies [0, d1), span 2 [d1, d1+d2), and so on,
         with the silence between them simply not existing
      2. give word j a share of T proportional to its weight
      3. lay the words end to end on that timeline, so together they tile
         [0, T) exactly with no gaps and no overlaps
      4. map each word's virtual interval back to real time by walking the spans

  Step 3 is where the arithmetic is done, and it is done in *cumulative* weight
  rather than by accumulating a cursor — the same discipline `Cutup.Vad` applies
  to frame starts, and for the same reason: an accumulated float drifts, and a
  recomputed one is wrong by at most one ulp forever.

  ## Straddling a boundary: the word goes where most of it went

  A word's virtual interval can cross from one span into the next, and the real
  time it would map to in between is *silence* — which the speaker was not
  talking through. **Such a word is clamped to a single span: the one it
  overlaps most**, and it keeps only that overlap. Ties go to the earlier span.

  Why majority rather than "always the span it started in": the start rule turns
  a word that begins 5 ms before a span ends into a 5 ms cut, which is not a
  word by any measure, and it does that *systematically* at every boundary. The
  majority rule puts the word where its audio actually is. Both rules preserve
  the ordering guarantee — the next word begins exactly where the clamped one
  stopped inside the same span — so this is a choice about audio quality, not
  about correctness.

  What the clamped word loses is written into its confidence (see below), so a
  caller can drop it rather than splice a fragment.

  ## Weight: syllables, because letters are not time

  Spoken duration scales with **syllables**, not with orthography. English
  spelling is a famously poor proxy: `strengths` is nine letters and one beat;
  `idea` is four letters and three. So the default weight is a syllable estimate
  — count vowel groups, drop a silent terminal `e`, treat a leading `y` as the
  consonant it is, count each digit as its own beat — floored at one.

  `weight: :characters` is kept, because it is the obvious baseline and because
  being able to switch is what makes the choice inspectable rather than asserted.
  **Neither has been measured against real audio**; the argument for syllables is
  from first principles and from the estimator agreeing with the duration model,
  which is not the same as evidence.

  The estimator is a heuristic and gets words wrong, always in the same
  direction: adjacent vowels in *separate* syllables read as one group, so `idea`
  scores 2 (it is 3) and `poem` scores 1 (it is 2). It is ~15 lines, its misses
  are pinned in the tests, and it is nowhere near the limiting error in this
  module — the constant-rate assumption below is.

  ## Confidence: a plausibility score, not a probability

  These timings are guesses and the field exists so that downstream ranking knows
  it. **`Index.search/2`'s `:min_confidence` is the only thing standing between
  an assembled sentence and a splice of pure silence**, so emitting a constant
  here would throw away the one filter that costs nobody a listen.

  The score compares each word's allotted duration against an absolute
  expectation of `syllables x #{trunc(200.0)} ms` (conversational English runs
  about five syllables a second) and falls off as a Gaussian in the **log** of
  the ratio, because half and double are equally wrong:

      plausibility = exp(-0.5 x (ln(actual / expected) / ln 2)^2)
      confidence   = 0.9 x plausibility x kept_fraction

  - The scale is **0.0 to 0.9**. Nothing this module emits ever reaches 1.0: a
    plausible duration is not evidence that the boundary is right, and 1.0 is
    what `Index.build/3` gives a hand-authored fixture. A caller wanting
    "measured timings only" can therefore ask for `min_confidence: 0.95` and get
    exactly the hand-marked ones.
  - **1.0x expected -> 0.90. 2x or 0.5x -> 0.55. 4x -> 0.12. 8x -> 0.01.** A word
    crushed into 40 ms, or stretched over two seconds, lands near the floor and
    a `:min_confidence` of 0.3 removes it without anyone listening.
  - `kept_fraction` is the share of its allotment a clamped word retained; it is
    1.0 for every word that did not straddle a boundary. **A clamped word is
    therefore marked down twice** — once because it ended up with less time than
    a word of its length wants, and once for the fraction it lost. That is
    deliberate: the shortfall is a duration error, and the split is separate
    evidence that this particular word was placed across a silence the speaker
    was not talking through.

  **The expectation is absolute, and deliberately not self-calibrated.** Deriving
  the expected rate from this recording's own T and syllable count would be
  vacuous — the allotment is proportional by construction, so every word would
  score exactly 1.0 and the failure this score exists to catch would become
  invisible. The consequence is worth stating plainly: under `weight:
  :syllables` the ratio is the *same for every word in one call*, so confidence
  varies only through boundary clamping. That is not a bug hiding — it is the
  model admitting it has exactly one global fact and no per-word one. Under
  `weight: :characters` the ratio does vary per word, and what it flags is
  precisely the words character-weighting mistimes.

  ## What this assumes, and it is false

  **A constant speech rate within a span.** People do not talk that way. They
  slow at phrase ends (pre-boundary lengthening is one of the most robust effects
  in speech timing), stress content words, and rattle through function words —
  `the` and `of` are routinely under 80 ms while a stressed noun beside them runs
  400. Pauses shorter than `Cutup.Vad`'s `:min_silence_ms` sit *inside* a span
  and get shared out among words that were not being spoken during them.

  **Transcript errors are baked in and cannot be detected here.** This corpus is
  Twilio's telephony transcription, which renders "Buster Claw" as *"bus
  o'clock"* — which is why `bus` and `oclock` are words in the index's
  vocabulary, sitting on audio that says neither. Given a wrong word list, this
  module distributes the wrong words perfectly evenly. A missing or hallucinated
  word does worse than mistime itself: it shifts **every word after it**, because
  the timeline is shared.

  **The output is expected to be replaced, word by word.** That is the whole
  reason `t:BusterClaw.Notifications.Cutup.Types.index/0` carries `origin` and
  every word carries `confidence`: a DTW hit for the same word, with `origin:
  :recognizer`, is strictly better evidence and should overwrite this. Build the
  index with `origin: :imported` or `:recognizer` as fits, and treat these
  timings as scaffolding.

  **A transcript longer than the audio can hold is not refused.** Twilio
  hallucinates a tail on noisy voicemail, and there is no way here to tell an
  invented sentence from a fast one. So every word still gets its share, the
  shares are all absurdly short, and *the confidence of the whole batch collapses
  together* — 200 words over one second scores about 1e-7 each. The signal is in
  the data rather than in an error tuple, which is the only place a caller who
  did not think to check will still see it.

  ## Totality

  Nothing here raises and there is no error channel. A transcript that is empty,
  whitespace, or nothing but punctuation aligns to no words; so does an empty or
  entirely invalid span list. Tokens that normalise to nothing are dropped before
  any time is shared out, so punctuation never consumes audio. A word whose
  mapped interval rounds to zero length is dropped rather than emitted, since
  `Index.build/3` would refuse it anyway — compare lengths if you need to know.

  Overlapping spans (which `Cutup.Vad` never produces, but a hand-written list
  can) are trimmed against their predecessor before the timeline is built, so the
  same millisecond is never handed to two words.
  """

  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClaw.Notifications.Cutup.Types

  # Conversational English runs roughly five syllables a second. This is the one
  # number in the module that is a claim about human beings rather than about
  # arithmetic, which is why it is an option: measure it against the operator's
  # corpus before trusting the confidences it produces.
  @syllable_ms 200.0

  # The width of the plausibility bell, in log-ratio units. ln 2 means "one
  # octave of duration error costs you a bit over a third of the score" — chosen
  # so that being twice as long as expected is suspicious rather than fatal
  # (speakers do stress words that much) while 4x and 8x are not survivable.
  @log_tolerance :math.log(2.0)

  # No aligned word is ever fully trusted. See the moduledoc: 1.0 belongs to
  # hand-marked timings, and leaving headroom is what makes `:min_confidence`
  # able to separate the two origins.
  @ceiling 0.9

  @vowels ~c"aeiouy"

  @typedoc """
  How to weight a word when sharing out the speech.

  - `:syllables` (default) — a vowel-group estimate. Spoken duration tracks
    syllables; see the moduledoc.
  - `:characters` — the crude baseline, counted over the *normalised* form, so
    punctuation is not paid for.
  """
  @type weight :: :syllables | :characters

  @typedoc """
  - `:weight` — see `t:weight/0`. Defaults to `:syllables`.
  - `:syllable_ms` — the expected duration of one syllable, used **only** to
    score confidence and never to place a word. Defaults to
    `#{trunc(@syllable_ms)}`. Lower it for a fast speaker; the effect is that
    fewer of their words are marked implausible.
  """
  @type opts :: [weight: weight(), syllable_ms: number()]

  # A token on its way through: the raw text, its matchable form, its syllable
  # estimate (needed twice — once to weight, once to score), and its weight.
  @typep token :: {String.t(), String.t(), pos_integer(), float()}

  # One span, positioned on the virtual timeline as well as the real one.
  @typep placed :: %{v0: float(), v1: float(), start_ms: float()}

  # ---------------------------------------------------------------------------
  # The public surface
  # ---------------------------------------------------------------------------

  @doc """
  Distribute a transcript's words across spans of speech, in time order.

  Pure: no IO, no file reads, no clock. Every returned entry lies wholly inside
  one of the supplied spans — never in the silence between them — and entries are
  strictly ordered and non-overlapping.

  The result is shaped for `Cutup.Index.build/3`, which will accept it unchanged;
  give it `origin: :imported` (or `:recognizer`) rather than `:manual`, because
  `:manual` means "exact by definition" and these are not.

      iex> spans = [%{start_ms: 0.0, end_ms: 1000.0, frames: 100}]
      iex> BusterClaw.Notifications.Cutup.Align.align("cat dog", spans)
      ...> |> Enum.map(&{&1.word, &1.start_ms, &1.end_ms})
      [{"cat", 0.0, 500.0}, {"dog", 500.0, 1000.0}]

  See `t:opts/0` for the two options, and the moduledoc for what the timings
  assume, what confidence means, and which of both are false.
  """
  @spec align(String.t(), [Types.span()], opts()) :: [Types.word()]
  def align(transcript, spans, opts \\ [])

  def align(transcript, spans, opts)
      when is_binary(transcript) and is_list(spans) and is_list(opts) do
    mode = weight_mode(opts)

    case {tokenize(transcript, mode), timeline(spans)} do
      {[_ | _] = tokens, {[_ | _] = placed, total}} when total > 0.0 ->
        lay_out(tokens, placed, total, syllable_ms(opts))

      _nothing_to_do ->
        []
    end
  end

  def align(_transcript, _spans, _opts), do: []

  @doc """
  The syllable estimate used for weighting and for the duration expectation.

  Public because it is the module's one guess about language rather than about
  arithmetic, and a caller comparing weighting schemes — or a test pinning the
  words this heuristic is known to get wrong — needs to see it directly. Counts
  vowel groups over the *normalised* form, so it is punctuation- and
  case-insensitive; always at least 1, including for input that is not a binary.
  """
  @spec syllables(term()) :: pos_integer()
  def syllables(word) do
    normalized = Index.normalize_word(word)
    chars = String.to_charlist(strip_leading_y(normalized))

    groups = vowel_groups(chars)
    digits = Enum.count(chars, &(&1 in ?0..?9))

    max(groups + digits - silent_e(normalized, groups), 1)
  end

  # ---------------------------------------------------------------------------
  # Tokens
  # ---------------------------------------------------------------------------

  # Split on whitespace, keep the raw token for display, derive the matchable
  # form with the *same* normaliser the index and the query side use — a private
  # copy here would drift, and the drift would be invisible until a search
  # missed a word that is plainly in the file.
  #
  # A token that normalises to nothing (a lone dash, an ellipsis) is dropped
  # HERE, before any time is shared out. Keeping it would hand a slice of audio
  # to something `Index.build/3` discards on the way in, so the words either side
  # of it would be mistimed by a token nobody can ever search for.
  @spec tokenize(String.t(), weight()) :: [token()]
  defp tokenize(transcript, mode) do
    transcript
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.flat_map(fn raw ->
      case Index.normalize_word(raw) do
        "" -> []
        normalized -> [to_token(raw, normalized, mode)]
      end
    end)
  end

  defp to_token(raw, normalized, mode) do
    syllables = syllables(normalized)
    {raw, normalized, syllables, word_weight(normalized, syllables, mode)}
  end

  defp word_weight(_normalized, syllables, :syllables), do: syllables * 1.0

  defp word_weight(normalized, _syllables, :characters),
    do: max(String.length(normalized), 1) * 1.0

  # ---------------------------------------------------------------------------
  # Syllables
  # ---------------------------------------------------------------------------

  # A leading `y` is a consonant (`yes`, `yellow`); everywhere else it is a
  # vowel (`my`, `rhythm`). One character of special case buys both.
  defp strip_leading_y("y" <> rest), do: rest
  defp strip_leading_y(word), do: word

  defp vowel_groups(chars) do
    chars
    |> Enum.chunk_by(&(&1 in @vowels))
    |> Enum.count(fn [first | _rest] -> first in @vowels end)
  end

  # `make` is one syllable, `table` is two: a terminal `e` is silent unless a
  # consonant plus `le` is carrying the beat. Never applied when it would take
  # the count to zero, so `the` and `be` survive.
  defp silent_e(word, groups) do
    if groups > 1 and String.ends_with?(word, "e") and not Regex.match?(~r/[^aeiouy]le$/, word) do
      1
    else
      0
    end
  end

  # ---------------------------------------------------------------------------
  # The virtual timeline
  # ---------------------------------------------------------------------------

  # Spans in, `{spans positioned on both clocks, total speech duration}` out.
  @spec timeline([Types.span()]) :: {[placed()], float()}
  defp timeline(spans) do
    spans
    |> Enum.flat_map(&bounds/1)
    |> Enum.sort_by(&elem(&1, 0))
    |> disjoint()
    |> Enum.map_reduce(0.0, fn {start_ms, end_ms}, offset ->
      stop = offset + (end_ms - start_ms)
      {%{v0: offset, v1: stop, start_ms: start_ms}, stop}
    end)
  end

  # Anything that is not a usable span is dropped rather than repaired. A
  # negative start has no reading; a zero-length span is silence with a name.
  defp bounds(%{start_ms: start_ms, end_ms: end_ms})
       when is_number(start_ms) and is_number(end_ms) and start_ms >= 0 and end_ms > start_ms do
    [{start_ms * 1.0, end_ms * 1.0}]
  end

  defp bounds(_span), do: []

  # Trim each span against the furthest edge reached so far, so overlapping
  # input cannot hand the same millisecond to two different words. A span
  # entirely swallowed by its predecessor disappears, and the edge does not
  # move backwards with it.
  defp disjoint(sorted) do
    sorted
    |> Enum.reduce({[], 0.0}, fn {start_ms, end_ms}, {kept, edge} ->
      from = max(start_ms, edge)

      if end_ms > from do
        {[{from, end_ms} | kept], end_ms}
      else
        {kept, edge}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # ---------------------------------------------------------------------------
  # Laying the words out
  # ---------------------------------------------------------------------------

  defp lay_out(tokens, placed, total, syllable_ms) do
    sum = tokens |> Enum.map(&elem(&1, 3)) |> Enum.sum()

    if sum > 0.0 do
      tokens
      |> cumulative()
      |> Enum.flat_map(fn {token, before, through} ->
        # Recomputed from the cumulative weight, never stepped: a cursor
        # accumulated across several hundred words drifts, and the last word's
        # end stops being the end of the audio.
        place(
          token,
          min(total * before / sum, total),
          min(total * through / sum, total),
          placed,
          syllable_ms
        )
      end)
    else
      []
    end
  end

  # Each token paired with the weight before it and the weight through it.
  defp cumulative(tokens) do
    tokens
    |> Enum.map_reduce(0.0, fn {_raw, _word, _syl, weight} = token, before ->
      {{token, before, before + weight}, before + weight}
    end)
    |> elem(0)
  end

  # Map one virtual interval back to real time, clamped to the single span it
  # overlaps most. Linear in the span count per word, which at corpus scale
  # (hundreds of words, hundreds of spans) is nothing; if a recording ever has
  # tens of thousands of spans this is the line to make a merge walk.
  defp place({raw, word, syllables, _weight}, v0, v1, placed, syllable_ms) do
    allotted = v1 - v0

    case best_overlap(placed, v0, v1) do
      nil ->
        []

      {span, from, to} ->
        start_ms = span.start_ms + (from - span.v0)
        end_ms = span.start_ms + (to - span.v0)

        if end_ms > start_ms do
          [
            %{
              word: word,
              text: raw,
              start_ms: start_ms,
              end_ms: end_ms,
              confidence: confidence(end_ms - start_ms, allotted, syllables, syllable_ms)
            }
          ]
        else
          []
        end
    end
  end

  # `Enum.max_by/3` keeps the first maximal element, which is the documented
  # tie-break: a word split exactly down a boundary goes to the earlier span.
  defp best_overlap(placed, v0, v1) do
    placed
    |> Enum.map(fn span -> {span, max(v0, span.v0), min(v1, span.v1)} end)
    |> Enum.filter(fn {_span, from, to} -> to > from end)
    |> Enum.max_by(fn {_span, from, to} -> to - from end, fn -> nil end)
  end

  # ---------------------------------------------------------------------------
  # Confidence
  # ---------------------------------------------------------------------------

  # A Gaussian in the log of (allotted / expected), scaled by how much of its
  # allotment a boundary-clamped word kept. See the moduledoc for the scale and
  # for why the expectation is absolute rather than derived from this recording.
  defp confidence(actual_ms, allotted_ms, syllables, syllable_ms) do
    expected = syllables * syllable_ms
    kept = if allotted_ms > 0.0, do: min(actual_ms / allotted_ms, 1.0), else: 0.0
    error = :math.log(actual_ms / expected) / @log_tolerance

    (@ceiling * :math.exp(-0.5 * error * error) * kept)
    |> max(0.0)
    |> min(1.0)
  end

  # ---------------------------------------------------------------------------
  # Options. An unusable value falls back to the default rather than failing an
  # alignment over a typo — the same posture `Cutup.Vad` takes.
  # ---------------------------------------------------------------------------

  defp weight_mode(opts) do
    case Keyword.get(opts, :weight, :syllables) do
      :characters -> :characters
      _syllables -> :syllables
    end
  end

  defp syllable_ms(opts) do
    case Keyword.get(opts, :syllable_ms, @syllable_ms) do
      value when is_number(value) and value > 0 -> value * 1.0
      _invalid -> @syllable_ms
    end
  end
end
