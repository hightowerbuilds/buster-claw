# The Studio — giving the agent a room it can enter

**Scoped 08-08-26 · Status: ACTIVE — Part I Phase 0 and Part II Phases A+B SHIPPED
08-08-26 (`e1088c2`).**

**Shipped so far:** thirteen `sound_*` verbs (catalog 162 → 175), the word-index
contract, the assembly engine, and transcript search over the recordings the app
already holds. **2,605 tests green.** What remains is the write half of the CLI
(Part I Phase 1), and the recogniser question — which the operator has answered:
**build our own** (Part III).

**What this is, in one line:** a `sound_*` command surface so the Studio's
cutting, arranging and routing are reachable by the agent, not only by a person
with a mouse.

**Why now.** Every other authoring surface in this product is agent-addressable.
The Studio is the one room the agent cannot enter, so *"turn that voicemail into
my notification chime"* is a thing the app can do and the assistant cannot. This
was `SOUND_STUDIO_ROADMAP`'s Phase 2, never built, and has sat in `LEFTOVERS.md`
since 08-02 with the honest note that it *"doesn't get expensive; it stays
absent, which is the actual cost."*

**How the parts relate.** Part I is the command surface — the substrate
everything else is reached through. Part II is the cut-up feature the operator
asked for. Part III is the recogniser that fills its index, built here rather
than bought. Part IV is open space for additions not yet scoped.

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
`:studio_redo` live in `StatusLive` assigns, held there because the tab's `:if`
discards the component on every tab switch. **There is no "currently open mix"
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
  guide in `LEFTOVERS.md`: a system-prompt string is neither runtime-loadable nor
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
> reasons it was cut, and `LAUNCH_ROADMAP` is still waiting on **G-2** with
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

# Part IV — Open space

The operator said on 08-08 that several Studio additions were in mind; one of
them — the transcriber and ramshackle sentences — became Part II and Part III.
**This part is what is left: genuinely unscoped, and deliberately not padded with
guesses.** Anything that arrives here should get its own scoping pass rather than
being appended to a phase list that has already been built against.

**Known candidates already on file, neither committed to:**

- **The chime designer** (`LEFTOVERS.md`) — `SoundGen`'s five-field tone spec as
  an editor, with the shipped 16 as starting points so *tuning* is the common
  path. `LEFTOVERS` says explicitly it should be **promoted back to its own
  roadmap** if genuinely wanted rather than picked up as a leftover. If it lands
  here instead, say so there.
  **Carries one hard constraint:** preview must go through WebAudio, **not a
  `blob:` URL** — the CSP declares no `media-src`, so media falls back to
  `default-src 'self'`, which excludes `blob:`. A blob preview works in dev and
  fails only in the packaged app. `dtmf.js` is the precedent.
- **The `nosniff` gap on four media routes** (`LEFTOVERS.md`, HIGH) — belongs to
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
  `LEFTOVERS.md`, and Studio work is what grows them.
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
