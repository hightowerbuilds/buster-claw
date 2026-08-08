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
    recognizer). Exact by definition.
  - `:recognizer` — machine transcription. Approximate; see the padding note on
    `t:cut/0`.
  - `:imported` — carried in from an external tool.
  """
  @type index :: %{
          source: String.t(),
          words: [word()],
          origin: :manual | :recognizer | :imported,
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
