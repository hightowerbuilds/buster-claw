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

  The expectation is `syllables x syllable_ms x reduction`, where `reduction` is
  the function-word multiplier applied to this token (1.0 for everything else,
  and 1.0 for every token when `reduce_function_words: false`). It is the only
  per-word term in the expectation and it exists so a reduced word is judged
  against the duration this module actually believes it should have.

  **The expectation is otherwise absolute, and deliberately not self-calibrated.**
  Deriving
  the expected rate from this recording's own T and syllable count would be
  vacuous — the allotment is proportional by construction, so every word would
  score exactly 1.0 and the failure this score exists to catch would become
  invisible. The consequence is worth stating plainly: under `weight:
  :syllables` the ratio is the *same for every word in one call*, so confidence
  varies only through boundary clamping. That is not a bug hiding — it is the
  model admitting it has exactly one global fact and no per-word one. Under
  `weight: :characters` the ratio does vary per word, and what it flags is
  precisely the words character-weighting mistimes.

  ## Two corrections to the proportional layout

  Everything above describes where the arithmetic *would* put a boundary. Two
  things then move it, and both exist because the operator listened to the first
  real assembled paragraph and the verdict was one word: "garbled". Both are
  independently switchable, so the four combinations can be compared by ear
  rather than argued about.

  ### 1. Snapping boundaries to energy minima (`:energy`, `:snap_to_energy`)

  A proportional boundary lands wherever the division put it, which is routinely
  **mid-vowel** — and a word cut through its own vowel is what "half-formed"
  sounds like. Only the *span* edges were ever quiet by construction; every
  interior boundary was arithmetic.

  Hand this `energy: Cutup.Vad.energy_profile(clip, opts)` and each interior
  boundary moves to the quietest analysis frame near it. **The unit is the
  boundary, not the word**: N words make N+1 boundaries, each is snapped exactly
  once, and adjacent words keep sharing the moved edge — so the layout still
  tiles with no gap and no overlap. Moving a word's start and its end separately
  is how you invent a gap.

  A frame is placed at its **centre** (`(start_ms + end_ms) / 2`), because its
  RMS is the energy over the whole 25 ms window and the midpoint is the only
  honest instant to attribute that to. Frames hop every 10 ms, so the snap
  resolution is 10 ms.

  Four invariants, each of which can veto a snap:

  - **Monotonic.** A boundary never passes a neighbour. Boundaries are walked
    left to right and each one's floor is the *already-snapped* boundary behind
    it, so order is preserved by construction rather than by checking afterwards.
  - **Bounded.** A boundary moves at most `:snap_window_ms` (default
    #{trunc(40.0)} ms) — far enough to reach a stop closure or an inter-word
    dip, nowhere near far enough to relocate a word into its neighbour.
  - **Inside a span.** The window is clipped to the span the boundary already
    sits in, so a snapped boundary can never land in the silence between spans.
    Words still tile real speech only. A boundary that already sits exactly on a
    span join is left alone: it is at a real silence edge already, which is the
    whole objective.
  - **No word annihilated.** Each side must keep `:min_word_ms` (default
    #{trunc(50.0)} ms), or its original duration if that was already shorter —
    a rule that can only ever refuse to shorten, never demand a word be
    lengthened. If no position satisfies all four, the boundary does not move.

  And one rule that is not an invariant but a refusal: the destination must be
  **strictly quieter** than the frame the boundary already sits in, or it stays.
  Without it a featureless profile — a synthesised clip, a gated carrier, a
  stretch of steady tone — would shuffle every boundary to its nearest frame
  centre for no acoustic reason at all.

  Ties go to the frame **nearest the original boundary**, and a remaining tie to
  the earlier of the two. This is deliberate and worth saying out loud: an
  arbitrary tie-break (first found, lowest index) drifts every tied boundary the
  same direction, and a systematic 10 ms drift applied at every boundary in a
  paragraph is a new defect wearing the old one's clothes.

  **What this does not do.** It finds a quiet *instant*, which is not the same as
  a word boundary — the quietest moment inside "sixty" is the stop closure in the
  middle of it. Within a 40 ms window that is usually the right answer anyway,
  because within 40 ms of a boundary the quietest thing usually *is* the
  boundary. It will be wrong across a word pair with no acoustic seam at all
  ("this study", "some more"), where there is no minimum to find and the snap
  will chase noise.

  ### 2. Reducing function words (`:reduce_function_words`)

  Proportional weighting hands `to` a full syllable's share — the same share as a
  stressed noun — and in real speech `to`, `the` and `of` run under 80 ms while
  the content word beside them runs 400. The over-allotment is not a rounding
  error: **the function word eats its neighbour's onset**, and onsets are what
  make a spliced word recognisable. The operator's corpus is dominated by exactly
  these tokens (`to` 35, `the` 29, `you` 28), so this lands on the words a cut-up
  splices most often.

  So a word in `@function_words` has its weight multiplied by
  `:function_word_scale` (default #{0.55}) before the shares are normalised —
  before, so the total allotted still equals the total speech exactly; the
  reduction redistributes time, it does not discard any.

  **This is a crude stand-in for prosody and will be wrong in a way no word list
  can fix.** Reduction is a property of stress and position, not of a word's
  identity: "**TO** the shop" and "I want to **GO**" contain the same token at
  very different durations, and this module cannot tell them apart because it has
  no acoustics for the word — only the letters. It gets the common case right
  (function words are unstressed most of the time) and is confidently wrong on
  the stressed minority, where it will now cut the word short. 0.55 is picked at
  the timid end of the plausible 0.4–0.6 band for exactly that reason: the errors
  are asymmetric. Under-reducing leaves some of a defect that already shipped;
  over-reducing takes audio out of a word that was really there.

  The confidence expectation is scaled by the same factor, so a reduced word is
  not marked down for obeying the model that reduced it. See the confidence
  section: that is the one place this module lets a weight feed back into the
  score, and it does so because using the reduced weight to place a word and the
  unreduced one to judge it would be incoherent rather than conservative.

  ## What this assumes, and it is false

  **A constant speech rate within a span.** People do not talk that way. They
  slow at phrase ends (pre-boundary lengthening is one of the most robust effects
  in speech timing), stress content words, and rattle through function words —
  `the` and `of` are routinely under 80 ms while a stressed noun beside them runs
  400. The function-word multiplier above is a first-order patch on the last of
  those and nothing at all on the others. Pauses shorter than `Cutup.Vad`'s
  `:min_silence_ms` sit *inside* a span and get shared out among words that were
  not being spoken during them — though with an energy profile in hand the
  boundaries either side of such a pause will now tend to fall into it.

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

  # How far a boundary may travel to reach a quiet frame. Wide enough to cross a
  # voiceless stop's closure (50-100 ms, but its *edge* is what we are looking
  # for) and an ordinary inter-word dip; narrow enough that a boundary cannot
  # leave the phoneme it belongs to. Above ~80 ms a boundary starts being able to
  # swallow a short function word whole, which is the failure this must not have.
  @snap_window_ms 40.0

  # The shortest word this is willing to leave behind when it moves a boundary.
  # `Assemble` pads 30 ms outward on each side of a cut, so anything under about
  # this is padding with a click in the middle rather than a word. Only ever
  # applied as a floor on *shortening*: a word already below it is simply never
  # made shorter.
  @min_word_ms 50.0

  # The function-word multiplier. See the moduledoc for why 0.55 rather than the
  # 0.4 the durations themselves suggest: the errors are asymmetric, and the
  # timid end of the band is the right end to be wrong on.
  @function_word_scale 0.55

  # Words that are unstressed *most* of the time in running speech: articles,
  # prepositions, coordinating and subordinating conjunctions, auxiliary and
  # copular verbs, personal and possessive pronouns, and the handful of
  # contractions of those that survive normalisation (`don't` -> `dont`).
  #
  # What is deliberately NOT here, and why:
  #
  #   - negations (`not`, `no`, `never`) — short, look functional, and carry the
  #     entire meaning of the sentence. They are stressed.
  #   - wh-words (`what`, `when`, `where`, `who`, `why`, `how`) — the stressed
  #     peak of a question, which is most of what a voicemail is. `when` and
  #     `while` are subordinating conjunctions too and were in the list once;
  #     they came out again, because a word that is a wh-word half the time is
  #     exactly the coin flip this list is not allowed to take.
  #   - demonstratives and deictics (`this`, `that`, `these`, `there`, `here`) —
  #     genuinely ambiguous. `that` is a reduced complementiser about as often as
  #     it is a stressed pointer, and a coin flip is not worth a systematic edit.
  #   - `now`, `back`, `call`, `up`, `out` — short content words and stressed
  #     particles that look like function words and are not.
  #
  # The list is meant to stay modest. Every addition is a bet that the word is
  # unstressed more often than not, and a wrong bet cuts audio out of a word the
  # speaker leaned on.
  @function_words MapSet.new(~w(
                      a an the
                      to of in on at for with from by as into onto than
                      and or but nor if so because
                      is am are was were be been being
                      do does did done have has had
                      will would can could shall should may might must
                      i you he she it we they me him her us them
                      my your his its our their
                      im ive id ill youre youve youll hes shes its theyre
                      dont doesnt didnt isnt arent wasnt werent
                      cant couldnt wont wouldnt
                    ))

  @typedoc """
  How to weight a word when sharing out the speech.

  - `:syllables` (default) — a vowel-group estimate. Spoken duration tracks
    syllables; see the moduledoc.
  - `:characters` — the crude baseline, counted over the *normalised* form, so
    punctuation is not paid for.
  """
  @type weight :: :syllables | :characters

  @typedoc """
  Every option, with its default. The two corrections described in the moduledoc
  are independently switchable so all four combinations can be heard.

  Layout:

  - `:weight` — see `t:weight/0`. Defaults to `:syllables`.
  - `:syllable_ms` — the expected duration of one syllable, used **only** to
    score confidence and never to place a word. Defaults to
    `#{trunc(@syllable_ms)}`. Lower it for a fast speaker; the effect is that
    fewer of their words are marked implausible.

  Correction 1 — snapping boundaries to energy minima:

  - `:energy` — a `t:BusterClaw.Notifications.Cutup.Vad.profile/0` for the same
    audio these spans came from. **Absent by default, and absent means off**:
    without it this module behaves exactly as it did before snapping existed.
  - `:snap_to_energy` — defaults to `true`, and does nothing at all without
    `:energy`. Set it `false` to keep the profile in the call and turn the
    correction off for an A/B.
  - `:snap_window_ms` — the furthest a boundary may move, defaults to
    `#{trunc(@snap_window_ms)}`. `0` disables snapping as surely as the flag.
  - `:min_word_ms` — the shortest word a snap may leave behind, defaults to
    `#{trunc(@min_word_ms)}`. Never lengthens anything; see the moduledoc.

  Correction 2 — reducing function words:

  - `:reduce_function_words` — defaults to **`true`**. This is a correction to a
    behaviour known to be wrong, so it is on; `false` restores the old
    proportional shares for comparison.
  - `:function_word_scale` — the multiplier, defaults to `#{@function_word_scale}`.
    Values outside `0.0 < x <= 1.0` fall back to the default, because a
    multiplier above 1 would be *lengthening* function words and nothing here
    means that.
  """
  @type opts :: [
          weight: weight(),
          syllable_ms: number(),
          energy: map(),
          snap_to_energy: boolean(),
          snap_window_ms: number(),
          min_word_ms: number(),
          reduce_function_words: boolean(),
          function_word_scale: number()
        ]

  # A token on its way through. `syllables` is needed twice (once to weight, once
  # to score) and `reduction` is the function-word multiplier that was applied,
  # carried so the confidence expectation can be scaled by the same number that
  # scaled the allotment.
  @typep token :: %{
           text: String.t(),
           word: String.t(),
           syllables: pos_integer(),
           weight: float(),
           reduction: float()
         }

  # One span, positioned on the virtual timeline as well as the real one.
  @typep placed :: %{v0: float(), v1: float(), start_ms: float()}

  # Snapping, once the options have been resolved and the profile read. `:off` is
  # every reason not to snap collapsed into one — no profile, an unreadable one,
  # the flag down, a zero window — so the layout has exactly one thing to check.
  @typep snap :: :off | %{frames: [{float(), float()}], window: float(), min_word: float()}

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

  Pass `energy: Cutup.Vad.energy_profile(clip, opts)` — the profile for *this*
  audio — to have interior boundaries snapped to the quiet moments near them
  instead of landing wherever the division put them. Without it nothing about
  the placement changes.

  See `t:opts/0` for every option and its default, and the moduledoc for what the
  timings assume, what confidence means, and which of both are false.
  """
  @spec align(String.t(), [Types.span()], opts()) :: [Types.word()]
  def align(transcript, spans, opts \\ [])

  def align(transcript, spans, opts)
      when is_binary(transcript) and is_list(spans) and is_list(opts) do
    mode = weight_mode(opts)
    scale = function_word_scale(opts)

    case {tokenize(transcript, mode, scale), timeline(spans)} do
      {[_ | _] = tokens, {[_ | _] = placed, total}} when total > 0.0 ->
        tokens
        |> boundaries(total)
        |> snap_all(placed, snap_config(opts))
        |> lay_out(tokens, placed, syllable_ms(opts))

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
  @spec tokenize(String.t(), weight(), float()) :: [token()]
  defp tokenize(transcript, mode, scale) do
    transcript
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.flat_map(fn raw ->
      case Index.normalize_word(raw) do
        "" -> []
        normalized -> [to_token(raw, normalized, mode, scale)]
      end
    end)
  end

  defp to_token(raw, normalized, mode, scale) do
    syllables = syllables(normalized)
    reduction = reduction(normalized, scale)

    %{
      text: raw,
      word: normalized,
      syllables: syllables,
      # The multiplier lands on the weight, which is *before* normalisation —
      # the shares are divided by their own sum a step later, so reducing a
      # function word hands its time to its neighbours rather than losing it,
      # and the words still tile the speech exactly.
      weight: word_weight(normalized, syllables, mode) * reduction,
      reduction: reduction
    }
  end

  # `scale` is 1.0 when the correction is switched off, so there is one code
  # path and the disabled case is the identity rather than a branch.
  defp reduction(normalized, scale) do
    if MapSet.member?(@function_words, normalized), do: scale, else: 1.0
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

  # N tokens produce N+1 boundaries on the virtual timeline: `[0.0, ..., total]`.
  # This is the unit everything downstream works in, because a boundary is shared
  # by the two words either side of it and a word is not — move a boundary and
  # both words follow, move a word's edges and you have invented a gap.
  #
  # Each boundary is recomputed from the cumulative weight, never stepped: a
  # cursor accumulated across several hundred words drifts, and the last word's
  # end stops being the end of the audio.
  @spec boundaries([token()], float()) :: [float()]
  defp boundaries(tokens, total) do
    sum = tokens |> Enum.map(& &1.weight) |> Enum.sum()

    if sum > 0.0 do
      [0.0 | tokens |> cumulative() |> Enum.map(&min(total * &1 / sum, total))]
    else
      []
    end
  end

  # The running weight *through* each token.
  defp cumulative(tokens) do
    tokens
    |> Enum.map_reduce(0.0, fn %{weight: weight}, before ->
      {before + weight, before + weight}
    end)
    |> elem(0)
  end

  # Consecutive boundaries are one word's virtual interval. `Enum.zip/2` stops at
  # the shorter list, which is the two of them by construction (N+1 boundaries
  # chunk into N pairs) and is empty when there are no boundaries at all.
  defp lay_out(boundaries, tokens, placed, syllable_ms) do
    boundaries
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.zip(tokens)
    |> Enum.flat_map(fn {[v0, v1], token} -> place(token, v0, v1, placed, syllable_ms) end)
  end

  # Map one virtual interval back to real time, clamped to the single span it
  # overlaps most. Linear in the span count per word, which at corpus scale
  # (hundreds of words, hundreds of spans) is nothing; if a recording ever has
  # tens of thousands of spans this is the line to make a merge walk.
  defp place(token, v0, v1, placed, syllable_ms) do
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
              word: token.word,
              text: token.text,
              start_ms: start_ms,
              end_ms: end_ms,
              confidence:
                confidence(
                  end_ms - start_ms,
                  allotted,
                  token.syllables * token.reduction,
                  syllable_ms
                )
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
  # Snapping boundaries to energy minima
  # ---------------------------------------------------------------------------

  # No profile, no flag, no window: the boundaries are the arithmetic's, exactly
  # as they were before this existed.
  @spec snap_all([float()], [placed()], snap()) :: [float()]
  defp snap_all(boundaries, _placed, :off), do: boundaries

  defp snap_all([first | rest], placed, config) do
    [first | walk(first, first, rest, placed, config)]
  end

  defp snap_all([], _placed, _config), do: []

  # Left to right, carrying both the boundary already fixed behind us (`prev`,
  # possibly moved) and where that boundary originally sat (`was`). Both are
  # needed: `prev` is what monotonicity is measured against, `was` is what the
  # word's original duration is measured against — and a word that was already
  # shorter than the minimum must not become a reason to refuse every snap.
  #
  # The last boundary is the end of the speech and is never moved, for the same
  # reason the first is not: it is a span edge, which was quiet to begin with.
  defp walk(prev, was, [boundary, next | rest], placed, config) do
    moved = snap_one(boundary, prev, was, next, placed, config)
    [moved | walk(moved, boundary, [next | rest], placed, config)]
  end

  defp walk(_prev, _was, [last], _placed, _config), do: [last]
  defp walk(_prev, _was, [], _placed, _config), do: []

  # One boundary, and the four invariants as one interval it has to land in.
  #
  # Everything here is in virtual milliseconds, and the window is clipped to the
  # single span the boundary sits inside — which is what makes that legitimate:
  # within one span the virtual and real clocks differ by a constant offset, so a
  # 40 ms window is 40 ms on both, and a position inside the span is real speech
  # on both. A boundary that is not strictly inside a span is already sitting on
  # a span join, which is a real silence edge; leave it there.
  defp snap_one(boundary, prev, was, next, placed, config) do
    with span when is_map(span) <- containing_span(placed, boundary),
         lo = lower_bound(boundary, prev, was, span, config),
         hi = upper_bound(boundary, next, span, config),
         true <- lo <= hi,
         offset = span.start_ms - span.v0,
         origin = boundary + offset,
         [_ | _] = candidates <- window(config.frames, lo + offset, hi + offset),
         {centre, rms} = quietest(candidates, origin),
         # Strictly quieter than where it already is, or it does not move. This
         # is what makes a featureless profile a no-op instead of a 5 ms shuffle:
         # with every frame equally loud the boundary would otherwise slide to
         # the nearest frame centre for no acoustic reason at all, half a hop at
         # a time, at every boundary in the paragraph.
         true <- rms < loudness_at(config.frames, origin) do
      centre - offset
    else
      _no_room_or_nowhere_quieter -> boundary
    end
  end

  # Bounded below by the window, by the boundary behind it plus whatever the word
  # between them is entitled to keep, and by the span's own start.
  defp lower_bound(boundary, prev, was, span, config) do
    boundary
    |> Kernel.-(config.window)
    |> max(prev + keep(boundary - was, config))
    |> max(span.v0)
  end

  # And above by the window, by the boundary ahead of it less what the word
  # between them keeps, and by the span's own end. `next` is the *unsnapped*
  # boundary ahead, which is what makes this safe to evaluate left to right: the
  # boundary ahead is then guaranteed a legal position of its own, because
  # staying put is always one.
  defp upper_bound(boundary, next, span, config) do
    boundary
    |> Kernel.+(config.window)
    |> min(next - keep(next - boundary, config))
    |> min(span.v1)
  end

  # A word keeps the minimum, or all of what it had if that was already less.
  # Stated this way the rule can only ever refuse to shorten a word; it can never
  # demand that a 30 ms word be grown to 50, which would be this function
  # inventing audio rather than declining to destroy it.
  defp keep(duration, config), do: min(config.min_word, duration)

  # The frames whose centres fall in the window, in time order. `Enum.filter/2`
  # over every frame per boundary is O(words x frames) — at corpus scale (a
  # 30-second voicemail is 3000 frames, a paragraph is tens of words) that is
  # nothing, and this is the line to turn into a merge walk if it ever is not.
  defp window(frames, from_ms, to_ms) do
    Enum.filter(frames, fn {centre, _rms} -> centre >= from_ms and centre <= to_ms end)
  end

  # The quietest frame; ties broken by distance from where the boundary already
  # was, and a remaining exact tie by the earlier frame (`min_by` keeps the first
  # minimal element and the frames are in time order).
  #
  # The tie-break is not fussiness. Silence digitised by a carrier that gates it
  # produces runs of *identical* RMS, and any tie-break that is not "nearest"
  # moves every one of those boundaries the same direction by up to the whole
  # window — a systematic drift applied at every boundary in the paragraph, which
  # is the same shape of defect this function exists to remove.
  defp quietest(candidates, origin_ms) do
    Enum.min_by(candidates, fn {centre, rms} -> {rms, abs(centre - origin_ms)} end)
  end

  # How loud it is where the boundary already sits — read off the nearest frame
  # centre, which is at most half a hop (5 ms) away. Deliberately searched over
  # every frame rather than over the window: if the nearest frame is one the
  # bounds excluded, the honest answer is still "this is how loud it is here",
  # and the boundary declining to move is the right outcome.
  defp loudness_at(frames, origin_ms) do
    {_centre, rms} = Enum.min_by(frames, fn {centre, _rms} -> abs(centre - origin_ms) end)
    rms
  end

  # Strictly inside, so a boundary already sitting on a span join belongs to
  # neither and is left alone.
  defp containing_span(placed, boundary) do
    Enum.find(placed, fn span -> boundary > span.v0 and boundary < span.v1 end)
  end

  # ---------------------------------------------------------------------------
  # Confidence
  # ---------------------------------------------------------------------------

  # A Gaussian in the log of (allotted / expected), scaled by how much of its
  # allotment a boundary-clamped word kept. See the moduledoc for the scale and
  # for why the expectation is absolute rather than derived from this recording.
  #
  # `syllables` arrives already multiplied by the token's function-word
  # reduction, so a word this module deliberately shortened is judged against the
  # duration this module believes it should have — the one place a weight is
  # allowed to feed back into the score.
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

  # 1.0 is the identity, so "switched off" and "no function words in this
  # transcript" are the same computation rather than two code paths. A multiplier
  # above 1.0 is refused rather than honoured: it would mean lengthening function
  # words, which no reading of this option supports and which is far more likely
  # to be a typo than an intention.
  defp function_word_scale(opts) do
    if Keyword.get(opts, :reduce_function_words, true) == false do
      1.0
    else
      case Keyword.get(opts, :function_word_scale, @function_word_scale) do
        value when is_number(value) and value > 0 and value <= 1 -> value * 1.0
        _invalid -> @function_word_scale
      end
    end
  end

  # Every reason not to snap resolved once, here, into `:off`.
  @spec snap_config(keyword()) :: snap()
  defp snap_config(opts) do
    window = positive_ms(opts, :snap_window_ms, @snap_window_ms)
    wanted? = Keyword.get(opts, :snap_to_energy, true) != false

    case wanted? and window > 0.0 and frame_centres(Keyword.get(opts, :energy)) do
      [_ | _] = frames ->
        %{frames: frames, window: window, min_word: positive_ms(opts, :min_word_ms, @min_word_ms)}

      _off ->
        :off
    end
  end

  # Read a `Cutup.Vad` profile down to the only two numbers this needs, taking
  # them **from the frames themselves**. `:frame_count`, `:duration_ms` and
  # `:hop_ms` are deliberately not consulted: they are summaries, a summary can
  # disagree with the list it summarises (a hand-built profile, a truncated one,
  # a profile for different audio), and a boundary placed from a number that
  # disagrees with the measurements is worse than a boundary not moved at all.
  # A frame that does not carry the measurements is dropped, not defaulted.
  #
  # The centre, not the start: the RMS is the energy over the frame's whole
  # 25 ms, and the midpoint is the only instant that honestly represents it.
  defp frame_centres(%{frames: frames}) when is_list(frames) do
    frames
    |> Enum.flat_map(fn
      %{start_ms: from, end_ms: to, rms: rms}
      when is_number(from) and is_number(to) and is_number(rms) and to >= from ->
        [{(from + to) / 2.0, rms * 1.0}]

      _unmeasured ->
        []
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp frame_centres(_not_a_profile), do: []

  defp positive_ms(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_number(value) and value >= 0 -> value * 1.0
      _invalid -> default
    end
  end
end
