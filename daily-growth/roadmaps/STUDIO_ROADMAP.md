# The Studio — giving the agent a room it can enter

**Scoped 08-08-26 · Status: SCOPED, nothing built.**

**What this is, in one line:** a `sound_*` command surface so the Studio's
cutting, arranging and routing are reachable by the agent, not only by a person
with a mouse.

**Why now.** Every other authoring surface in this product is agent-addressable.
The Studio is the one room the agent cannot enter, so *"turn that voicemail into
my notification chime"* is a thing the app can do and the assistant cannot. This
was `SOUND_STUDIO_ROADMAP`'s Phase 2, never built, and has sat in `LEFTOVERS.md`
since 08-02 with the honest note that it *"doesn't get expensive; it stays
absent, which is the actual cost."*

**Further phases are expected.** The operator has additions in mind that are not
yet in this document — Part III is a deliberate placeholder. The CLI is scoped
first because it is the substrate the rest will want.

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

# Phase 0 — The read half

*Shippable alone, entirely `:safe`, and it is what makes the write half
debuggable.*

- [ ] `commands/catalog/sound.ex` + `commands/sound.ex`, registered in
  `catalog.ex` and delegated from `commands.ex`.
- [ ] `sound_list` — the library, **both layers, showing which wins**. Bundled
  defaults and workspace files share a namespace and the workspace shadows the
  bundle; a listing that hides that is how "I replaced the chime and nothing
  changed" happens.
- [ ] `sound_routes` — the routing table: every key from `Sound.route_keys/0`,
  its human label, and what is currently routed to it. This is the map the agent
  needs before it can sensibly propose a change.
- [ ] `sound_sources` — the Studio's imported clips (`sounds/studio/`).
- [ ] `sound_probe` — format, duration, peak, and whether a file is already in
  the studio's internal format. Wraps `probe/1` + `peak/1` + `duration_ms/1`.
  **This is the agent's only substitute for ears** and it is the reason the read
  half ships first.
- [ ] Tests: every verb against a tmp workspace; the shadowing case is asserted
  explicitly; a nonexistent name returns a named error rather than raising.

**Done when:** the agent can describe the sound library completely and correctly
without touching anything.

# Phase 1 — The write half, clip-level

- [ ] `sound_import` — a file into `sounds/studio/`, via `import_source/1`.
  Decoder-dependent: `decoder_available?/0` exists and must be reported, not
  assumed. Non-WAV input on a machine without the decoder is a clear refusal.
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

# Part III — Ramshackle sentences: cutting speech out of found audio

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

**Phase A — the index format and the assembly engine.** Define the word index.
Build `sound_assemble` (take an ordered list of index entries → padded, faded,
normalized `splice` + `concat` → a new file) and search over indexes. **Prove the
whole feature end to end against a hand-authored index fixture, with no
transcription in the codebase at all.** If this phase is right, everything after
it is a matter of filling indexes.

**Phase B — search the transcripts that already exist.** `Telephony.Event` already
carries a `transcript` field from Twilio. That is text without timings — useless
for splicing, **genuinely useful for discovery**: *"which recordings say
harbor?"* Zero new dependencies, ships alone, and it is the half the agent will
reach for first.

**Phase C — `SFSpeechRecognizer`, for the timings.** A Swift/ObjC shim behind a
Rust command, producing the Phase A index from a file URL. Needs
`NSSpeechRecognitionUsageDescription` and the Speech Recognition TCC prompt —
**not** the microphone entitlement.

> **Do not land Phase C before the first notarized build.** The Whisper
> post-mortem names *"an unproven notarization/entitlement gamble on the
> Apple-signing critical path"* among the reasons it was cut, and
> `LAUNCH_ROADMAP` is currently waiting on **G-2**, the Developer ID certificate,
> with **nothing ever notarized or stapled**. Adding a new entitlement and a new
> native dependency to a signing path that has never once succeeded is how a
> release slips for reasons that have nothing to do with the feature. Phases A
> and B are entitlement-free by construction; take them first, and add C once
> there is a known-good notarized baseline to diff against.

**Phase D — non-speech: onset and silence detection.** Windowed RMS in pure
Elixir. Serves "or sounds", needs no permission, and is independently useful for
trimming leading silence off any clip.

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

# Part IV — The operator's other additions *(placeholder — not yet scoped)*

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

## Tail items

- `sound_studio_component.ex` is **1,235 lines** and `StatusLive` (1,460) owns six
  studio assigns. Neither blocks this roadmap — the CLI talks to the domain
  modules, not the component — but both are on the decomposition list in
  `LEFTOVERS.md`, and Studio work is what grows them.
- Check whether `Sound.install_bundled/0` should be reachable as a verb. It is
  the "restore the defaults" path and an agent that has just overwritten a chime
  is exactly who needs it.
