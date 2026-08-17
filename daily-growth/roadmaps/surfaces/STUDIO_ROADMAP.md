# The Studio — giving the agent a room it can enter

**Scoped 08-08-26 · Status: PARTS I, II, III and IV SHIPPED 08-08-26. Parts V and
VI remain, and both need a person rather than an agent.**

> **Parts V and VI were rewritten 08-09-26**, folding in three documents written
> that day — a microphone plan, a word-dictionary brief, and a legal survey of
> sourcing words from YouTube. All three are retired; this is the only Studio map.
>
> **They agreed, three independent ways, on one action: record the operator's own
> voice.** The engineering line (Part V already said so), the measurement line (a
> sentence built on 08-09 scored 3/10 because two of its seven words exist in no
> transcript), and the legal line (a four-layer survey concluded scraping is not a
> clean path and landed on "record 30–60 minutes of phonetically balanced
> sentences" *on the merits*). See **V.0**.
>
> **Part V** is now the corpus and how to capture it — nothing in this app records
> audio today, and the reason that matters is a process-boundary fact, not a UI
> gap (**V.3**). **Part VI** is the dictionary: the Studio can cut, align, match
> and choose, but **it cannot listen**, and that single gap explains every
> remaining quality problem (**VI.0**). The labelling session that used to be all
> of Part VI is now **VI.4**, because three more valuable things come first.
>
> **Sequence by risk, not by value:** Part V is gated on an unknown
> (`getUserMedia` inside WKWebView) and a notarization-affecting entitlement
> change; the dictionary has **no blockers at all.** Spike **V.4a** on day one,
> then build **VI.1** while the packaging clears.

**Shipped:** **24 `sound_*` verbs** (the catalog went 162 → 191 across the day,
including other sessions' work), the word-index contract, the assembly engine,
transcript search, a complete pure-Elixir recogniser (framing, FFT, MFCC,
subsequence DTW, VAD, feature cache), proportional alignment, a unit-selection
lattice, and a reference skill that teaches the lot. **3,112 tests green.**

**The acceptance criterion is met.** *"A voicemail becomes a routed sound effect
end to end, from the CLI alone, with no UI involved"* — carried unmet since
08-02 — now has a test that walks it entirely through `Commands.call/3` by name,
plus a second proving `sound_apply` is genuinely gated when untrusted.

**And it made a sentence.** Twenty-four words spliced out of six different
voicemails, a sentence nobody ever said. The operator's first verdict was
"garbled"; two targeted fixes to `Align` later, "both sounds better".

**What remains needs a person, not an agent:** Part V wants a donor recording,
and Part VI wants a listening surface. Neither is a gap in the plan.

**What this is, in one line:** a `sound_*` command surface so the Studio's
cutting, arranging and routing are reachable by the agent, not only by a person
with a mouse.

**Why now.** Every other authoring surface in this product is agent-addressable.
The Studio is the one room the agent cannot enter, so *"turn that voicemail into
my notification chime"* is a thing the app can do and the assistant cannot. This
was `SOUND_STUDIO_ROADMAP`'s Phase 2, never built, and has sat in `LEFTOVERS_AGENT_CORE.md`
since 08-02 with the honest note that it *"doesn't get expensive; it stays
absent, which is the actual cost."*

**How the parts relate.** **I** is the command surface — the substrate
everything else is reached through. **II** is the cut-up feature itself. **III**
is the recogniser that fills its index, built here rather than bought. **IV**
chooses *which take* of a word to use, which is most of the quality and is
currently nobody's job. **V** grows the corpus, because every problem downstream
is partly a corpus problem. **VI** is the labelling loop that tunes IV to the
operator's ear. **VII** is open space.

**The honest dependency:** IV, V and VI compound. A lattice search cannot help
when a slot has one candidate (V fixes that), and weights cannot be fitted
without labels (VI produces them). **V is the cheapest and lifts everything**,
including Part III — a donor recording has known text and clean audio, which
removes `Align`'s two worst failure modes outright.

---

## The lay of the land (read before building)

**The DSP is already built, tested, and pure.** `Notifications.SoundStudio`
(725 lines) is a complete WAV toolkit: `parse/1`, `read/1`, `render/1`,
`write/2`, `splice/3`, `fade/2`, `normalize/2`, `mixdown/1`, `concat/1`,
`probe/1`, `import_source/1`, `peak/1`, `duration_ms/1`. **None of it needs
writing.** This roadmap is almost entirely about *addressing* — naming things
the agent can act on — not about audio.

**There are three durable artifact stores, all workspace-relative:**

| Store | Path | Module |
|---|---|---|
| Routed sound library | `sounds/` | `Notifications.Sound` |
| Studio sources (imported clips) | `sounds/studio/` | `Notifications.SoundStudio` |
| Saved mixes | `sounds/studio/mixes/` | `Notifications.StudioMix` |

**Mixes are persisted and addressable by name** — `StudioMix.list/0`, `load/1`,
`save/1`, `delete/1`, with a `migrate_v1/0` already in place. This is the single
fact that makes a CLI tractable, and it was not true when the Phase 2 entry was
written.

**But the GUI's *working* state is deliberately not addressable.** `:studio_source`,
`:studio_trim`, `:studio_clip`, `:studio_clipboard`, `:studio_undo` and
`:studio_redo` live in **`StudioLive`** assigns, held there because the tab's `:if`
discards the component on every tab switch. *(They were `StatusLive`'s until
08-16, when the Studio became its own route and took them with it. The reason
they live in a LiveView rather than the component never changed.)* **There is no "currently open mix"
the agent can reach, and there should not be.** See decision 1.

**The command surface has a fixed shape, in four places.** A verb is: an entry in
`commands/catalog/<area>.ex` (name, type, tier, description, args), that module
appended in `commands/catalog.ex`, a handler function in
`commands/<area>.ex`, and a `defdelegate` in `commands.ex` (~:486).
`Commands.call/3` (`commands.ex:112`) dispatches by name. `catalog/notify.ex` (49
lines) is the cleanest small example to copy.

**The catalog is under contract test.** The Explore tutorial's counts are guarded
against the live catalog, and the count moved 165 → 162 when the trading stack
went. **Adding verbs will move it again** — expect to update that test, and treat
a surprise there as the test doing its job.

**`Sound.route_keys/0` is the validation source** for where a sound can be routed.
A typo'd key must be refused at the verb, not written and discovered later when
something fails to chime.

**Audio names are already normalised centrally** — `BusterClaw.AudioName` exists
precisely because Sound, the Studio and StudioMix all share the problem. Use it;
do not write a fourth normaliser.

---

## Decisions taken while scoping (revisit if wrong)

1. **The CLI operates on FILES, never on "what the GUI has open."** The agent's
   unit of work is a named source, a named mix, a named library sound. It cannot
   read or drive the operator's in-progress edit, undo stack or selection.

   This is not a limitation to route around later — it is the design. The GUI
   state is ephemeral by construction, single-socket, and discarded on tab
   switch; an agent verb that mutated it would be acting on something the
   operator is holding, with no undo they authored. **A CLI that renders to a new
   file is reviewable; one that reaches into a live editor is not.**

2. **Reads are `:safe`; anything that writes the library is `:restricted`.**
   Straight from the archived roadmap, and the reason is specific: a sound
   effect is a file **the app will later play unattended**. Writing one is not
   like writing a note.

3. **No verb deletes an operator's source or mix without it being its own verb.**
   `sound_delete` exists and is `:restricted`; no edit verb silently overwrites
   its input. Edits render to a new name by default.

4. **`sound_apply` — the route-a-key step — is the one gated verb.** Routing
   changes what the machine does when nobody is watching. It is the difference
   between "the agent made me a sound" and "the agent changed what my computer
   does at 3am."

5. **Reuse `AudioName` and `Sound.route_keys/0` for validation; do not invent a
   second vocabulary.** The GUI and the CLI must agree on what a legal name and
   a legal route are, or the two surfaces will drift and the drift will be found
   by a chime that does not play.

---

## Open question — does the agent get a *mix* editor, or only a clip editor?

Two coherent scopes, and the difference is roughly double the verbs:

- **Clip-level only** (`sound_import`, `sound_trim`, `sound_fade`,
  `sound_normalize`, `sound_concat`, `sound_apply`, `sound_list`,
  `sound_delete`). Covers the acceptance case — voicemail → routed chime — end
  to end, and every verb maps to one existing pure function.
- **Plus mix-level** (`mix_list`, `mix_create`, `mix_add_clip`, `mix_render`,
  `mix_delete`). `StudioMix` already persists, so this is reachable — but a
  multi-track arrangement authored blind, without hearing it, is a much weaker
  proposition than a single clip edit.

**Proposed: clip-level in Phase 1, mix-level gated on Phase 1 being used.** The
agent cannot hear. Clip edits are verifiable from metadata it *can* read
(duration, peak, format); an arrangement's quality is not. **Decide before Phase
2, from whether the clip verbs actually get used.**

---

# Part I — The command surface

# Phase 0 — The read half

***SHIPPED 08-08-26** (`e1088c2`). Four `:safe` verbs, catalog 162 → 166.*

> **What shipping it taught, kept because Phase 1 depends on it:** `sound_probe`
> is degraded on exactly the input the acceptance walk starts from. Three of its
> four facts (`peak`, `duration_ms`, `internal?`) need a *parsed* clip, and an
> mp3 voicemail cannot be parsed without decoding — so it returns header data
> from `afinfo` and **no peak at all**. The agent therefore cannot tell how loud
> a voicemail is before importing it, and level is one of the two things that
> decides whether an assembled sentence is intelligible. **Phase 1 should add
> decode-on-demand probing**, not paper over it.

- [x] `commands/catalog/sound.ex` + `commands/sound.ex`, registered in
  `catalog.ex` and delegated from `commands.ex`.
- [x] `sound_list` — the library, **both layers, showing which wins**. Bundled
  defaults and workspace files share a namespace and the workspace shadows the
  bundle; a listing that hides that is how "I replaced the chime and nothing
  changed" happens.
- [x] `sound_routes` — the routing table: every key from `Sound.route_keys/0`,
  its human label, and what is currently routed to it. This is the map the agent
  needs before it can sensibly propose a change.
- [x] `sound_sources` — the Studio's imported clips (`sounds/studio/`).
- [x] `sound_probe` — format, duration, peak, and whether a file is already in
  the studio's internal format. Wraps `probe/1` + `peak/1` + `duration_ms/1`.
  **This is the agent's only substitute for ears** and it is the reason the read
  half ships first.
- [x] Tests: every verb against a tmp workspace; the shadowing case is asserted
  explicitly; a nonexistent name returns a named error rather than raising.

**Done when:** the agent can describe the sound library completely and correctly
without touching anything.

# Phase 1 — The write half, clip-level

- [x] **`sound_import` — SHIPPED 08-08-26.** By `event_id` (the acceptance path)
  or a Library-root-relative path, never an absolute one. Two independent
  guards: a segment scan before the filesystem is touched at all, then
  containment on the expanded path. Thirteen traversal shapes tested to their
  exact named errors. **Measured on the real corpus: a 54.5 s voicemail imports
  end to end in 224 ms.**
  *Residual gap, disclosed:* containment is lexical, not `realpath`, so a
  symlink **inside** the Library pointing outside it would resolve. Left open
  deliberately — refusing symlinks could break a legitimate layout — and cheap
  to close with `File.lstat/1` if wanted.
- [ ] `sound_trim` — `splice/3`, rendering to a new name.
- [ ] `sound_fade` — `fade/2`.
- [ ] `sound_normalize` — `normalize/2`.
- [ ] `sound_concat` — `concat/1` over a list of named sources.
- [ ] `sound_apply` — write into the library and route a key. **The gated verb**
  (decision 4). Validates against `Sound.route_keys/0`.
- [ ] `sound_delete` — `:restricted`.
- [ ] Update the catalog contract test's counts (they will move).
- [ ] **The acceptance walk, from the CLI alone with no UI involved:** a
  voicemail becomes a routed sound effect end to end — import, trim, normalize,
  apply, and hear it fire. This is the archived roadmap's own acceptance
  criterion and it is the only test that proves the surface is real.

**Done when:** the acceptance walk passes, and the agent can be asked in plain
language to turn a recording into a chime.

# Phase 2 — Teach it

- [ ] The verbs need a **reference skill**, not a longer system prompt — the
  `shader-designer` precedent, and the same argument recorded for the scene3d
  guide in `LEFTOVERS_AGENT_CORE.md`: a system-prompt string is neither runtime-loadable nor
  operator-editable.
- [ ] The skill carries the workflow, not just the verbs: probe before you cut,
  render to a new name, tell the operator what you are about to route *before*
  routing it.
- [ ] Decide the mix-level question above from real usage.

---

# Part II — Ramshackle sentences: cutting speech out of found audio

**The operator's ask (08-08):** a transcriber the model can use to find *words or
sounds* inside audio files, and splice them together across sources to build
sentences. The aesthetic is the name — cut-up, seam-showing, assembled from
whatever was lying around.

## The assembly half is already built

`SoundStudio.splice/3` cuts a span out of a clip. `concat/1` joins clips.
`fade/2` shapes edges. `normalize/2` levels them. **A ramshackle sentence is
`splice` per word, then `concat`** — every function that assembles one already
exists and is tested.

So this feature is not an audio problem. It is an **indexing** problem: knowing
which file says which word, and exactly when.

## The one data structure that matters

    %{word: "harbor", start_ms: 1240, end_ms: 1480,
      confidence: 0.82, source: "voicemail-03.wav"}

A **word index** per source file. Everything else follows: search it to find
candidates, `splice` each hit, `concat` the results. The index is the contract
between "how did we get the timings" and "what do we do with them", and it must
be defined before either half is built — the same contract-first discipline that
made Scene3D's four stages compose.

**Crucially, the index does not care where it came from.** A recognizer produces
one; so could a hand-written fixture, an imported file, or a future aligner. That
independence is what lets the risky part come last.

## Where the timings come from — and why Whisper's grave does not apply

**Do not rebuild on Whisper.** Demolished 06-28 (see that day's summary in
`daily-growth/MM-DD-YY-Summary/06-28-26-summary.md`); the operator reaffirmed it
on 08-08 while this part was being scoped. **No phase below uses it**, and a
future session proposing it should read the post-mortem first rather than
rediscovering the reasoning.

For the record, so the rule is applied to the right thing: the objection was to
**bundling** it — a 142 MB model, a static whisper.cpp/Metal build, a hand-rolled
resampler, and an unproven entitlement gamble on the signing path. A *hosted*
Whisper API shares none of that baggage and is a different proposition
technically. **It is still not proposed here** — the operator's preference is
clear, and a hosted API lands in the same "audio leaves the machine" bucket as
Google Cloud STT without Google's telephony tuning, so it has no advantage to
argue for.

**The reason Whisper became un-iterable does not apply to this feature, and this
is the unlock worth understanding.** That post-mortem's root cause was
environmental: *macOS TCC hands a bare `cargo tauri dev` binary a silent mic*, so
every recording came back `peak=0.0000` and the feature could not be developed
outside a bundled `.app`.

**This feature never touches the microphone.** It transcribes files that already
exist — voicemails, imported sources. `SFSpeechURLRecognitionRequest` takes a
file URL. No mic entitlement, no silent-mic wall, and the dev loop works from a
plain `mix phx.server`. The wall that killed the last attempt is not on this path.

`SFTranscriptionSegment` returns exactly the fields above — `substring`,
`timestamp`, `duration`, `confidence`, `alternativeSubstrings` — which is why the
index shape is what it is.

## Words are not sounds — two mechanisms, named honestly

The ask says "words **or sounds**". These are different problems and only one is
a recognizer's job:

- **Words** — speech recognition, as above.
- **Sounds** — windowed RMS over the PCM: where the silences are, where the
  transients are. **Pure Elixir, no new dependency, buildable today**, and it is
  what supports "cut at the gaps" and "grab that hit". `peak/1` already walks
  samples; this is the same walk with a window.
- **Sound *classification*** — "find the door slam" — needs a model and is **out
  of scope**. Say so in the guide rather than letting the vocabulary imply it.

## Decisions taken while scoping (revisit if wrong)

6. **Word boundaries lie, and padding is not polish — it is the feature
   working.** Recognizer timestamps are approximate and speech co-articulates:
   plosives (`p`, `t`, `k`) have a silent closure *before* the burst, so a cut at
   exactly `timestamp` removes the consonant onset and the word arrives
   decapitated. Every splice pads by a configurable few tens of ms each side.

7. **Every cut gets a micro-fade (~5–10 ms).** `splice/3`'s own moduledoc already
   says a hard start is "the loudest click a sound can make". Ramshackle means
   the seams *show*, not that the seams *click* — a click is a defect that reads
   as broken, not as style.

8. **Per-word normalize, on by default.** Words from different callers, rooms and
   distances land at wildly different levels; without levelling, the sentence is
   unintelligible rather than charmingly rough. `normalize/2` exists.

9. **The index is persisted per source and never silently recomputed.**
   Transcription costs time and (on some paths) permission. Re-running it because
   nobody cached the result is the kind of waste that shows up as "why is this
   slow".

10. **Assembly renders to a new file, always.** Consistent with decision 3 —
    sources are never edited in place.

## Phases — ordered so every risk lands last

**Phase A — the index format and the assembly engine. SHIPPED 08-08-26**
(`e1088c2`). `Cutup.Types` pins the contract; `Cutup.Index` persists and searches;
`Cutup.Assemble` pads, splices, micro-fades, normalises and joins. Proven end to
end against hand-authored fixtures with no transcription in the tree at all —
which is exactly what lets Part III drop in underneath it unchanged.

Two findings from building it, both worth keeping:

- **`mixdown/1` rounds each placement offset from ms independently of clip
  length, so a join drifts a sample per cut** and the total stops being the sum
  of its pieces. `Assemble` uses `concat/1` + explicit silence instead. It is
  also quadratic in this shape, and mixing is not what this does — no two cuts
  ever sound at once.
- **`fade_ms` must stay well below `pad_ms`.** If the ramp is longer than the
  padding it reaches past it into the syllable onset and re-creates the
  decapitation the padding exists to prevent. The two settings are coupled;
  defaults are 30 / 8 / 60 ms with `normalize: true`.

**Phase B — search the transcripts that already exist. SHIPPED 08-08-26**
(`e1088c2`). `Cutup.Transcripts` searches the Twilio `transcript` on
`Telephony.Event` — text without timings, useless for splicing, **genuinely
useful for discovery**. Zero new dependencies.

**It was also the corpus measurement this roadmap was staged around, and here is
the answer:** 10 voicemails, 295 s, 655 tokens, **238 distinct words, 47 with 3+
takes, 30 with 5+**. Thin but real — a sentence can be built today, mostly from
function words (`to` 35, `the` 29, `you` 28, `and` 26, `me` 12, `email` 11,
`need` 11, `morning` 9).

**And it exposed why a better recogniser buys more than timings.** Twilio renders
"Buster Claw" as *"busted class"*, *"buster clark"*, *"bus o'clock"*, *"a butcher
cool and"* — four manglings of one phrase. So the frequency counts are polluted
(`bus` and `o'clock` rank high on wreckage), search misses words you know are
there, and **absence of a hit is weak evidence**. Part III improves discovery,
not only cutting.

**Phase C — an external recogniser. DEFERRED 08-08 in favour of Part III.**

The original plan was `SFSpeechRecognizer` behind a Rust shim (or Google Cloud
STT over HTTP), producing the Phase A index from a file URL. **The operator chose
to build our own instead**, so this phase is not next — but it is not deleted
either, because it buys something Part III explicitly cannot: **text**. A
recogniser can name a word nobody has marked; query-by-example can only find more
of a word you already have an instance of. Those are different capabilities, and
one day the app may want both.

**If it is ever revived, the two live options and their trade-offs:**

| | `SFSpeechRecognizer` | Google Cloud STT |
|---|---|---|
| Word timings | yes | yes (`enableWordTimeOffsets`) |
| Dependency | native shim + entitlement | HTTP; `req` is already a dep |
| Audio leaves the machine | no | **yes** |
| Cost | free | per-minute |
| Telephony tuning | none | a `phone_call` model — **and this corpus is telephony** |
| Apple signing path | **new entitlement** | untouched |

> **And the caution that still applies:** do not land the native option before
> the first notarized build. The Whisper post-mortem names *"an unproven
> notarization/entitlement gamble on the Apple-signing critical path"* among the
> reasons it was cut, and the Apple map is still waiting on **G-2** with
> nothing ever notarized or stapled. Part III is entitlement-free by
> construction, which is a further reason it goes first.

**Not Whisper**, reaffirmed by the operator 08-08. See the note above for why the
rule targets *bundling* rather than the name.

**Phase D — non-speech: onset and silence detection.** Windowed RMS in pure
Elixir. Serves "or sounds", needs no permission, and is independently useful for
trimming leading silence off any clip. **Subsumed by Part III below**, which needs
the same framing layer.

---

# Part III — Our own recogniser, honestly scoped

**Operator ask (08-08): build our own, lean on Elixir and the BEAM, best effort.**

## The boundary, stated first

**Open-vocabulary speech-to-text is not buildable here, and that is a property of
the problem rather than of our ambition.** Modern ASR is a trained acoustic model:
thousands of hours of labelled audio, GPU-weeks, and a training pipeline nobody
maintains by hand. The classical alternative — HMM-GMM in the Kaldi lineage — adds
a pronunciation lexicon and a language model on top of decades of engineering.
Neither is a weekend, a month, or a sensible use of this project.

**Anyone proposing "let's write an ASR" should read this paragraph and stop.**

## What we can build, and why it is a better fit anyway

The cut-up feature never actually needed transcription. It needs two things, and
both are classical, training-free, and pure arithmetic:

**1. Query-by-example keyword spotting — MFCC + DTW.** Give it one instance of a
word and it finds every other occurrence in the corpus by acoustic similarity.
This is 1970s technology, needs **no training data, no model, no download, no
entitlement and no network**.

**2. Voice-activity detection — windowed energy and zero-crossing rate.** Where
speech starts and stops, which is word boundaries in clean speech and the honest
answer to "or sounds" in everything else.

**Query-by-example is arguably the better tool for this aesthetic than ASR
would be.** A recogniser answers "what word is this"; DTW answers "what else
sounds like this" — same speaker, same prosody, same room. For assembling a
sentence that hangs together, acoustic similarity is the more useful axis, and
being **speaker-dependent is a feature** on a personal voicemail corpus rather
than the limitation it would be in a product.

It also composes with what shipped today: `Cutup.Transcripts` narrows *which
recording* probably contains a word, a person confirms one instance by ear, and
DTW finds the rest. Text search does the coarse pass; acoustics do the fine one.

## Is the BEAM a good host for this? Honestly, mixed

**In its favour:** the algorithms are small, pure, total functions over numbers —
exactly what this codebase tests well. Binary pattern matching is genuinely good
at PCM. Indexing N recordings is embarrassingly parallel and `Task.async_stream`
is one line. And it needs **zero new dependencies** — nothing on the Apple
signing path, which is the constraint that killed the last attempt.

**Against it:** tight float loops are the BEAM's weakest axis — no SIMD, boxed
floats. A pure-Elixir FFT will run perhaps two orders of magnitude slower than C.

**The numbers, so the decision is not vibes.** The corpus is 295 s at 22.05 kHz.
At a 10 ms hop that is ~30,000 frames; a 512-point radix-2 FFT is ~4,600 butterfly
operations, so ~1.4×10⁸ float ops for a full index build. In pure Elixir that is
**tens of seconds, parallelised across files, once** — and an index is saved, not
recomputed. DTW search is a ~30-frame template against 30,000 frames: under a
million cells, effectively instant.

**So it works at this size, and the scaling limit is worth writing down now:**
past roughly an hour of audio the index build becomes uncomfortable and the
answer is `Nx` — not a rewrite, since the pipeline is already frame-parallel
arithmetic. Do not add `Nx` before that hurts; EXLA is a heavy dependency and
this roadmap's whole posture is to keep the signing path clean.

## Phases

> **V.0–V.3 SHIPPED 08-08-26. 2,785 tests green.**
>
> The code landed in commit `eccfbf4` — whose message is about the modularization
> roadmap, because a concurrent session ran a catch-all `git add` over the shared
> working tree while these files were staged. Nothing was lost or altered, but
> `git log` will not lead anyone here. **This block is the real record.**

**V.0 — Framing and the FFT. SHIPPED.** `Cutup.Signal`: 25 ms frames at a 10 ms
hop, pre-emphasis, Hamming, iterative radix-2 FFT with compile-time twiddle and
bit-reversal tables. Verified bin-for-bin against an independent naive O(n²) DFT
— the strongest check available, since it cannot share a bug with its reference.

- **Measured: ~40 s single-core to index the 295 s corpus, ~27 s across 8 cores.**
  Two qualifiers, both found by re-running it: that is **framing + FFT only**
  (MFCC is on top), and it is an **idle machine**. The same benchmark run
  beside four other suites drops to 229 frames/s and projects **129 s** — a
  3.2x contention penalty. Indexing would run alongside a live app, so treat
  40 s as the floor and 130 s as the realistic ceiling.
  The estimate above held — **but two errors cancelled.** It costed a *512*-point
  FFT, and 25 ms at 22.05 kHz is 551 samples, so the smallest radix-2 size that
  holds a frame is **1024**. Real work is ~2.2× the projection; the estimate
  survived only by being pessimistic about per-operation cost by about the same
  factor. An estimate right by accident is worth what a wrong one is, until
  measured.
- **Throughput HALVES on long clips.** Framing is eager, so a 10 s clip leaves
  ~1M live floats on the process heap and every GC walks them; the same audio in
  3 s pieces runs 2.5× faster. Chunking the *consumption* does not help.
  **Index one file per process, and prefer short files.**
- A 10 ms hop at 22.05 kHz is 220.5 samples. Rounding once to 221 and stepping
  drifts 0.23% forever — **0.67 s across this corpus, longer than a word.** Frame
  starts are recomputed from the index; error is bounded at half a sample and
  never accumulates.

**V.1 — MFCC. SHIPPED.** `Cutup.Mfcc`: 26 mel filters, log, orthonormal DCT-II —
chosen so the transform is an isometry, which means a DTW threshold means the
same thing on either side of it. Coefficient 0 kept, because CMN turns it from
absolute loudness into *relative* loudness within a recording. Deltas
implemented, **recommended off**: they sit on a different numeric scale, so
unweighted Euclidean over the concatenation silently reweights the vector.

**V.2 — Subsequence DTW. SHIPPED.** `Cutup.Dtw`, and the two decisions that make
it correct rather than merely working:

- **The recurrence minimises accumulated cost and normalises once at the end.**
  Minimising the ratio per cell has no optimal substructure — the argmin of a
  ratio does not decompose — so it would be a greedy heuristic optimal for
  neither objective. Cost and path weight are carried per cell as
  `{cost, weight, start_frame}` rather than backtracked, which is O(1) extra
  against retaining a 1.8M-cell matrix.
- **Symmetric step weights (diagonal 2, axis 1).** With all-1 weights the
  diagonal is a discount, so a straight path scores structurally lower than a
  warped one and the score partly measures *how much warping happened*. Weight 2
  makes the normalised distance exactly the mean local frame distance.
- **Measured 1.6M cells/s, flat across template length** — the observable proof
  per-cell work is O(1). A 30 s recording against a 60-frame template: **0.108 s**.
  The whole corpus: ~1 s.
- **Length independence is asserted**: at fixed perturbation, scores agree within
  ~1% across a 4× template-length range. Un-normalised they differ by 4×.
- Synthetic threshold band **≈0.2–0.9** against a false-alarm floor of ~2.2 that
  barely moves with target length. Real audio will differ; the moduledoc gives
  the *recipe* — measure the floor on a recording known not to contain the word,
  the ceiling on one that does, set nearer the floor.

**V.3 — VAD. SHIPPED.** `Cutup.Vad`: adaptive threshold as a multiplicative
margin over a p10 noise floor, hysteresis expressed as a run rule (a span is a
maximal run above the *leave* gates containing one frame above the *enter*
gates). Energy OR (lower energy AND high ZCR), because unvoiced fricatives are
low-energy and high-ZCR and an energy-only detector clips the onset of every word
starting with `s` or `f`.

- Two alternative thresholding schemes were built and rejected; the reasons are
  in the moduledoc. One of them would have made the ZCR branch **dead code at low
  SNR** — exactly the telephony case it exists for.
- **Predicted first failure on real audio:** the ZCR gate at 0.25. 8 kHz
  telephony bands out above 3.4 kHz, which is most of a fricative's energy;
  expect to want 0.15–0.20, and expect line noise to start creeping in there.
- Spans are **utterance boundaries, not word boundaries.**

## The threshold, measured against real speech (08-08)

The roadmap warned the synthetic threshold would not transfer. It did not, and
the size of the gap is the point: **DTW's own synthetic tests suggested a usable
band of 0.2–0.9 against a false-alarm floor of ~2.2. Real speech runs an order of
magnitude higher.**

Measured over the **Free Spoken Digit Dataset** (CC BY-SA 4.0, 8 kHz mono — the
same band as telephony), 45 labelled files, 3 speakers × 3 digits × 5 takes,
**990 pairs**, through the full Signal → Mfcc → CMN → Dtw chain:

| class | n | min | p05 | p50 | p95 | max |
|---|---|---|---|---|---|---|
| same word, same speaker | 90 | 2.97 | 3.38 | **4.43** | 7.49 | 9.23 |
| same word, diff speaker | 225 | 4.67 | 5.28 | 6.97 | 10.07 | 11.83 |
| diff word, same speaker | 225 | 5.08 | 6.05 | **8.99** | 10.78 | 13.24 |
| diff word, diff speaker | 450 | 6.08 | 6.71 | 9.40 | 11.78 | 13.11 |

**The ordering is exactly right, and speaker-dependence is confirmed as designed** —
the same word from another speaker (6.97) sits closer to a *different word* than
to the same speaker saying it again (4.43). For assembling one person's
voicemails that is the wanted behaviour.

**Operating point, same-speaker only (the real use case): threshold ≈ 6.0 →
precision 0.88, recall 0.93, F1 0.91.**

**But the distributions overlap, and an early 8-file sample hid that.** Eight
files showed a clean gap with no overlap at all; at 990 pairs, **128 of 225
negatives fall below the worst positive (9.23)**. The tail positives cannot be
recovered — pushing the threshold up to catch them floods the result with false
matches.

**So this is a shortlist generator, not an oracle**, and that is the honest frame
for the feature: at threshold 6 it finds 93% of real takes and about one in eight
returned spans is wrong. For a tool whose next step is *listen and pick*, that is
useful. For anything unattended, it is not.

**Caveat on transfer:** FSDD is clean, trimmed, isolated digits. Connected speech
inside a noisy voicemail — with co-articulated fragments and partial-word
matches among the negatives — should be harder. Treat 6.0 as a starting point to
re-measure against the operator's corpus, not as a constant.

**V.4 — Wire it to the index.** A DTW hit becomes a `t:word/0` with `origin:
:recognizer`, so **everything built in Phase A consumes it unchanged** — that is
the whole reason the index was defined as a contract first.

## What this will and will not do

- It will **not** transcribe. There is no text output, ever.
- It **cannot** find a word you have no example of. The workflow is
  transcript-search → confirm one instance → DTW for the rest.
- It is **speaker- and channel-dependent**. A word said by a different caller
  will usually not match, and that is correct behaviour for assembling audio
  that has to sound like one voice.
- Accuracy on 8 kHz telephony will be worse than on clean speech, and the
  threshold will need tuning against the real corpus rather than a fixture.
  **Expect to spend as long tuning the threshold as writing the DTW.**

## What could make this not work

- **On-device recognition availability is per-locale**, and the server path sends
  audio to Apple. For voicemail — other people's voices — that is a real
  disclosure question, not a technical one. Prefer
  `requiresOnDeviceRecognition`, and **say in the UI which one ran**.
- **Recognizer accuracy on voicemail audio is unknown here.** 8 kHz telephony,
  compressed, noisy. The index carries `confidence` for exactly this reason, and
  the guide should teach the agent to prefer high-confidence hits.
- **A word that appears once is not a word you can use.** The interesting
  question — *how many usable takes of "harbor" do I have across everything?* —
  is a property of the corpus, not the code, and Phase B is what answers it
  cheaply before Phase C is built.

---

## The first listen, and the two fixes it bought (08-08)

**The first real 24-word paragraph assembled cleanly and the operator's verdict
was one word: "garbled."** That is the most useful thing that happened to this
feature, and it is worth recording how it resolved.

Garbled ruled out the tempting next step. **Selection ranks what exists — if
every take of a word has the wrong boundaries, choosing between them cannot
help.** So the listening session (Part VI) was not the fix; `Align` was. The two
defects were the ones `Align`'s own moduledoc had already predicted:

1. **Boundaries landed mid-vowel.** Words were laid out proportionally and
   clamped only at *span* edges, so an interior boundary fell wherever the
   arithmetic put it. **Fixed** by snapping each boundary to the nearest strictly
   quieter frame within 40 ms, using the energy profile `Vad` already computes.
2. **Function words were over-allotted.** `to`, `the`, `of` run under 80 ms in
   real speech but received a full syllable's share, so they ate their
   neighbours' onsets — and this corpus is mostly function words. **Fixed** with
   a 0.55 reduction over a hand-curated stopword set.

**Both are on by default, and that default is now backed by ear**: rebuilt in
four variants (neither / snap / reduce / both), the operator judged **both**
better than the baseline. Both remain independently toggleable through
`sound_align` so the comparison stays reproducible, and a test pins that
*neither* reproduces the pre-correction output exactly — without which the A/B
would be against a moving target.

**One measurement that deserves follow-up:** snapping changed total duration by
**10 ms across 24 words**. It is barely moving anything, which is consistent with
its own strictly-quieter rule — a vowel-to-vowel or fricative-to-fricative
junction has no minimum to find, so the boundary correctly stays put. Whether it
earns its keep, or wants a wider window, is an open question that only more
listening answers.

**What is still wrong, and is not a parameter:** pre-boundary lengthening
(speakers slow at phrase ends; the model assumes a constant rate), stressed
function words now cut short (a *new* error class the reduction introduced), and
transcript errors still sliding every word after them. Those are what V.4 and
Part V address.

---

# Part IV — Choosing takes: the unit-selection lattice

**Operator ask (08-08):** give Ramshackle a graph, with weights, so phrasing can
be honed word by word.

**That instinct has a name — this is unit-selection synthesis**, the classical
technique behind concatenative TTS, and our data is already in its shape.

## The problem it fixes

Today `sound_assemble` is handed an ordered list of cuts and splices them. The
*choice* of which take of "morning" to use is made outside it, and in the first
real paragraph it was made by picking the median duration — which is very nearly
arbitrary. With 9 takes of "morning" and 35 of "to", the choice is most of the
quality and nothing is currently making it.

## Two costs and a search

A sentence becomes a **lattice**: one slot per target word, N candidate takes per
slot. Every path is a possible sentence; find the cheapest.

**Target cost — is this take good *for this slot*, ignoring neighbours:**

- alignment `confidence` (exists)
- duration against its syllable expectation (exists, in `Align`)
- **boundary energy** — does the cut start and end in a quiet moment, or
  mid-vowel? `Vad.energy_profile/2` already exposes exactly this, per frame.
  **This needs no human and no learning: a cut through a vowel is measurably
  worse than a cut at a closure.**
- distance from its own siblings — a take far from the other 8 instances of the
  same word is probably mis-aligned. `Dtw.distance/3` already computes it.

**Join cost — how well does this take splice onto the next.** The standard join
cost in unit-selection TTS is **cepstral distance across the seam**, and we
already compute MFCCs: compare the last frames of take A against the first frames
of take B. Add a level-match term, since `normalize/2` equalises peaks rather
than loudness and a level jump at a seam is audible.

**The search is Viterbi** over the lattice — the same dynamic-programming family
as the DTW already built and measured.

## What this will and will not do

- It will **not** invent audio. No path through a bad candidate set is good, and
  with 1–2 takes in a slot the search has nothing to do. **This improves
  monotonically as the corpus grows** (Part V), which is a reason to build it
  early and let it get better on its own.
- The acoustic costs are **measurable properties with obvious signs**. Hand-set
  weights will capture most of the benefit; fitting them is Part VI's job and
  should not block this.

---

# Part V — Growing the corpus: record it yourself

**Rewritten 08-09-26**, folding in three documents written that day — a microphone
plan, a word-dictionary brief, and a legal survey of sourcing words from YouTube.
All three are now retired into Parts V and VI.

## V.0 The one thing all three documents agreed on

Read separately they looked like three features. Read together they were **one
finding arrived at three independent ways**:

- **The engineering line.** Part V already called a donor session *"by far the
  highest value"* — known text, clean audio, consistent channel, a designed
  passage.
- **The measurement line.** Building *"Take me out to the ball game"* on 08-09
  scored **3/10 and was deleted.** Five of seven words had real takes; `take` and
  `ball` appear in none of the ten transcripts and were faked by splicing sub-word
  fragments. **The corpus, not the engine, was the constraint.**
- **The legal line.** A four-layer survey of sourcing words from YouTube concluded
  scraping is not a clean path, and arrived — on the merits, not as a consolation —
  at *"record 30–60 minutes reading phonetically balanced sentences… for a personal
  assistant that speaks in your own voice, this is almost certainly the right
  answer."*

**Three lines of reasoning — packaging, measurement, and law — converging on one
action is as strong a signal as this project gets.** Everything below is ordered by
it.

### The rule all three derive separately: one voice, one channel

Each document reaches this from a different direction and none says it in these
words, so it is stated here once:

- **Microphone:** pin a device for a donor session rather than "System Default",
  because macOS can move the default out from under a long take.
- **Dictionary:** `sound_find` is *"speaker- and channel-dependent by design"*, and
  Part IV's lattice was built for one speaker.
- **Legal:** *"Keep the voicemail corpus as its own separate voice. Don't merge
  banks. A sentence assembled from one voice sounds intentional; a sentence
  assembled from several sounds broken."*

**Banks never merge, and a bank is a voice-and-channel, not a folder.** This
constrains the data model before anything is built.

## V.1 The legal question is closed — do not re-open it

**Scraping general YouTube content is out.** It breaks YouTube's ToS at the
download step, before copyright is reached — and that prohibition applies
*regardless of what the video contains*, so even a public-domain recording hosted
there is covered.

**The copyright analysis is more favourable than expected and still not a plan.**
Individual words are not copyrightable (37 CFR § 202.1), but **the sound recording
of a word is a separate protected work** (17 U.S.C. § 102(a)(7)) — the fragment,
not the word, is the exposure. There is a live circuit split, and Washington State
sits in the **Ninth Circuit**, where *VMG Salsoul v. Ciccone* held a 0.23-second
sample non-infringing: squarely the size of one spoken word, and the strongest
legal fact available. But de minimis looks at the **aggregate** — a hundred words
from one speaker stops being "trivially small" — and fair use is **a defense
asserted after being sued**, not a permission.

**The layer that matters most here is the one people forget.** This pipeline exists
to make a recognisable voice say things it never said, which puts **right of
publicity** ahead of copyright. Washington's RCW 63.60.010 makes voice an explicit
property right with statutory remedies; *Midler v. Ford* and *Waits v. Frito-Lay*
establish it federally for voice specifically; the **NO FAKES Act** (S. 4591,
advanced out of Senate Judiciary 22 June 2026) would federalise it. **That risk is
independent of how the audio was obtained and of how short the samples are.**

**Which is the real argument for recording yourself: it removes an entire legal
layer instead of arguing about it.** No ToS, no copyright, no publicity question —
plus one channel, and the ability to re-record any word that comes out badly.

*Not legal advice. Anything shipped should get a lawyer's eyes. Non-commercial
personal use is where this sits today and is where every argument above is
strongest.*

## V.2 Where the audio can come from, in order of value per effort

**1. A donor session — by far the highest value.** The operator reads a prepared
passage aloud. This is how TTS voice datasets are actually built, and it inverts
every hard problem at once: **the text is known exactly** (no Twilio mangling, no
"bus o'clock"), the audio is clean and consistent in level and channel, and the
passage can be *designed* to cover the vocabulary a cut-up actually needs —
pronouns, verbs, connectives, numbers, days, months. An hour of reading would dwarf
the entire existing corpus.

**Note what it does to Part III:** with known text and clean audio, `Align`'s
output stops being crude — its two worst failure modes (transcript errors sliding
the timeline, and unpredictable spontaneous speech rate) both largely vanish.

**2. Voicemails, which accumulate on their own.** Free, organic, already wired. The
constraint is that they are other people's voices and Twilio's transcripts.

**3. Licensed speech corpora — and note two different uses.**
[FSDD](https://github.com/Jakobovski/free-spoken-digit-dataset) (CC BY-SA 4.0,
8 kHz) is already proven as the DTW ground truth behind the threshold study.
[LibriSpeech](https://www.openslr.org/12) / **LibriTTS** (CC BY 4.0) matter twice
over: **word-level alignments exist** (Montreal Forced Aligner), which is
ground-truth timing to measure `Align` and `Dtw` against instead of guessing —
*and* they are the **licensed fallback for material** if the donor session does not
happen, because they carry **hours per individual speaker with transcripts
included**, which skips the hardest pipeline step. Pick one reader with the most
material and build that bank from that single voice. Also green: **Common Voice**
(CC0, but many speakers × few minutes — good coverage, wrong shape for one
consistent voice), **VCTK** (48 kHz studio, ~24 min/speaker), **LibriVox**, and US
Government works (17 U.S.C. § 105).

> **Do not vendor any of them into this repo.** FSDD is share-alike and this tree
> is source-available (PolyForm Shield). A fetch script plus a gitignored fixture directory, with tests
> that skip when it is absent — the pattern `sound_studio_test.exs` already uses
> for a missing `afconvert`. And per V.0, a licensed bank stays **separate** from
> the operator's voice.

**4. Anything the operator already has** — recordings, interviews, voice memos.
`sound_import` takes any Library-relative file, so this is already reachable.

## V.3 There is no way to record inside this app, and that is the gap

Verified 08-09 against the tree:

| | State |
|---|---|
`getUserMedia` anywhere in `assets/js` | **none** |
`NSMicrophoneUsageDescription` | **absent, deliberately** — `Info.plist` lists it under *"WHAT IS DELIBERATELY ABSENT, and why, so nobody adds it back on a hunch"* |
`com.apple.security.device.audio-input` | **absent** from `Entitlements.plist` |
`media-src` in the CSP | **absent** — media falls back to `default-src 'self'` |
Tauri bridge precedent | `voice.js` (57) ↔ `voice.rs` (111), `speak`/`stop_speaking`, **output only** |
`ffmpeg` | present, 8.1, built with `avfoundation` |

**Directly reusable, so the recorder is smaller than it looks:** `studio_audition.js`
(170 lines, WebAudio + ArrayBuffers, **no blob URLs**), `wave_trim.js` (161,
drag-to-select — **the post-record trim UI already exists**), `clipwave.js` (247,
WGSL peak texture), `studio_keys.js` (82), and `SoundStudio.write/2` — **WAV
encoding already exists in Elixir.**

### The process-boundary argument, which decides the design

`Entitlements.plist` documents this trap in another context and it applies here at
full force: **entitlements do not inherit across process boundaries.**

**The process that opens the microphone is the process that needs the entitlement
and the TCC grant.** Capturing in the WebView puts that in the Tauri app — signed
with `Entitlements.plist`, carrying an `Info.plist`, both of the things consent
requires. Spawning `ffmpeg` from the BEAM puts it in a process with neither, out of
`Contents/Resources`, where consent is attributed to the *responsible* process — so
the prompt may go to the wrong app or never appear, and **the failure mode is the
worst available: a WAV full of silence, with no error.**

**So: capture in the front end for the operator's path, and keep the `ffmpeg` route
as an explicitly-caveated agent convenience (V.9).**

## V.4 Two cheap decisive things, before anything else

> **Half done: V.4b shipped, V.4a has not been attempted.** Which is the wrong
> half — this section's whole argument is that the *spike* goes first, because
> it is the one that can invalidate the design. V.4b was buildable by an agent
> alone and V.4a needs a signed build and a permission dialog, so the easy half
> got done and the decisive half did not. Stated here rather than implied by two
> status markers.

**V.4a — The `getUserMedia` spike (~1 day, the highest-risk unknown here).** Build
a signed app that does nothing but open an input stream and print its sample rate.
Test in **both** hosts: Chrome at `localhost:4000` (a secure context) and the
**packaged** app. Needs the `Info.plist` key and the entitlement to be a real test,
so it overlaps V.5 deliberately. **If it fails, front-end capture is dead and the
recorder becomes a substantially larger Rust build — better to know on day one.**

**V.4b — The "what words am I missing?" report. ✅ SHIPPED** — `Cutup.Gaps`, the
`sound_gaps` verb, 23 tests. *This section read "and built by neither" until
08-14, while the verb table further down this same document already listed
`sound_gaps` as "V.4b's report". The document disagreed with itself; the code
was right.*

A read-only report over the existing index: which words the corpus has, with how
many takes, and — against a target vocabulary — **which it lacks entirely.**

It is the difference between a designed passage and a guessed one: write the donor
passage *against this*, so an hour of reading targets real gaps rather than ground
the voicemails already cover 35 times over. It is also the first half of the
dictionary's Pane 1 (VI.1), so it is not throwaway work.

**A word with one take is a quotation, not a cut-up.** That distinction is the most
useful thing this report — and later the dictionary — can surface.

### What it says today (run 08-14, the live ten-voicemail corpus)

Every number this Part quotes comes from here, which is worth knowing before
re-measuring anything by hand:

| | |
|---|---:|
| indexed sources / unreadable | 10 / 0 |
| distinct words | **237** |
| total takes | 655 |
| cuttable (≥2 takes) | **93** |
| single-take (quotable only) | **144** |
| origins | `aligned` 655 · everything else **0** |

Three things fall out of that table and they shape the donor passage:

1. **144 of 237 is where "the corpus is mostly quotations" comes from.** It is
   measured, not estimated, and `sound_gaps` re-measures it on every call.
2. **Every take is `aligned`** — a proportional guess capped at 0.9 confidence.
   There is not one `manual` or `recognizer` take in the corpus, so the whole
   vocabulary is estimates. VI.2 (correct boundaries) is what changes that, and
   until it does, quality complaints are a boundary problem before they are a
   recording problem.
3. **The frequency curve is brutally top-heavy.** `to` 35, `the` 29, `you` 28,
   `i` 27, `and` 26 — then a long tail where *93 cuttable words* means most of
   them sit at exactly 2. Reading more of the same material buys almost nothing;
   this is the argument for a *designed* passage stated as a number.

**Write the passage against `sound_gaps target: "<words>"`.** It returns the
target words with zero takes, normalized the same way the index is, so a word it
does not list is one you already have — and if it also appears in `single_take`,
you have it once, which is a quotation and not a cut.

## V.5 Permissions and packaging groundwork

`Info.plist`: add `NSMicrophoneUsageDescription`, **and fix the comment that
currently asserts nothing captures.** It is in the "deliberately absent" list, which
makes it an explicit claim rather than an omission — and a stale comment
confidently stating the opposite of the truth is worse than no comment. Write the
string honestly; the operator reads it verbatim in the system dialog.

`Entitlements.plist`: add `com.apple.security.device.audio-input`. **Three rules
that file documents about itself, all load-bearing:**

1. **No double hyphen anywhere in a comment.** `plutil -lint` accepts it; codesign's
   AMFI parser rejects the entire file and signs nothing.
2. It is referenced from **two** places on purpose — `tauri.conf.json` at
   `bundle.macOS.entitlements`, and `scripts/codesign_release.sh`, which signs every
   Mach-O in the OTP tree. Both must stay pointed at it.
3. The file says *"NOTHING ELSE BELONGS HERE."* Adding a key is a deliberate
   exception and gets commented as one, in the same voice as its neighbours.

**This is notarization-affecting.** Budget a full signed-and-notarized build to
validate it, not a `cargo tauri dev` run — read `../platform/APPLE_ROADMAP.md` III.E first.

**No CSP change should be needed**, because of the AudioWorklet decision in V.7. If
a future path wants blob playback, `media-src 'self' blob:` gets argued on its own
merits rather than slipped in. `tauri.conf.json` sets `app.security.csp: null`, so
the Phoenix header is the only policy in force: one place to change.

## V.6 See the mic move — metering with no recording at all

**Independently useful, and where every device and permission edge case surfaces.**
A small honest thing to ship before anything can be lost.

**Enumeration has two gotchas, and building the picker first is a common avoidable
rewrite:**

- **Labels are empty until permission is granted.** The flow must be: prompt with
  default constraints → get the grant → re-enumerate → *now* show real names.
- **`deviceId` is stable per-origin but rotates** when permission is revoked or site
  data is cleared. Persist the **label** alongside the id and fall back to matching
  by label.

**Hot-plug** via `ondevicechange`. Two cases that must not be silent: a device
appearing mid-session refreshes the list but **does not switch the active input
under the operator**; and **the active device disappearing mid-recording** — a USB
mic unplugged, AirPods sleeping — must **stop the recording, keep what was
captured, and say plainly what happened**, not keep "recording" silence.

**Metering: two numbers off the same frames.** **Peak**, with a **latching clip
indicator** — a clip that flashes for 40 ms is missed and the take is already
ruined. And **RMS**, for "am I loud enough", because peak alone is a bad guide to
whether a recording is usable. Render on **dBFS, −60 to 0, with a marked target
zone**; a linear meter spends most of its travel where the ear does not care.
Reuse `clipwave.js` — the meter must not become a second waveform implementation.

**Aim for peaks −12 to −6 dBFS while speaking, nothing touching 0.** Digital
clipping is unrecoverable, which is why this phase is **preventive**: a
check-your-level state that runs *before* arming. Note `sound_normalize` targets
≈ −1 dBFS and is **peak**, not loudness — it cannot rescue a clipped take and will
happily amplify a quiet noisy one along with its noise. **And the probe already
measured this corpus peaking at ~0.96**, so headroom is the live risk here, not
level.

### Enumeration, measured 08-09 — use `system_profiler`, not `ffmpeg`

Both candidates were run by hand and the choice is not close.
**`ffmpeg -f avfoundation -list_devices true` returns an index and a name and
nothing else** — no transport, no channel count, no sample rate, which is all three
fields enumeration exists to provide. It also interleaves video devices, writes to
stderr, and exits non-zero by design. **`/usr/sbin/system_profiler SPAudioDataType
-json` carries every field.** (`ffmpeg` remains the right tool for *recording* in
V.9 — just not for asking what exists.)

**The transport vocabulary is verifiable rather than guessable.** It lives in the
reporter binary:

```
strings /System/Library/SystemProfiler/SPAudioReporter.spreporter/Contents/MacOS/SPAudioReporter \
  | grep coreaudio_device_type
```

→ exactly twelve: `builtin usb bluetooth virtual displayport hdmi airplay avb
firewire thunderbolt pci unknown`. So `bluetooth` is a confirmed member of Apple's
own table, not an inference from device names.

**Three traps the real payload exposed, all of which a naive parser hits:**

1. **The system-default flag sits on a *different device*.**
   `coreaudio_default_audio_system_device` was on the **LG monitor**, not on any
   input. The input discriminators are `coreaudio_device_input` and
   `coreaudio_default_audio_input_device`.
2. **"Built-in" does not mean "input"** — the speakers are built-in too.
3. **`coreaudio_input_source` can be the literal placeholder `"spaudio_default"`.**
   Take the name from `_name`, or the picker will offer the operator a microphone
   called *"spaudio_default"*.

**This machine has two inputs, not one:** *MacBook Pro Microphone* (builtin, 1 ch,
48 kHz, default input) and *iPhone (5) Microphone* (Continuity Camera, transport
reported as `unknown`). So multi-device handling is exercised by the current
hardware after all.

**And one honest limit on the Bluetooth guard below.** The reporter's table has a
single `bluetooth` value, while CoreAudio distinguishes Bluetooth from
Bluetooth-LE — so **a BLE headset may surface as `:unknown` rather than
`:bluetooth`**. Nothing was paired on 08-09, so AirPods → `:bluetooth` rests on that
string table and **has not been verified on hardware.** A caller that must not
record over Bluetooth should treat `:unknown` as *unproven, not safe.*

### Bluetooth — the trap that reproduces the exact problem we are escaping

**The highest-value warning in the microphone document.** Bluetooth has two
profiles: **A2DP** (output only, high quality) and **HFP/HSP** (bidirectional, much
worse). **Opening a Bluetooth headset as an input switches the whole device out of
A2DP into HFP** — classic HFP is 8 kHz narrowband, wideband mSBC is 16 kHz.

1. **A donor session recorded over AirPods is close to worthless** — it hands us a
   second 8–16 kHz corpus, which is precisely what the session exists to escape. We
   would have gained nothing but a known transcript.
2. **The operator will hear their own output degrade the instant recording arms**,
   because output collapses to HFP at the same moment. That reads like a bug, so the
   UI should pre-empt it in words.

**Read the true rate of the live stream** — `AudioContext.sampleRate` and
`track.getSettings()` — and **display what the open stream is actually running at,
never the device's advertised capability. Warn below 32 kHz** in plain language.
Label Bluetooth transports in the picker *before* selection. Prefer wired: the
built-in MacBook Pro mic at **48 kHz** beats any Bluetooth headset here and is the
default already.

**Channel count matters too:** a 2-in interface may carry voice on channel 1 with
channel 2 silent or noise, so mixing to mono halves the level and folds in the
noise. Show channel count; offer *left / right / mix* when > 1. Request
`channelCount: 1` as a hint, not a guarantee.

## V.7 Record and save

```
┌─ RECORD ─────────────────────────────────────────────────┐
│                                                          │
│  Input  [ MacBook Pro Microphone            ▾ ]          │
│         48 000 Hz · 1 ch · Built-in            ✓ good    │
│                                                          │
│  Level  ▁▂▃▄▅▆▇█▇▆▅▄▃▂▁                                  │
│         -60    -40    -20   -12  -6   0                  │
│                      [   target   ]      ● CLIP          │
│                                                          │
│         Input volume  ────────●─────  62                 │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │            ●  RECORD          ⏎ or Space           │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  Saves to sounds/studio/ · nothing is uploaded           │
└──────────────────────────────────────────────────────────┘
```

While recording: the button becomes **STOP**, an elapsed timer runs, the meter keeps
moving, a live waveform scrolls, and everything else is disabled. After stopping it
becomes a review state — waveform with the `wave_trim.js` selection overlay,
**Play**, **Trim**, a name field, and **Save to Studio** / **Retake** / **Discard**.

**The meter runs before you arm.** The operator must be able to see the needle move
and set their level without committing to a take; this single behaviour prevents most
bad recordings. **The format readout is always visible** and turns into a warning
below 32 kHz (V.6).

AudioWorklet capture → raw PCM → a new `sound_record_save` verb → a source in the
Studio. Review state reusing `wave_trim.js`. **Retake as a first-class button**, not
discard-then-restart — it is the most-pressed control in any recording tool. An
optional 3-2-1 pre-roll so the first word is not clipped by the operator's own
reaction time. Spacebar transport, matching `studio_keys.js`.

### AudioWorklet, not `MediaRecorder` — three reasons

1. **CSP.** `MediaRecorder` produces a `Blob`, whose natural next step is
   `URL.createObjectURL`; with no `media-src` this app falls back to
   `default-src 'self'` and `blob:` media is refused. `studio_audition.js` already
   documents working around exactly this, and `dtmf.js` is the standing precedent.
2. **Format.** `MediaRecorder` emits MP4/AAC in WKWebView and WebM/Opus in Chrome —
   both lossy, both needing decode, and **the two hosts would disagree.** An
   AudioWorklet hands back raw `Float32` PCM identically everywhere.
3. **We already have the encoder.** Ship raw PCM to the server and let
   `SoundStudio.write/2` produce the WAV with tested Elixir, rather than writing a
   second WAV encoder in JS.

### Turn the voice-call processing OFF — and why it is not a detail

```js
navigator.mediaDevices.getUserMedia({
  audio: {
    deviceId: {exact: chosenId},
    echoCancellation: false,
    noiseSuppression: false,
    autoGainControl: false,
    channelCount: 1,
  },
})
```

All three are on by default in Chrome, all three are built for conference calls,
and all three are **time-varying** — they change behaviour as the signal changes.

**`autoGainControl` is the sharpest cross-document finding in this whole roadmap.**
It means two takes of the same word, from the same session a minute apart, come back
at **different levels**. A cut-up splices exactly such fragments together — so AGC
guarantees an audible level jump at every seam. That is *precisely* the artefact
`sound_assemble`'s `normalize` option exists to suppress, **reintroduced upstream
where nothing downstream can remove it.** `noiseSuppression` is nearly as bad: it
gates and reshapes quiet passages, which is where word onsets and plosive closures
live — the parts that matter most when cutting.

**Constraints are requests, not guarantees.** Verify with `track.getSettings()` and
surface a mismatch.

### Sample rate policy

- **Capture at the device's native rate** (48 kHz here). Do not ask the browser to
  resample on the way in.
- **Archive the 48 kHz master.** Downsampling is lossy and irreversible; if the
  internal format ever changes, the masters are the only way back. An hour of
  48 kHz mono PCM16 is ~350 MB. Disk is cheap.
- **Resample properly.** 48 000 → 22 050 is ~2.1769, not an integer, so naive
  decimation aliases badly. Use `OfflineAudioContext` at 22 050, or `ffmpeg`'s
  `swresample`. Both apply the required low-pass.
- **Keep 22.05 kHz as the working format**, archive at 48 kHz, revisit only with
  evidence. The donor corpus is the first material that genuinely exceeds 22.05 kHz,
  so this deserved a deliberate answer rather than inheritance — and the deliberate
  answer is that 11 kHz of bandwidth covers the intelligible range and matches every
  existing asset.

**Never auto-overwrite.** A recording is unrepeatable; a name collision prompts,
always. `sound_record_save` reports `peak` and **flags a clipped take at the door**
rather than letting it be discovered later.

### Levels: an honest limitation

**The web layer cannot set OS input gain.** A `GainNode` after capture raises the
recorded level but **cannot undo clipping that already happened at the converter.**
In preference order: (1) guide the operator to *System Settings → Sound → Input*
with a target-zone readout; (2) a small native command using
`osascript -e "set volume input volume 50"` — coarse 0–100, current default device,
no CoreAudio bindings, good value for the effort; (3) full per-device CoreAudio gain
only if 1 and 2 prove insufficient.

**Do not fake it.** A slider that silently only applies post-capture, while the
operator believes it is setting the mic, is worse than no slider.

## V.8 Donor session mode — the payoff

A teleprompter over the V.7 recorder. This is what this Part was always pointing at.

- The prepared passage, one line at a time, large type — **written against V.4b's
  gap report.**
- **Record per line, not per hour.** Each line becomes its own source with **known
  text**, which is what makes `Align` stop being crude.
- Per line: **Keep** / **Retake**, then advance.
- Progress over the passage, and **resumable** — an hour of reading will not happen
  in one sitting, and Part VI already notes that fatigue degrades quality.
- **Pin the input device** for the session (V.0).

Candidate passages: the **Harvard sentences** or VCTK's prompt list, both
phonetically balanced — but the gap report should bend the selection toward the
function words, numbers, days and months a cut-up actually needs.

## V.9 `sound_record` for the agent, silence-checked

The one route that works **today** with zero packaging changes: the BEAM spawning
`ffmpeg -f avfoundation`. It is also the only **agent-addressable** capture path —
*"record thirty seconds of room tone"* with nobody clicking — which is consistent
with this project's posture that every surface should be reachable by the agent.

**Ship it as a CLI/agent convenience with its caveat in the verb's own description,
not as the operator's recording path.** No live metering (ffmpeg is a black box
mid-capture), no device-change handling, and the TCC problem from V.3. **It must
verify the capture is not digital silence before reporting success**, and return an
error naming the TCC cause if it is.

### New verbs, following the existing read-half / write-half split

| Verb | Half | Does |
|---|---|---|
`sound_gaps` | read | V.4b's report: vocabulary coverage, and what is missing |
`sound_devices` | read | Input devices with name, transport, channels, native rate, system-default flag |
`sound_input_level` | read/write | Get/set OS input volume 0–100, via the `osascript` route |
`sound_record` | write | Agent-addressable capture, duration-bounded, **silence-checked** |
`sound_record_save` | write | Accepts raw PCM + rate/channels/name, writes via `SoundStudio.write/2`, reports `peak`, flags clipping |

**Every one lands a file in `sounds/studio/` as a *source*.** Recording never routes
a chime. **`sound_apply` stays the separate, trust-gated act.**

## V.10 Risks specific to capture

| Risk | Severity | Mitigation |
|---|---|---|
`getUserMedia` broken in Tauri v2 WKWebView | **High** — invalidates the design | V.4a spike, day one. Fallback is native Rust (`cpal`), a much larger build. |
Entitlement change breaks notarization | High | Full signed build in V.5 before any UI. Obey the no-double-hyphen rule. |
**Bluetooth silently degrades the corpus** | **High for project value** | True-rate readout, hard warning below 32 kHz, transport labelled pre-selection. |
**AGC / noise-suppression left on** | **High and easy to miss** | Explicit constraints, verified with `getSettings()`, mismatch surfaced. |
TCC denial is sticky — no programmatic re-prompt | Medium | Detect it, show the exact path: System Settings → Privacy & Security → Microphone. **Never silently record nothing.** |
Dev-in-Chrome and packaged permissions diverge | Medium | Two permission stores, two failure modes. Mirror the existing dev/packaged split. |
Device vanishes mid-take | Medium | `ondevicechange`: stop, keep the audio, explain. |

---

# Part VI — The dictionary: the ear, and only then the weights

**Rewritten 08-09-26.** The original Part VI was the labelling session alone. The
dictionary brief showed that the labelling session is the *fourth* thing to build
here, not the first — and that the three before it are more valuable.

## VI.0 The thesis: the Studio cannot listen

**It can cut, align, match and choose. It cannot listen.** Every remaining quality
problem traces to that one gap:

- `sound_align` confidence is **capped at 0.9** by design, because it is a
  proportional guess. **Only a human ear promotes a take to `manual` / 1.0.**
- **`sound_find` is unusable without a confirmation UI.** Its own docs call it a
  *"SHORTLIST GENERATOR, not an oracle"* — precision 0.88 / recall 0.93 at DTW
  threshold ≈ 6.0, measured against 990 labelled pairs. **Roughly one match in eight
  is wrong.** There is no responsible way to run it at scale without a person
  confirming by ear. **This is the strongest single argument for this Part.**
- Part IV's lattice picks takes the operator never hears until the sentence is
  already assembled.

**And it compounds with Part V.** An hour of donor audio without the dictionary
gives ten times the words with **still-uncorrectable boundaries**. The dictionary
without new audio can only redistribute what 295 seconds holds. Together: record
clean known-text audio, correct it once, permanently — and every future sentence
using that word improves. **The corpus gets better each time it is used.**

**Sequence by risk, not by value.** Part V is gated on an unknown (V.4a) and a
notarization-affecting change; the dictionary has **no blockers at all** — it is
LiveView plus existing hooks over verbs that already ship. So spike V.4a on day one,
then build VI.1 while the packaging clears.

## VI.0b Where it lives — ANSWERED 08-09 by the operator

> **Superseded in placement, not in substance (08-16).** The Studio is no longer
> a Home sub-tab — it is its own route, `StudioLive` at `/studio`, with three
> tabs rather than two (`Mix` · `Voice Library` · `Sketch Pad`). The decision
> below is kept as written because it was true when made and the *reasoning* —
> a rail over sibling surfaces, sidestepping the frozen component — is what
> actually got built. Only the surface it sits on moved.

**Two sub-tabs inside the home Studio tab: `Mix` and `Voice`.** Mix is the
existing cutting-and-arranging studio. **Voice** is voice training and ramshackle
audio creation — the recorder from Part V and the dictionary below.

This resolves the open question better than either option previously framed,
because **it does not extend `sound_studio_component.ex` at all.**

**The component is `FROZEN` at 1,235 lines, and its cap equals its current size —
it cannot grow by a single line.** A sub-tab *inside* it was therefore never
available. A sub-tab *above* it means the Mix tab renders it **unchanged**, and
the Voice tab is a sibling. The frozen file stays frozen and no extraction is
needed to start.

### Copy the Explore tab exactly — it already solved this

`ExplorePanel` (96 lines, capped 104) is *"the rail and the dispatch, and nothing
else"*, with every tutorial its own module under `BusterClawWeb.Explore` and a
**data-only `Explore.Registry`** as single source of truth. The rail, the parent's
event whitelist (via `tab_keys/0`) and the panel dispatch all read from that
registry, **so a tab cannot exist in one of them and not the others.** That
property is the reason the registry has no dependencies.

Mirror it:

| New file | Role |
|---|---|
`components/studio/registry.ex` | Data-only: the sub-tabs, labels, blurbs. **Adding a third is one edit here.** |
`components/studio_panel.ex` | The rail and the dispatch. `tab_keys/0` feeds the parent's whitelist. Mix dispatches to the existing `SoundStudioComponent`; Voice to the new module. |
`components/studio/voice.ex` (and siblings) | The Voice tab's surfaces, as they land. |

### The sub-tab assign belongs to `StatusLive`, not the panel

Not a style choice — both existing modules state the reason. `Status.Studio`:
*"home panels render behind `:if`, so the component — and any state it held — is
discarded on every tab switch. An undo stack that empties when you glance at Chat
does not read as a tab switch; it reads as the feature being broken."*
`ExplorePanel` says the same about its sub-tab. So `:studio_tab` is a `StatusLive`
assign, exactly like `:explore_tab`.

**But `status_live.ex` is at its cap exactly (929/929 HELD).** The chat-skins work
hit this and the answer is the same: **push the wiring down into
`status/studio.ex`** (103/114, real headroom) and let `StatusLive` carry only the
assign, one `handle_event` clause whitelisted through `StudioPanel.tab_keys/0`, and
one condition. Raise the cap by those few lines **in the same commit, with the
reason written there** — that is the ratchet's documented protocol, and the
precedent is `chat_panel.ex` going 1,020 → 1,040 for the text-size axis.

**One existing line changes:** the Studio toolbar at `status_live.ex:851` renders
on `@home_tab == "studio"`; it belongs to Mix, so it gains
`and @studio_tab == "mix"`. No new lines.

### Build the shell before the contents

The shell is **pure structure and independently testable**: the rail renders, the
whitelist rejects an unknown tab, Mix still renders the existing studio
byte-for-byte, Voice renders a placeholder. Ship that, then land the Voice tab's
surfaces into a frame that already exists — rather than growing a frame and a
feature at once and being unable to tell which broke.

**A note on the Voice tab's own scope.** It holds two genuinely different
activities: *recording* (V.6–V.8) and *browsing/auditioning/correcting* (VI.1–VI.3).
They may want to be two tabs rather than one. Because the registry is data-only,
**splitting them later is one edit** — which is the whole reason for copying Explore
rather than hand-rolling a rail.

## VI.1 Browse and audition — this alone is worth shipping

### What the dictionary actually reads

Part II defines the index as an in-memory map. **On disk it is one JSON file per
source**, and the dictionary reads and writes these directly, so the full shape
belongs here (measured 08-09):

```
sounds/studio/index/<source>.wav.index.json
```

```json
{
  "version": 1,
  "source": "voicemail-RE176efbe12921acb0f55286217ac5aec0.wav",
  "indexed_at": "2026-08-09T14:07:24.488767Z",
  "origin": "aligned",
  "language": null,
  "words": [
    { "word": "good", "text": "Good", "start_ms": 10.0,
      "end_ms": 302.5, "confidence": 0.7743340717131871 }
  ]
}
```

Note `word` versus `text`: the normalised key and the surface form as spoken.
`origin` is one of **`aligned`** (proportional guess, confidence caps at 0.9),
**`recognizer`** (MFCC + DTW, from `sound_find`), or **`manual`** (hand-marked, the
**only** origin that earns 1.0). Sources live one directory up in
`sounds/studio/`; audio is PCM16 mono 22.05 kHz.

**The corpus lives outside the dev workspace** — all ten recordings are under the
configured DataZone, so a dictionary built in dev sees nothing unless pointed at
it. `sound_corpus` reports that as a number rather than a failure.

**Three panes.**

**Pane 1 — Vocabulary.** Every indexed word, sorted by take count descending, with
search. **Words with exactly one take are visually marked as not-cuttable — the
highest-value pixel on the screen.** Data: `sound_index_words`. This is V.4b grown
up.

**Pane 2 — Takes.** One row per take, ranked by confidence: source, `start_ms`,
duration, confidence, `origin`. A waveform per row that plays **instantly on
selection** — arrow keys audition, no click. Show surrounding transcript as context
with the word emphasised; knowing a take came from *"…at the 6 30 AM in the morning,
go to the navy base…"* tells the operator what prosody to expect. Data:
`sound_index_search`.

**Pane 3 — Sentence builder.** Type a phrase; each word becomes a chip. **Chips for
words with no take render as a clear warning before anything is built** — the one
signal that would have prevented the 3/10 attempt entirely. Sliders for `gap_ms` /
`pad_ms` / `fade_ms`. **Preview** renders and plays **without writing a file.**
Data: `sound_sentence` — read its `missing` field first, and surface `selection`:
**`candidates == slots` means every word had exactly one take and the lattice
decided nothing, so a reported cost of 0.0 means *best-of-one*, not *good*.**

**Four non-negotiable interaction rules:**

- **Audition must be instant and keyboard-driven.** If hearing a take takes two
  clicks, the operator will not audition twenty, and the feature dies. This is the
  whole product.
- **Preview before write.** Every failure so far came from committing audio nobody
  had heard.
- **Never silently drop a word** — per `sound_sentence`'s own docs, the worst failure
  mode this feature has.
- **Show provenance everywhere.** `aligned` / `recognizer` / `manual` mean very
  different things and belong on every take, always.

**Search grammar worth stealing:** `audiogrep` / `videogrep` (Sam Lavigne,
`antiboredom` on GitHub, MIT-ish) is the same architecture — corpus → force-align →
word index → search → concatenate — validated by a decade of use, and its **fragment
and n-gram / pattern search is more expressive than `sound_index_search`'s
whole-word lookup.** Cheap, high-value addition to the search box. **Read it; do not
vendor it** — this tree is source-available (PolyForm Shield) and the dependency is unnecessary. It is
also informative for what it *lacks*: no audition, no boundary correction, no notion
of take quality. **That absence is the gap this Part fills**, which means this is an
unserved need rather than a solved one.

## VI.2 Correct boundaries — what makes the dictionary compound

Draggable start/end handles on the Pane 2 waveform; on commit, write back via
`sound_index_import` with `origin: "manual"` and `overwrite: true`. **Every
correction is permanent, raises that take to confidence 1.0, and improves every
future sentence using that word.**

**Praat solved this UI thirty years ago** — a waveform with draggable tier
boundaries. Copy it. (ELAN's multi-tier layout is the reference if phones are ever
indexed as well as words. Descript is the bar for the transcript-linked editing
model.)

**`sound_index_import` refuses an existing index unless `overwrite: true`,** because
a hand-corrected index is real work. **Never overwrite `manual` with `aligned`
output.**

## VI.3 Confirm `sound_find` hits — how the corpus grows without recording

From any confirmed take, sweep the corpus for acoustic matches and present them as
an audition queue: play, then **keep** or **reject**. Kept hits enter as
`origin: recognizer`.

**`sound_index_words` counts are a floor, not a census**, because Twilio's
transcriber drops words on 8 kHz audio. There are almost certainly unindexed takes
of common words sitting in the existing ten files right now.

**The DTW threshold ≈ 6.0 is a starting point, not a constant** — same-word distances
(3–9) overlap different-word ones (5–13). Make it adjustable and **show the
distances.**

**Whether VI.2 or VI.3 goes first is an open question.** VI.3 grows the corpus; VI.2
improves what is there. Corpus size is the binding constraint, which argues VI.3 —
unless the donor session lands, in which case there will be an hour of fresh
`aligned` timings worth promoting and VI.2 matters more.

## VI.4 The labelling session: labels, and only then weights

**Operator ask (08-08):** an intensive session where the model asks a lot of
questions about word quality.

**This is active learning, and the framing matters.** The model cannot hear. It is
not learning to judge audio — it is **building a labelled dataset by choosing good
questions**, and then fitting Part IV's cost weights to match the operator's ear.
Being clear about that is what keeps the feature honest. **It comes after VI.1–VI.3
because it needs the audition surface those build.**

### Ask pairs, not scores

**"Which of these two takes of *morning* is better?"** beats "rate this 1–5".
Pairwise judgements are more reliable, need no calibration, survive fatigue better,
and are what ranking models actually want. Absolute scores from one person drift
within a single sitting.

### Ask the questions that are worth asking

A session that walks the corpus alphabetically wastes the operator's time. Query
strategy, roughly in priority order:

- **Leverage** — words that appear most often in assembled sentences. Getting `to`
  and `the` right matters more than any content word, and they are the words `Align`
  handles *worst* (function words are systematically over-allotted).
- **Uncertainty** — pairs where the target costs disagree, or are close enough that
  the model genuinely cannot rank them.
- **Disagreement** — where boundary energy says one thing and DTW-to-siblings says
  another. A label there resolves an actual conflict.

Skip pairs the costs already rank confidently — they teach nothing.

### What gets stored, and why it matters before any fitting

Each judgement stores **the two takes, the winner, and the full feature vector at
judgement time**. That last part is what makes the data outlive the model: if the
costs change, old labels remain fittable because the features they were judged under
are recorded.

### Be honest about the ceiling

- **A few dozen labels is tuning, not learning.** Say so. Fit weights only when the
  data supports it, and report how much went in.
- **This overfits to one person's ear on a small corpus** — which for a personal tool
  is arguably correct, and should still be stated.
- **Session design is a real constraint**: label quality degrades with fatigue, so
  sessions should be short, resumable, and should record their own ordering so a
  tired tail can be discounted later.

### Phases

- **VI.4a** — store judgements (schema + verbs), with the feature vector. No fitting.
  Immediately useful: a judged pair is a better take-choice than a measured one, so
  Part IV can consult labels directly before any model exists.
- **VI.4b** — the query strategy, so a session asks its most valuable questions first.
- **VI.4c** — fit the target/join weights. **Gated on having enough labels to beat
  hand-set weights on a held-out set** — and if it does not beat them, say so and
  keep the hand-set ones.

## VI.5 Constraints the dictionary must respect

- **Feature analysis costs ~109 s per uncached source.** `sound_sentence` imputes
  costs from the median for uncached sources and reports how many were imputed;
  `warm: true` forces analysis first. **The UI must not block on this.** Warm in the
  background and show which takes are scored versus imputed.
- **Lattice costs are min-max normalised within one lattice**, so two sentences'
  totals are **not comparable.** Do not build a UI implying they are.
- **`sound_apply` is trust-gated** and is the only verb that changes what the machine
  does when nobody is watching. **The dictionary must not route sounds** — keep
  installation a separate, deliberate act.
- **Assembly defaults:** `pad_ms: 30`, `fade_ms: 8`, `gap_ms: 60`, `normalize: true`.
  Keep `fade_ms` well below `pad_ms` or word onsets get eaten. Below ~40 ms gap words
  slur; above ~150 ms it reads as dictation.
- **`sound_probe` rejected a `source` parameter** in CLI testing on 08-09. Confirm its
  actual argument name before wiring it up.
- **The dev server at :4000 returns HTTP 500 with a `CompileError` page mid-recompile.**
  Observed three times during the source research. Any polling UI must tolerate it.

## VI.6 Explicitly out of scope

- **Sub-word / phoneme splicing.** This is what broke the 3/10 attempt: `ball` was a
  /b/ off *"bus"* plus *"all"*; `take` was three fragments each under 200 ms spliced
  at zero gap. **Phonemes do not have stable edges** — the /t/ in *"to"* is already
  coarticulated with what follows, so cutting at phone boundaries puts the seam
  exactly where the information is. The field's answer decades ago was **diphone**
  units, cut from the middle of one phone to the middle of the next. That needs
  diphone indexing and a different data model: separate project. **The UI must not
  offer it.**
- **A recogniser.** Settled and re-settled. Whisper is not coming back. Better timings
  come from hand-correction and `sound_find`, not a model.
- **2D similarity maps** (the CataRT / AudioStellar model). Beautiful for timbre,
  wrong for speech — the operator wants a *specific word*, and a word list is a better
  index than a cloud. Revisit only if browsing by prosody becomes a real need.
- **Non-speech search.** There is no sound classifier; *"find the door slam"* cannot
  be answered.
- **Scraping general YouTube content.** Closed in V.1. Do not re-research it.
- **Merging voice banks.** V.0.

## VI.7 One finding about the verb surface itself

Not about audio. The 3/10 sentence was assembled by hand-picking spans out of
`sound_index_search` and passing them to `sound_assemble` — **when `sound_sentence`
already does exactly that properly**, with a unit-selection lattice that scores
candidates and picks the cheapest path. The verb existed and was not known about.

**The verb surface has outgrown what a person or an agent can hold in their head.**
A UI that makes the corpus and its verbs visible has value beyond word-picking, and
that is a second, independent argument for VI.1.

## VI.8 Open questions for the operator

1. **Is the donor session actually going to happen?** The entire ordering rests on
   it. If yes, V.4–V.8 are the critical path. If no, the answer is LibriTTS as a
   separate bank (V.2) and Part VI becomes the whole map.
2. ~~**Where does the dictionary live?**~~ **ANSWERED 08-09 — see VI.0b.** Two
   sub-tabs in the home Studio tab, `Mix` and `Voice`, on the Explore tab's
   rail-and-registry pattern. It sidesteps the `FROZEN` component entirely: Mix
   renders it unchanged and Voice is a sibling, so no extraction is needed to start.
3. **VI.2 or VI.3 first?** See VI.3.
4. **Wired mic or built-in?** The built-in at 48 kHz is genuinely fine and is what is
   attached. A cheap USB dynamic would be better, is not a blocker, and should not
   delay anything.
5. **How much does agent-addressable recording matter?** If `sound_record` (V.9) is
   valuable on its own it could move much earlier, since it works today with no
   packaging changes. If it is only there for consistency, it stays last.

---

# Part VII — Open space

The operator said on 08-08 that several Studio additions were in mind; one of
them — the transcriber and ramshackle sentences — became Part II and Part III.
**This part is what is left: genuinely unscoped, and deliberately not padded with
guesses.** Anything that arrives here should get its own scoping pass rather than
being appended to a phase list that has already been built against.

**Known candidates already on file, neither committed to:**

- **The chime designer** (`../agent-core/LEFTOVERS_AGENT_CORE.md`) — `SoundGen`'s five-field tone spec as
  an editor, with the shipped 16 as starting points so *tuning* is the common
  path. `LEFTOVERS` says explicitly it should be **promoted back to its own
  roadmap** if genuinely wanted rather than picked up as a leftover. If it lands
  here instead, say so there.
  **Carries one hard constraint:** preview must go through WebAudio, **not a
  `blob:` URL** — the CSP declares no `media-src`, so media falls back to
  `default-src 'self'`, which excludes `blob:`. A blob preview works in dev and
  fails only in the packaged app. `dtmf.js` is the precedent.
- **The `nosniff` gap on four media routes** (now gate `G-35`) — belongs to
  the security surface rather than to a Studio feature, but it is Studio-adjacent
  and nobody has owned it since the music build found it.

---

## Open questions carried forward

- **Mix-level verbs** (the open question above): still undecided, and now
  answerable. The clip verbs exist and are used; the question was always whether
  a multi-track arrangement authored *blind* is worth the second half of the
  vocabulary. **Decide from whether anyone reaches for the clip verbs first.**
- ~~Does `sound_probe` need decode-on-demand?~~ **ANSWERED 08-08: yes, shipped
  as opt-in `decode: true`.** Measured ~4.6 ms per second of audio plus ~40 ms
  fixed subprocess cost — 278 ms for a 54.5 s voicemail against 23 ms for the
  header-only default. **And it immediately paid for itself: the operator's real
  voicemails peak at ~0.96, near the rail** — which is exactly the fact the
  default probe could not see, and it means `normalize` has almost nothing to
  do on this corpus while clipping on assembly is a live risk.
- **What does the tuned DTW threshold turn out to be** (Part III)? It cannot be
  guessed from a fixture, and the roadmap warns it may cost as long as the
  algorithm did.

## Tail items

- `sound_studio_component.ex` is **1,235 lines** and `StatusLive` (1,460) owns six
  studio assigns. Neither blocks this roadmap — the CLI talks to the domain
  modules, not the component — but both are on the decomposition list in
  the leftovers maps, and Studio work is what grows them.
- Check whether `Sound.install_bundled/0` should be reachable as a verb. It is
  the "restore the defaults" path and an agent that has just overwritten a chime
  is exactly who needs it.
- **Two verb names are provisional**: `sound_index_words` / `sound_index_search`
  were renamed from `sound_words` / `sound_word_search` during Part II so that
  everything producing *cuttable* spans shares the `sound_index_*` prefix and
  everything producing timing-less text shares `sound_transcript_*`. Mechanical
  to revert across three files if the shorter names read better in practice.
- **The corpus lives outside the dev workspace.** All 10 recordings are under the
  configured DataZone; `tmp/dev-workspace` has none, so transcript search returns
  nothing in dev unless `with_recording: false`. `sound_corpus` reports this as a
  number rather than as a failure. Worth remembering that the DataZone sits on
  iCloud Desktop, which this project's own history records as having evicted
  files before — an audio corpus is exactly what iCloud likes to reclaim.
