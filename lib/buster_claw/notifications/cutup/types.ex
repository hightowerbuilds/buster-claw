defmodule BusterClaw.Notifications.Cutup.Types do
  @moduledoc """
  The shared data contract for the cut-up pipeline — finding words inside audio
  and splicing them back together into ramshackle sentences.
  **This module is types and documentation only; it holds no logic.**

  The name is the art-historical one: a cut-up is text or tape sliced apart and
  reassembled out of order. That is literally what this does.

  ## The pipeline

      audio file
        └─ (a recognizer, or a hand-authored fixture) → t:index/0
        └─ Cutup.Index.save/1 · load/1 · search/2       → [t:hit/0]
        └─ Cutup.Assemble.build/2                        → a SoundStudio clip
        └─ SoundStudio.write/2                           → a new file

  Separately, and needing no recognizer at all:

      Cutup.Transcripts.search/2 → [t:transcript_hit/0]

  And the signal layer that fills an index without any external recogniser
  (Part III) — query-by-example, not transcription:

      PCM16 clip
        └─ Cutup.Signal.frames/2   → [t:frame/0]     (pre-emphasis, window, hop)
        └─ Cutup.Signal.spectrum/1 → t:spectrum/0    (FFT magnitudes)
        └─ Cutup.Mfcc.features/2   → t:features/0    (mel → log → DCT)
        └─ Cutup.Dtw.search/3      → [t:match/0]     (template vs recording)
        └─ Cutup.Vad.spans/2       → [t:span/0]      (energy + ZCR)

  And the bootstrap that fills an index with no recogniser at all — a transcript
  plus the spans it must fit into:

      Cutup.Align.align/3 :: (transcript, [t:span/0], opts) → [t:word/0]

  **`Align` is the crude one, and it is supposed to be.** It exists because
  query-by-example needs a seed: DTW can find every other take of a word, but
  only once it has been given one. `Align` produces that first pass from text we
  already have, so a corpus can be bootstrapped without anyone marking words by
  ear. Its output is expected to be replaced, word by word, as better timings
  arrive — which is exactly why `t:index/0` carries `origin` and `confidence`.

  ## The analysis frame is fixed, and everything depends on it

  **25 ms frames at a 10 ms hop.** Those are the standard values and they are
  pinned here rather than passed around, because a template extracted at one hop
  and a recording analysed at another cannot be compared at all — the frame index
  IS the clock, and `frame_index * hop_ms` is the only thing converting features
  back to a splice point. Changing either number invalidates every stored index.

  ## Why the index is a contract and not an implementation detail

  A `t:index/0` does not care where its timings came from. A speech recognizer
  produces one; so does a hand-written test fixture, an imported file, or some
  future aligner. **That independence is the whole point of the staging** — the
  assembly engine is provable end to end before any transcription exists in the
  codebase, so the risky, permission-carrying, platform-specific part lands last
  and lands into something already known to work.

  ## The unit is milliseconds, and the source is a basename

  Times are floats in milliseconds from the start of the source, matching
  `SoundStudio.splice/3` and `duration_ms/1`. A `source` is a **basename** inside
  the Studio's sources directory — never an absolute path, so an index is
  portable between workspaces and a malicious index cannot name `/etc/passwd`.
  Resolution to a real path goes through the Studio's existing allowlist.
  """

  @typedoc """
  One recognized word, located in its source.

  `word` is the **normalized** form used for matching — lowercased, punctuation
  stripped — and `text` is what was actually recognized, kept for display. They
  are separate fields because "Harbor," and "harbor" must match each other while
  still rendering the way the speaker said it.

  `confidence` is 0.0–1.0. Recognizers disagree about what it means, so treat it
  as a *ranking* signal rather than a probability: prefer the higher of two
  candidate takes, do not threshold on an absolute value.
  """
  @type word :: %{
          word: String.t(),
          text: String.t(),
          start_ms: float(),
          end_ms: float(),
          confidence: float()
        }

  @typedoc """
  Every word found in one source file, in time order.

  `origin` records how the timings were produced, because their trustworthiness
  differs and a future reader needs to know which they are looking at:

  - `:manual` — hand-authored (a test fixture, or an operator correcting a
    recogniser). Exact by definition, and the only origin `Index.build/3` gives
    a confidence of 1.0.
  - `:aligned` — derived by `Cutup.Align` from a transcript and VAD spans. **No
    recogniser ran**: the word *sequence* is known and the *times* are a guess
    from proportional weighting. Approximate in a specific way worth knowing —
    a transcript error slides every word after it, and function words are
    systematically over-allotted.
  - `:recognizer` — machine transcription, where a recogniser genuinely produced
    the timings. Approximate; see the padding note on `t:cut/0`.
  - `:imported` — carried in from an external tool.
  """
  @type index :: %{
          source: String.t(),
          words: [word()],
          origin: :manual | :aligned | :recognizer | :imported,
          language: String.t() | nil,
          indexed_at: DateTime.t() | nil
        }

  @typedoc "A search result: the word, and which source it was found in."
  @type hit :: %{source: String.t(), word: word()}

  @typedoc """
  One span to cut, as handed to the assembler. Deliberately looser than a
  `t:hit/0` — an operator or an agent may want a span that is not a word.

  **`start_ms`/`end_ms` are the *intended* boundaries, not the sample boundaries
  the assembler will actually cut on.** `Assemble` pads outward from these; see
  `t:assemble_opts/0` for why that padding is not optional polish.
  """
  @type cut :: %{source: String.t(), start_ms: float(), end_ms: float()}

  @typedoc """
  How to assemble a list of cuts.

  - `pad_ms` — extra audio taken **outside** each cut on both sides. Recognizer
    word boundaries are approximate and speech co-articulates: plosives
    (`p`, `t`, `k`) have a silent closure *before* the burst, so cutting exactly
    at a reported boundary removes the consonant onset and the word arrives
    decapitated. Padding is what makes an assembled word sound like the word.
  - `fade_ms` — a micro-fade on each cut's edges. `SoundStudio.splice/3` cuts
    mid-waveform, and `fade/2`'s own docs call a mid-waveform start "the loudest
    click a sound can begin with". **Ramshackle means the seams show, not that
    the seams click** — a click reads as broken, not as style.
  - `gap_ms` — silence inserted between consecutive cuts. Zero runs words
    together; a little gives the sentence its stitched, deliberate rhythm.
  - `normalize` — level each cut before joining. Words taken from different
    callers, rooms and handsets arrive at wildly different levels; without this
    the sentence is unintelligible rather than charmingly rough.
  """
  @type assemble_opts :: [
          pad_ms: float(),
          fade_ms: float(),
          gap_ms: float(),
          normalize: boolean()
        ]

  # ── The signal layer (Part III — our own recogniser) ───────────────────────

  @typedoc """
  One frame of audio: samples normalised to roughly -1.0..1.0.

  Normalising at the framing boundary rather than carrying PCM16 integers means
  every stage downstream is scale-free, so a quiet recording and a loud one
  produce comparable features without anyone remembering to divide.
  """
  @type frame :: [float()]

  @typedoc """
  A magnitude spectrum — the output of the FFT stage, one value per frequency
  bin, length `fft_size / 2 + 1` (DC through Nyquist inclusive).

  Magnitudes, not complex pairs: nothing downstream of the FFT needs phase.
  Discarding it at the boundary keeps the seam narrow and halves what the MFCC
  stage has to reason about.

  **MAGNITUDE — `sqrt(re² + im²)` — not power, not power in dB.** The MFCC stage
  squares these itself, per the conventional definition. This distinction has no
  visible failure mode, which is exactly why it is pinned here: if the FFT ever
  returned power instead, every log-domain feature would shift by a constant
  factor *uniformly*, so nothing would look broken — but a template stored under
  one convention would stop being comparable to a recording analysed under the
  other, and the only symptom would be matches quietly getting worse.
  """
  @type spectrum :: [float()]

  @typedoc """
  A feature vector for one frame — 13 MFCCs by convention.

  This is the unit DTW compares. **It is deliberately opaque to the matcher**: as
  far as `Dtw` is concerned this is a point in N-space with a distance function,
  so the feature extractor can be changed (more coefficients, deltas, a different
  filterbank) without touching the matcher at all.
  """
  @type features :: [float()]

  @typedoc """
  A time-ordered sequence of feature vectors — a whole recording, or a template
  cut out of one. Frame `i` starts at `i * hop_ms`.

  ## Normalise the recording, THEN cut the template out

  Cepstral mean normalisation is what makes two phone calls comparable — it
  subtracts the channel's constant colouring, so the distance reflects which word
  was said rather than which handset said it. But the mean must be taken over a
  **whole recording**, not over a template.

  Over a two-word snippet the mean is substantially the speech itself, so
  normalising it subtracts the signal along with the channel. The template and
  the target then sit in different spaces and every distance is wrong — with no
  error, no crash, and no symptom except results that are quietly poor.

  So the order is: analyse the full recording → CMN the full sequence → slice the
  template out of the normalised sequence. Both sides of a comparison must have
  been normalised the same way. This is the easiest thing in the pipeline to get
  backwards, which is why it is written on the type rather than in one module.

  **CMN belongs to the feature stage — apply it once.** `Cutup.Mfcc.cmn/1` is the
  intended home. `Cutup.Dtw` also offers it as an opt-in (default off) for callers
  holding features that were never normalised; **do not enable both.** Applying it
  twice subtracts an already-zero mean over a *different* window and quietly
  changes the score's scale, so a threshold tuned under one arrangement does not
  transfer to the other — with, as usual in this pipeline, no error to notice.
  """
  @type feature_seq :: [features()]

  @typedoc """
  A DTW match: where in the target a template was found, and how badly it fits.

  `distance` is the **length-normalised** warped distance (total cost divided by
  path length). Un-normalised, a long template always scores worse than a short
  one and no single threshold can work across words of different lengths — which
  is the trap that makes a naive DTW keyword spotter useless in practice.

  Lower is better. There is no natural scale: the threshold has to be tuned
  against a real corpus, and the roadmap warns that tuning it may cost as long as
  writing the matcher did.
  """
  @type match :: %{
          start_frame: non_neg_integer(),
          end_frame: non_neg_integer(),
          start_ms: float(),
          end_ms: float(),
          distance: float()
        }

  @typedoc """
  A span of speech (or of anything above the noise floor), as found by voice
  activity detection. `frames` is how many analysis frames it spans, kept so a
  caller can reject spans too short to be a word without recomputing.
  """
  @type span :: %{start_ms: float(), end_ms: float(), frames: pos_integer()}

  # ── Selection (Part IV — which take of a word to use) ──────────────────────

  @typedoc """
  One candidate for one word slot: a hit, plus everything needed to cost it.

  `features` is the source's feature sequence, injected rather than loaded, so
  the selector stays pure and testable while `Cutup.Features` owns the IO and
  the cache. `frame0` is the index of the frame the candidate starts at, which
  is how a caller slices `features` to reach the seam.
  """
  @type candidate :: %{
          source: String.t(),
          word: word(),
          frame0: non_neg_integer(),
          frame1: non_neg_integer()
        }

  @typedoc """
  What it costs to use a candidate in a slot, ignoring its neighbours.

  Unit-selection's *target cost*. Every term is already computable from what
  exists: alignment `confidence`, duration against a syllable expectation, how
  quiet the audio is at the cut boundaries (`Vad.energy_profile/2`), and how far
  the candidate sits from other takes of the same word (`Dtw.distance/3`).

  **A high-variance term must not silently dominate.** Terms are normalised
  before weighting, or the weights mean nothing.
  """
  @type target_cost :: %{
          confidence: float(),
          duration: float(),
          boundary: float(),
          typicality: float(),
          total: float()
        }

  @typedoc """
  What it costs to splice one candidate onto the next.

  Unit-selection's *join cost*, and the standard formulation is **cepstral
  distance across the seam** — compare the last frames of A against the first
  frames of B. We already compute MFCCs, so this is arithmetic over data we have.
  A level term rides alongside it because `normalize/2` equalises peaks rather
  than loudness, and a level jump at a seam is audible even when the spectrum
  matches.
  """
  @type join_cost :: %{spectral: float(), level: float(), total: float()}

  @typedoc """
  A transcript search result — Phase B, and the half that needs no recognizer.

  Telephony events already carry a Twilio `transcript` and a local
  `recording_path`, so this finds *which recording says a thing* and where its
  audio lives. It carries **no timings**, which is exactly the boundary: this is
  discovery, not cutting. `excerpt` is the surrounding text so a person can judge
  the hit without listening.
  """
  @type transcript_hit :: %{
          event_id: integer(),
          recording_path: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          from_number: String.t() | nil,
          excerpt: String.t(),
          match_count: non_neg_integer()
        }
end
