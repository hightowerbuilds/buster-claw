---
name: sound-cutup
description: Playbook for cutting words out of recorded speech and splicing them into a sentence nobody said — the sound_* verbs in the order they have to be used, what the timings are actually worth, and how to report a result you cannot hear.
tier: safe
enabled: true
handler_kind: reference
---

# sound-cutup

A **reference** skill: read this, then use the `sound_*` commands to build a
*ramshackle sentence* — words cut out of recordings the operator already has,
spliced into something none of them said. Run each verb through the CLI:

    ./buster-claw run sound_corpus --json '{}'

No verb in this workflow installs a chime or routes a key. Every write lands in
`sounds/studio/` as a new source; making the machine actually play it is a
separate, deliberate act that this skill does not cover.

## Three constraints, before any verb

1. **You cannot hear what you made.** There are no ears on this path. Report
   `duration_ms`, `peak`, the cut count and which sources the words came from,
   then **ask the operator to listen**. Never say a sentence sounds good,
   sounds clean, or came out well — you do not know, and claiming it is the one
   failure that wastes the operator's time twice.
2. **The timings are a guess, not a measurement.** `sound_align` runs **no
   recogniser**. Voice-activity detection finds where sound happens; the
   transcript's words are shared out across those spans by syllable count,
   assuming a constant speech rate — which people do not have. That is what
   `origin: aligned` means, and why confidence there tops out at **0.9**: 1.0 is
   reserved for hand-marked timings, so `min_confidence: 0.95` asks for those
   alone.
3. **A transcript error slides every word after it.** The whole transcript
   shares one timeline, so a dropped or invented word mistimes the entire
   remainder — not just itself. This corpus is Twilio telephony transcription,
   which renders "Buster Claw" as *"bus o'clock"*; that is why `bus` and
   `oclock` sit in the vocabulary on audio that says neither. Correcting the
   text and re-running with `overwrite: true` is the cheapest improvement
   available anywhere in this feature.

## The workflow, in order

Each step depends on the one above it. Skipping one produces a confident,
broken result rather than an error.

1. **Find which recordings say the word.** `sound_transcript_search` searches
   the transcripts voicemails already carry — an excerpt and where the audio
   lives, and **no timings**. This is discovery, not cutting.
   `sound_transcript_words` lists the corpus vocabulary with counts (a *floor*,
   not a census — real takes hide under misrecognitions). If a search comes
   back empty, run `sound_corpus` before concluding anything: `recordings_on_disk:
   0` means the audio lives in another workspace, not that the word is absent.
2. **Bring the audio in.** `sound_import` with the `event_id` from step 1 (or a
   path relative to the Library root; absolute paths and `..` are refused).
   It writes a WAV in the Studio's internal format and **reports the stored
   name** — use exactly that name in every later verb.
3. **Give the source word timings.** `sound_align` with the same `event_id`
   (its transcript comes from the event; pass `transcript` to correct what the
   transcriber mangled), or `source` plus an explicit `transcript`. It never
   imports: an un-imported source is refused as `not_imported`, naming the
   basename to import. It refuses an existing index unless `overwrite: true`.
   Without an index a source cannot be cut from, however good its transcript is
   — `sound_index_list` says which sources have one.
4. **Find the takes.** `sound_index_search` returns hits best-confidence first,
   each carrying `source`, `start_ms`, `end_ms`. **A hit's shape is already a
   cut** — hand it straight to the assembler. `sound_index_words` answers the
   prior question: which words are indexed and *how many takes* of each exist.
5. **Splice.** `sound_assemble` takes the cuts in the order you want them
   spoken plus a `name`, and writes one new source.

## Reading the numbers, since you cannot listen

- **`confidence` is a whole-recording plausibility figure, not a per-word
  verdict.** Every word is scored against the same absolute expectation of
  ~200 ms per syllable, so under the default weighting the min/median/max are
  usually one number three times. **A flat spread is normal and means nothing.**
  A *low value* is the signal: it means the transcript does not fit the audio at
  any rate people speak at — a hallucinated tail or a truncated line. Use
  confidence to rank candidate takes; do not read it as a probability.
- **`unplaced_ms`** is detected speech no word covers: audio trimmed off words
  that straddled a span boundary. Those words are fragments.
- **`words` well under `transcript_words`**, or fewer words than `spans`, means
  the audio holds activity the transcript does not account for. Everything after
  the gap is mistimed.
- **Function words are the least reliable and the most available.** `to`, `the`,
  `of`, `you` dominate the corpus and are exactly the tokens whose duration the
  model guesses worst — in real speech they run under 80 ms while the model
  hands them a full syllable's share. Prefer content words when the sentence
  allows it.
- `sound_probe` is the only other substitute for ears: format, duration, peak.
  On a non-WAV file it reports no peak unless you pass `decode: true`.

## Assembly defaults, and what moving them does

`pad_ms: 30`, `fade_ms: 8`, `gap_ms: 60`, `normalize: true`.

- **`pad_ms`** — cuts outward past the reported boundary, because boundaries lie
  and a plosive's closure sits *before* its burst. Lower it and words arrive
  decapitated; past ~50 ms you reliably drag the neighbouring word's vowel in
  with every cut. That is a cost of the technique, not a bug.
- **`fade_ms`** — the micro-ramp that stops the seam clicking. **Keep it well
  below `pad_ms`**: a fade longer than the padding eats into the word's onset,
  which is the decapitation the padding existed to prevent.
- **`gap_ms`** — under ~40 ms the words slur together; at 150 ms and up it reads
  as someone dictating a word list. Ramshackle means the seams show, not that
  the pacing is broken.
- **`normalize`** — words from different callers, rooms and handsets arrive tens
  of dB apart. Off, the sentence is not charmingly rough, it is unintelligible.
  It equalizes *peaks*, not loudness, so a breathy word still sits quieter than
  a shouted one.

## A worked example

Build "call me tomorrow" out of two voicemails.

    # 1. Is there anything to cut at all?
    ./buster-claw run sound_corpus --json '{}'
    #    → events: 34, recordings_on_disk: 31

    # 2. Who says "tomorrow"? (excerpts + event ids, no timings)
    ./buster-claw run sound_transcript_search --json '{"query":"tomorrow"}'
    #    → hit: event_id 41, "...give me a call tomorrow if you can..."

    # 3. Bring that recording in; note the stored name it reports.
    ./buster-claw run sound_import --json '{"event_id":41}'
    #    → name: "voicemail-41.wav"

    # 4. Time its words. The transcript said "bus o'clock" for "Buster Claw",
    #    so hand it a corrected line — a wrong word slides every word after it.
    ./buster-claw run sound_align --json '{"event_id":41,
      "transcript":"hey it is Dana give me a call tomorrow if you can thanks"}'
    #    → words: 13, spans: 4, unplaced_ms: 210,
    #      confidence: {min: 0.61, median: 0.9, max: 0.9}, origin: "aligned"

    # 5. Do the words I need exist, and how many takes of each?
    ./buster-claw run sound_index_words --json '{"word":"call"}'   # → takes: 3
    ./buster-claw run sound_index_words --json '{"word":"tomorrow"}' # → takes: 1

    # 6. Turn each into a cut, best confidence first.
    ./buster-claw run sound_index_search --json '{"query":"call"}'
    #    → {source: "voicemail-17.wav", start_ms: 3120, end_ms: 3480, confidence: 0.9}
    ./buster-claw run sound_index_search --json '{"query":"me"}'
    ./buster-claw run sound_index_search --json '{"query":"tomorrow"}'
    #    → {source: "voicemail-41.wav", start_ms: 5210, end_ms: 5940, confidence: 0.9}

    # 7. Splice them in the order they should be spoken.
    ./buster-claw run sound_assemble --json '{"name":"call-me-tomorrow","cuts":[
      {"source":"voicemail-17.wav","start_ms":3120,"end_ms":3480},
      {"source":"voicemail-17.wav","start_ms":4020,"end_ms":4180},
      {"source":"voicemail-41.wav","start_ms":5210,"end_ms":5940}]}'
    #    → duration_ms: 1370, peak: 0.98, cuts: 3

Then report, in these terms and no stronger:

> Wrote `sounds/studio/call-me-tomorrow.wav` — 3 cuts, 1.37 s, peak 0.98.
> "call" and "me" came from voicemail-17, "tomorrow" from voicemail-41; the
> timings are aligned guesses, not measurements, and "tomorrow" had only one
> take. **Please listen and tell me which word is wrong** — I can re-cut any
> single word, or re-align voicemail-41 with a corrected transcript.

## When not to reach for this

- **Check the words exist before assembling.** `sound_index_words` is the whole
  question: a sentence needs every one of its words present *with usable takes*.
  Asking first is the difference between a good result and a confidently broken
  one — a missing word silently becomes a shorter sentence, and a word with one
  take is a quotation, not a cut-up.
- **A word absent from the transcripts may still be in the audio.** Report "no
  transcript contains X", never "you have no takes of X". A recurring nonsense
  word is usually a real word the transcriber keeps missing — searching *for the
  nonsense* is often how you find the take.
- **Non-speech is out of scope.** There is no sound classifier here: "find the
  door slam" cannot be answered. Words only.
- **Don't propose a recogniser.** Whisper is demolished and the decision stands;
  do not re-propose it. Better timings arrive by hand-correcting an index
  (`sound_index_import` with `origin: "manual"`, which is the only origin that
  earns confidence 1.0), not by adding a model.
- **If the operator wants the result to play on an event**, say plainly that
  assembly writes a source only. Installing and routing a sound is a different
  act with its own verbs and its own confirmation; check the live catalog rather
  than assuming from this file.
