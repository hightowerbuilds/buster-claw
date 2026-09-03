# The Voice — one synthesizer, and the room it replaces

**Scoped 09-02-26 · Status: BLOCKED ON PART 0's QUALITY GATE. Two halves that
only make sense together.**

> **Where it actually stands (09-02-26).** Part 0 ran and stopped: **this machine
> cannot run VoxCPM by any Python route** — see *Part 0 — what it actually
> measured*. Nothing has been deleted and nothing needs to be yet. One guard
> landed (`describe "the external-render bridge"`), chosen because it is true
> under every outcome below. **The one thing standing between here and a decision
> is ten minutes on `openbmb/VoxCPM-Demo`:** does the clone sound like him. The
> seven open questions at the foot of this file are still open.

> **The decision.** The Studio's cut-up engine — 7,947 lines of hand-written
> MFCC, DTW, VAD and unit selection — is **deleted**, and **VoxCPM** takes over
> the job it was built to do. The app gains a real text-to-speech engine that can
> speak in the operator's own voice, and loses the machine that tried to reach
> the same place by splicing recordings of words he had already said.
>
> **This is a ~35,000-line deletion and a ~3,000-line build.** Roughly **19% of
> the codebase** goes. That ratio is the argument, not a side effect: the
> replacement is smaller than the thing replaced by an order of magnitude,
> because the hard part moves out of our repo and into a 2B model under
> Apache-2.0.

**Supersedes [`STUDIO_ROADMAP.md`](STUDIO_ROADMAP.md) Parts I–VI.** That map is
archived unfinished, and its Parts V and VI — the donor recording session and the
word dictionary — are **cancelled rather than deferred**. Both existed to solve
"the corpus has 238 distinct words and cannot say an arbitrary sentence." A model
that clones a voice from seconds of reference audio dissolves that problem
instead of grinding it down. Part VII (open space) has nothing in it.

**Does not touch the Sketch Pad.** [`SKETCH_ROADMAP`](SKETCH_ROADMAP.md) is a
live map for a surface that shares a route with the thing being deleted and
nothing else. See **VI.1** for what happens to `/studio` when two of its three
tabs go.

---

## Read this first — the four things that are not obvious

**1. The notification layer is already clean of the Studio.** Every module in
the surviving chime path — `Notifications.Sound`, `SoundBoard`, `SoundGen`,
`Schedule`, `Scheduler`, `Notification`, `AudioName` — has **zero** `alias`,
`import` or call into `SoundStudio`, `StudioMix`, `Cutup.*` or `Capture.*`.
Measured 09-02 by reading every `alias` line in all seven. The four places a grep
says otherwise (`notifications/sound.ex:335`, `audio_name.ex:6`,
`workspace.ex:257`, `commands.ex:624`) are **comments**. The cut is clean, and it
is clean by luck rather than design — nothing asserted it, and nothing will
assert it afterwards either.

**2. `sound_apply` is the bridge, and it already exists.** The one gated verb
that installs an audio file into the chime library and routes an event key to it
takes a *studio source* as input. Repoint that one function at the VoxCPM output
directory and the entire notification integration is done — no new publish path,
no new gate, no new trust decision. **The seam we need was cut for a different
feature and fits.**

> **Half right, corrected 09-02-26 — see "Correction to Read this first #2"
> below.** The seam does fit and needs no new gate. But it is not a *repoint*:
> `sound_apply` pattern-matches the `%SoundStudio{}` struct and reads its `bits`
> field, so it is welded to the module this roadmap deletes. Extracting the WAV
> codec is the critical path, not a sub-item.

**3. Chat is the hard half, not the easy one — and the reason is arithmetic.**
VoxCPM's best measured Apple Silicon figure is **RTF ≈ 1.76 on an M4 Pro**
(Q8_0, llama.cpp-omni). RTF > 1 means rendering is slower than speaking. A
streaming reader can never catch up; the gap grows with every sentence. Add
model load — tens of seconds per cold CLI invocation — and naive substitution
for `say(1)` makes voice chat unusable. **Notifications have lead time and chat
does not**, which is why the plan pre-renders everything it can and treats the
chat case as an explicitly asynchronous one.

**4. The file-size gate fails the moment you delete anything.**
`scripts/check_file_sizes.sh` fails when a capped file *does not exist*, and
**32 of its 152 entries are files this roadmap deletes.** Four more —
`studio_panel.ex`, `studio/registry.ex`, `studio_live.ex` and
`notifications/sound.ex` — survive but shrink, and the gate **fails a file far
under its cap too** (the ratchet, at 80%), so their caps must be lowered in the
same commit that earns it. Only Sketch's two entries are untouched. `mix
precommit` is red from the first deleted file until the script is edited
alongside. That is the gate working as designed; it is listed here so nobody
discovers it mid-demolition and "fixes" it by loosening the gate.

---

## Part 0 — The measurement that decides everything

**Before a line of app code, and before a line is deleted.** Sequence by risk:
everything below assumes VoxCPM is usable on this machine, and nobody has run it
on this machine.

**0.1 — Install it outside the repo and time it.** A venv in
`~/.buster-claw/voxcpm`, `pip install voxcpm`, weights pulled once. Then measure,
writing every number down:

| Measure | Why it decides something |
|---|---|
| Cold `voxcpm design` wall-clock for a 10-word line, `--device mps` | The CLI-mode floor. If this is 90 s, per-notification rendering at schedule time is out and only batch pre-rendering survives. |
| The same line again, warm page cache | Separates model load from inference. These two numbers pick the engine mode. |
| `voxcpm batch` over 18 short lines, one invocation | The notification chime set in one shot. This is the number that makes **Part IV** cheap or not. |
| Peak RSS during a render | A 2B model on a 16 GB Mac while Chrome, the BEAM and a Claude Code session are running. If it swaps, the app must serialize renders and say so. |
| `--device cpu` vs `--device mps`, same line | Whether MPS works at all for this architecture. Not assumed. |
| Disk after install: venv + weights | The number the operator is being asked to accept. Expect multiple GB. |
| A cloned line from 10 s of the operator's voice, `clone --reference-audio` | **The quality verdict.** Everything below is worthless if it does not sound like him. |
| The same, with `--prompt-audio` + `--prompt-text` (ultimate cloning) | Whether a transcript is worth demanding from the recorder. |

**0.2 — Pick the variant.** Three exist and they are not interchangeable:

| Variant | Params | Rate | Note |
|---|---|---|---|
| `openbmb/VoxCPM2` | 2B | 48 kHz | 30 languages, voice *design* from a text description, reference-audio cloning. The CLI's default. |
| `openbmb/VoxCPM1.5` | 0.6B | 44.1 kHz | Middle. |
| `openbmb/VoxCPM-0.5B` | 0.5B | 16 kHz | Chinese + English only. No voice design. |

**Recommendation: measure 2B first and 0.5B as the fallback**, because the whole
product argument is *the operator's own voice* and cloning quality is what buys
that. But 16 kHz is not a disqualifier for this app — every chime we ship is
22.05 kHz mono and the phone path is 8 kHz by the time Twilio is done with it.
**If 2B is too slow and 0.5B sounds acceptable through a phone and a chime, 0.5B
wins on every other axis.**

**0.3 — Try `llama.cpp-omni` + GGUF only if PyTorch/MPS disappoints.** It is the
route the RTF 1.76 figure comes from, it removes the Python dependency entirely,
and it is a C++ binary of the shape this app already spawns (`afconvert`,
`ffmpeg`). It is listed third because it is a build-from-source step to hand an
operator, and step 0.1 may make it unnecessary.

**0.4 — Write the numbers into this file before building.** Not into a summary,
not into a commit message. A measured RTF that lives in a chat log is a number
nobody can find in three weeks.

> **The gate.** If cloned output does not sound like the operator, **stop and come
> back to this document.** The deletion is still probably right — the cut-up
> engine scored 3/10 on its own acceptance sentence — but "delete the Studio" and
> "ship VoxCPM" become two separate decisions instead of one.

---

## Part 0 — what it actually measured (09-02-26)

**Part 0 ran and stopped at the first step, for a reason 0.1 did not anticipate:
this machine cannot run VoxCPM by any Python route, and no amount of RAM changes
that.** Everything above assumes Apple Silicon — `--device mps`, "best measured
Apple Silicon figure", "RTF ≈ 1.76 on an M4 Pro". The dev machine is not one.

**The machine.** `MacBookPro16,1` — 2019 16-inch, **Intel Core i9-9980HK,
x86_64**, 32 GB, macOS 26.6.2. Not Rosetta: `hw.optional.arm64` and
`sysctl.proc_translated` are both unknown OIDs, which they would not be under
translation.

**The wall, with receipts:**

| Measured | Result |
|---|---|
| `voxcpm` 2.0.3 declared requirement (read from wheel METADATA) | **`torch>=2.5.0`** |
| Last `torch` release with a macOS **x86_64** wheel (PyPI release index) | **2.2.2** |
| macOS x86_64 wheels in torch 2.3.0 → 2.14.0 | **zero**, every release; arm64 only |
| `pip index versions torch` on this machine | `No matching distribution found` |
| `onnxruntime` 1.29.0 macOS wheels | 0 x86_64, 4 arm64 |
| `mlx` | arm64 only, by construction |
| Apple Neural Engine builds (`seba/VoxCPM-ANE`) | Intel Macs have no ANE |

So the gap is **architectural and permanent**, not a pin to nudge. RAM was never
the constraint — fp16 weights for a 2B model are ~5 GB. **A 128 GB Intel Mac Pro
fails identically; a base 8 GB M1 Air would work.** That is the shape of any
hardware decision made for this feature.

**What survives on this hardware: 0.3, and only 0.3.** llama.cpp-omni + GGUF,
built from source for x86_64, CPU-only. Weights are real —
`VoxCPM2-BaseLM-Q8_0` 1.73 GB, `voxcpm2-q4_k` 1.69 GB, `voxcpm2-f16` 4.97 GB.
**Two cautions before anyone spends a day on it:** upstream `ggml-org/llama.cpp`
shows almost no VoxCPM presence (two Metal-kernel PRs, both Apple-GPU work), and
two of the published GGUF repos are named `VoxCPM2-gguf-notcpp` — "not cpp",
i.e. those weights are for some other runtime. **0.3 is therefore not the third
option here, it is the only door, and it is thinner than a one-line mention
suggests.** Reorder 0.1–0.3 accordingly if this machine stays the dev machine.

**What Part 0 did NOT measure, deliberately: the quality verdict.** It is the
actual gate and it is architecture-independent, so it does not need this machine
— `openbmb/VoxCPM-Demo` on HF Spaces (747 likes) answers it in ten minutes with
no install. **No RTF figure was invented for this CPU.** A speed number measured
on a 2019 Intel laptop describes a machine no user runs, and inventing one is
exactly what 0.4 exists to prevent.

### Correction to "Read this first" #2

**`sound_apply` is not a repoint.** The claim is that repointing one function at
the VoxCPM output directory finishes the notification integration. It does not,
because `sound_apply` is coupled to the Studio's *data type*, not just its
functions:

```elixir
# commands/sound.ex — editable_clip/1
case SoundStudio.read(path) do
  {:ok, %SoundStudio{bits: 16} = clip} -> {:ok, clip}
```

It pattern-matches `%SoundStudio{}` and reads its `bits` field, and
`studio_source/1` calls `SoundStudio.path_for/1`. `sound.ex` carries 43
`SoundStudio.` references. So the door every voice feature must come through is
welded to the module this roadmap deletes, and extracting the WAV codec is not a
sub-item — **it is the critical path.** Blast radius if the struct moves: 63
`%SoundStudio{}` literals across 22 files, but only **6 in surviving lib code**
(4 of them in `sound.ex`); the rest are in cut-up modules that die anyway. The
rename is compiler-enforced, so it is mechanical rather than risky.

### The good news: the bridge is a directory

`sound_import` takes any WAV on disk (`path`, relative to the Library root) and
normalizes it into `sounds/studio/`; `sound_apply` installs it and routes it.
**Neither verb cares what produced the audio.** So "make VoxCPM work here" needs
no inference plumbing in the app at all — it needs a WAV to appear in a folder,
which makes local-vs-hosted a logistics choice rather than an architecture one,
deferrable until the quality verdict is in.

Guarded on 09-02-26 by `describe "the external-render bridge"` in
`test/buster_claw/commands/sound_test.exs`: audio rendered by something else
walks in as a plain file and out as a routed chime, every step through
`Commands.call/3` by name. **That test is also the successor to "the acceptance
walk"**, which proves the same thing only for app-assembled audio and dies with
the cut-up engine it is built on (align → index_search → assemble).

Writing it turned up an unrelated defect worth keeping: **the RIFF chunk walker
had no hermetic coverage.** Of 106 tests in that file only 4 fail when the walk
is broken, and the 2 pre-existing ones are both `afconvert`-gated — one inside
`if @decoder_available`. On Linux CI a fixed-offset parser passed. The awkward
header in the new fixture is measured, not invented: `say -o out.wav
--data-format=LEI16@22050` emits a `JUNK` chunk that puts `fmt ` at byte 48.

---

## The lay of the land

### What speaks today — three mechanisms, all of them small

| Where | Mechanism | Lines |
|---|---|---|
| Chat readback | `desktop/tauri/src/voice.rs` → `/usr/bin/say`, one worker thread, a queue and a barge-in generation counter | 111 |
| BusterPhone greeting | `supabase/functions/voice/index.ts` → `<Say voice="Polly.Matthew">`, text from a `GREETING_TEXT` env var | 3 lines of TwiML |
| Notification chimes | `Notifications.SoundGen` synthesizes 16 WAVs at build time into `priv/static/sounds/`; `SoundBoard` maps events to keys; `Notifications.Sound` routes keys to files | 184 + 124 + 578 |

**Nothing in the app has ever produced speech from text.** `say(1)` is the OS
doing it and Polly is Amazon doing it. That is the gap this roadmap fills, and
it is worth saying plainly because the README's *"There is no LLM inside Buster
Claw"* needs a qualifier afterwards — see **VII.4**.

### What the Studio is, measured 09-02

| Piece | Lines | What it is |
|---|---|---|
| `notifications/cutup/` (16 files) | 7,947 | FFT, MFCC, subsequence DTW, VAD, proportional alignment, a Viterbi unit-selection lattice, bank isolation, transcript search |
| `commands/sound.ex` | 2,464 | 30 `sound_*` verbs (FROZEN in the size gate) |
| `notifications/studio_mix.ex` | 836 | the arranger's mix model |
| `notifications/sound_studio.ex` | 745 | the WAV toolkit — **a third of this survives, see below** |
| `notifications/capture*` (4 files) | 1,167 | AudioWorklet take handling, device enumeration, level metering |
| `notifications/studio*.ex` + `studio/` | 740 | catalog, effects, render |
| `commands/sound_capture.ex` + `catalog/sound.ex` | 731 | the capture verbs and all 34 catalog entries |
| `web/components/sound_studio/` (7 files) | 1,668 | arranger, catalog, clip inspector, edits, format, menu bar, overlays |
| `web/live/sound_studio_component.ex` | 973 | the Mix tab (HELD at 1,070, effectively frozen) |
| `web/live/studio/` + `web/studio/` + controller | 914 | mix state, recorder state, voice state, preview, file controller |
| `web/components/studio/{recorder,sentence,voice_library,words}.ex` | 842 | the Voice Library tab |
| `web/components/explained/studio.ex` | 431 | the tutorial |
| **lib total** | **19,498** | **19.3% of `lib/`** |
| tests | 14,167 | 20.7% of `test/` |
| `assets/js` | 1,734 | audition, keys, menu bar, context menu, wave trim, track arrange, audio clip, clipwave, + three `lib/` modules and their bun tests |
| **grand total** | **≈ 35,400** | |

**Corpus reality, for the record.** 10 voicemails, ~295 s, 655 tokens, **238
distinct words**, 144 of them single-take, alignment confidence median 0.42–0.81,
`sound_find` precision 0.88. The best sentence it ever made scored **3/10** and
needed two hand-tuned `Align` fixes to get from "garbled" to "sounds better".
That is not a criticism of the engineering; it is the honest ceiling of
concatenative synthesis on five minutes of phone audio, and it is why the
replacement is worth 35,000 lines.

### The four couplings that look load-bearing and are not

Verified 09-02 by reading each site:

| Site | What the grep hit | Reality |
|---|---|---|
| `notifications/sound.ex:335` | `StudioMix.safe_mix_name/1` | a comment citing a sibling's reasoning |
| `audio_name.ex:6` | "Music, Sound, the Studio, and StudioMix all share" | a moduledoc sentence |
| `workspace.ex:257` | "(Music.ensure/0, SoundStudio.ensure/0)" | a comment about who creates which folder |
| `commands.ex:624` | "one pure SoundStudio function each" | a comment about the editing verbs |
| `settings_live.ex:24`, `settings/models_component.ex:16` | `Studio.MixState` | both comments, citing MixState as precedent for holding state in the LiveView |

**All prose.** They break no build and they will all read false the moment the
modules go, which is the drift this repo has been bitten by three times. They are
listed so the demolition commit fixes them rather than a doc-drift comb finding
them in October.

### What the survivors actually need from the condemned

This is the finding that reshapes the demolition, and it is the reason
`sound_studio.ex` cannot simply be deleted:

- `Capture.Take` needs `SoundStudio.write/2`, `parse/1`, `duration_ms/1`,
  `peak/1`, `clamp16/1`, `internal?/1`, `dir/0`.
- `Commands.Sound.sound_apply/1` needs `path_for/1`, `read/1`, `internal?/1`.
- `StudioFileController` needs `path_for/1`, `content_type/1`.

**So the WAV codec survives and the editor dies.** `splice/3`, `fade/2`,
`normalize/2`, `mixdown/1`, `concat/1`, `render/1`, `save/2`, `rename/2` and the
`afconvert` import pipeline have no caller once the Mix tab and the editing verbs
go. See **I.4**.

---

## Decisions taken while scoping (revisit if wrong)

**D1 — The engine is BYO, discovered at runtime, and never bundled.** The signed
DMG is **27–29 MB** and the `.app` is 76 MB; `APPLE_ROADMAP` wants CI to fail on
a >10% size regression. A Q8_0 2B GGUF is ~2.1 GB, and the PyTorch route pulls
`torch`, `torchaudio`, `torchcodec`, `transformers`, `funasr`, `librosa`,
`gradio` and `datasets` — a multi-gigabyte environment. **Follow the `ffmpeg`
precedent exactly** (`notifications/capture.ex:49`): known locations first, then
`System.find_executable/1`, resolved *per call* so an operator who installs it
after boot is not told to restart.

**D2 — The floor is `say(1)`, and it never goes away.** Three rungs, and every
one of them is a complete product:

1. **No VoxCPM.** `say(1)` for chat, synthesized chimes for notifications, Polly
   for the phone. *This is today, unchanged.*
2. **VoxCPM CLI installed.** Notifications, chimes and the phone greeting speak
   in the operator's voice. Chat gains a per-message "speak this" that renders on
   demand with visible latency. Automatic chat readback still uses `say(1)`.
3. **A resident VoxCPM daemon running.** Automatic chat readback in the
   operator's voice, delayed and honest about it.

**Rung 3 is allowed to fail without touching rungs 1 and 2.** That is the whole
defence against the Browserbase shape — a sidecar prod never bundles, powering a
feature with no fallback, which had to be deleted whole at −2,158 lines.

**D3 — Nothing renders on a request path.** Every spoken thing this app produces
is rendered ahead of time and cached, or rendered on an explicit click that shows
a spinner. There is no code path where a user action waits on a model.

**D4 — The cache is content-addressed and permanent.** `sha256(text + voice +
engine params)` → `sounds/voice/lines/<hash>.wav`. Re-rendering the same line is
free, which is what makes a fixed chime set and a repeated notification cheap.
The cache is swept by age and total size, never by "the app restarted".

**D5 — One render at a time, process-wide.** A `GenServer` with a queue, the same
shape as `voice.rs`'s worker thread and for the same reason. Two 2B model loads
concurrently will swap a 16 GB Mac, and the failure mode is the whole machine
stalling, not a slow chime.

**D6 — A voice is a reference clip plus a label, and it lives in the workspace.**
`sounds/voice/refs/<name>.wav` beside `<name>.json`. Not a database row: the
operator can hear it in Finder, replace it, and back it up with everything else.
This inherits the Studio's **one voice, one channel** rule for the same reason it
was true there — a reference recorded over a Bluetooth headset at 8 kHz HFP
produces a clone of a bad phone line.

**D7 — Do not reuse the `studio.voice.*` Settings keys.** `studio.voice.banks`
and `studio.voice.active_bank` hold cut-up banks. New keys (`voice.profiles`,
`voice.active`), and the old two are **deleted** in the demolition commit. A
stale key that resurrects as something else is a bug that survives a rewrite.

**D8 — The operator's audio on disk is not ours to delete.** `sounds/studio/`
holds ten voicemails he imported. The demolition removes the *code*; the audio
stays where it is. The two derived caches under it — `sounds/studio/index/` and
`sounds/studio/features/` — are swept once, because after the deletion nothing
can read or regenerate them and `features/` is the larger of the two by a wide
margin (109 s of computation per source, cached).

**D9 — The recorder survives, stripped.** `voice_recorder.js`, `lib/meter.js`,
`Capture.Devices`, `Capture.Level` and the encoder half of `Capture.Take` are the
only microphone path this app has, and **VoxCPM makes them 50× cheaper to use** —
seconds of reference audio instead of the 30–60 minutes of phonetically balanced
sentences `STUDIO_ROADMAP` V.8 was asking for. What goes is `Take`'s index
bookkeeping (`Cutup.Align`, `Bank`, `Dtw`, `Gaps`, `Index`, `Vad`).

**D10 — Day one does not depend on the microphone.** Dropping a `.wav`/`.m4a`
into `sounds/voice/refs/` is the reference path that works today. The recorder is
better UX and is unproven — `getUserMedia` has never run in a packaged build —
so it must not gate anything. See **VII.1** for a finding that changes the odds
on that spike.

**D11 — Spoken notifications are a *layer*, not a replacement.** A chime is 200 ms
and a spoken line is 2 s. A person who wants to know a timer fired does not always
want a sentence. So: **chime, then optionally speak**, per route key, defaulting
to chime-only. The routing map already stores a per-key value; this is a second
map beside it, not a change to the first.

**D12 — The 18th route key is dead and does not get a voice line.** `order` has a
label, a synthesized chime and a routing slot, and **nothing rings it** —
`SoundBoard.event_key/1` emits `blocked · confirm · email · security · shift ·
sms · voicemail · web`, `ring/1` adds `chat` and `boot`, and the notification
kinds add `timer · alarm · reminder`. `order` was a Trading key and Trading was
deleted 08-08. Do not render a line for a key nothing can fire; **fix or remove
the key** as a separate one-line change with its own reasoning.

**D13 — The phone greeting is a `<Play>`, not a `<Say>`, and the WAV lives in
Supabase Storage.** The `recordings` bucket already exists and the Mac already
uploads to and deletes from it. Rendering the greeting on the Mac and pushing it
up is the whole mechanism. **This is the single highest-value use of the engine
in the product** — it is the first thing every caller hears, on the money leg.

**D14 — No new Tauri command.** Rendered audio is served by Phoenix from a
`:media` route and played by an `<audio>` element, exactly like
`/notify/sound/:name` and `/music/track/:name`. CSP declares no `media-src`, so
media falls back to `default-src 'self'` and a same-origin URL is fine. Adding a
Rust playback command would need three registrations (`build.rs` AppManifest,
`capabilities/default.json`, `generate_handler`) plus the ACL lockstep test, and
buys nothing.

**D15 — `voice_render` is `:restricted`; `voice_greeting_set` is `gated`.**
Rendering writes a file and costs a minute of CPU — restricted. Setting the
public greeting changes what strangers hear when they call the operator's number,
which is a stronger case for a gate than `sound_record`'s microphone: an
`:agent_untrusted` run acting on content it did not choose must not be able to
rewrite it. `sound_apply` keeps its existing gate unchanged.

**D16 — Never claim a voice the engine cannot produce.** Every surface reads the
probe. Absence is reported with a reason and a next step, never as an empty list
or a disabled button with no explanation. This is the `decoder_available?`
posture that `sound_sources` already takes for `afconvert`.

---

## The order to build in

Risk first, then value. The subject-organised Parts below are for reading; **this
is the sequence.**

| # | What | Gate | Why here |
|---|---|---|---|
| 1 | **Part 0** — measure VoxCPM outside the repo | none | Nothing below is knowable until this is done, and a bad answer changes the plan rather than the schedule |
| 2 | **VII.1** — add `NSMicrophoneUsageDescription` | none | One line, and it is on the critical path for every reference-audio story. See the finding |
| 3 | **Part I** — demolition, in nine ordered commits | Part 0 says go | Independent of the engine; unblocks the size gate and shrinks everything below |
| 4 | **Part II** — the engine: probe, queue, cache, four verbs | I complete | The substrate all three surfaces call |
| 5 | **Part IV.1** — the fixed spoken chime set (18 lines, one `voxcpm batch`) | II | The cheapest real thing the engine can do, and it exercises the whole path |
| 6 | **Part VI** — the Voice tab | II | Where a person makes a profile and hears it. Everything else is unusable without it |
| 7 | **Part V** — the phone greeting | II, VI | The highest-value single output in the product |
| 8 | **Part IV.2** — spoken notification labels, rendered at schedule time | IV.1 | Needs the lead-time trick proven |
| 9 | **Part III.1** — chat: per-message render on demand | II | Cheap, and it is the honest form of chat voice |
| 10 | **Part III.2 + the daemon** | everything | The riskiest thing here. Allowed to fail |

---

## Part I — Demolition

**Nine commits, ordered so the tree compiles after each one.** The ordering rule:
*delete callers before callees.* A leaf module deleted first leaves a compile
error in five places and tempts a rushed patch; a caller deleted first leaves an
unused module that the next commit removes cleanly.

> **Staging discipline.** Other sessions write into this tree. `git status` and
> **explicit paths** on every `git add` — never `-A`. A deletion this size across
> nine commits is exactly where a stray file from another session gets swept into
> a commit whose message says something else entirely. This has already cost one
> polluted commit (`843d3b1`).

### I.1 — The Mix tab

Delete `live/sound_studio_component.ex`, `components/sound_studio/` (7 files),
`live/studio/mix_state.ex`, `web/studio/preview.ex`,
`controllers/studio_file_controller.ex` and the `/studio/file/:name` route. Drop
`"mix"` from `Studio.Registry`'s `@tabs` and `@built`, and its dispatch clause
from `StudioPanel`. Delete `assets/js/hooks/{studio_audition,studio_keys,
studio_menu_bar,studio_context_menu,wave_trim,track_arrange,audio_clip}.js`,
`assets/js/audio/clipwave.js`, `assets/js/lib/{arrange,audition,trim}.js` and
their three bun tests, and every corresponding line in `hooks/index.js`.

**The two-directional hook guard fires here.** `hooks_registered_test.exs` fails
on a registered-but-unnamed hook — that check exists *because* the 08-08 Trading
deletion left two dead hooks shipping in every page load for five days. Removing
the markup and leaving the `index.js` export is the exact failure it catches.

Tests: `sound_studio_component_test.exs`, `clip_actions_test.exs`,
`studio_mix_test.exs`, `studio/effects_test.exs`, `studio/render_test.exs`.

**Consequence to state out loud:** the music library's tracks appeared as
*material* in the Mix tab's catalog. `MusicComponent` (the manager: upload,
delete, queue, play-all) was already deleted 08-16. After this commit the dock
player is the only place music appears, and adding a track means dropping a file
in `sounds/music/`. That is acceptable; it is written here so it is a decision
rather than a discovery. **`SUPERMAP` Part III's "Music library — `MusicComponent`
(inside Studio → Mix)" row is already stale and must be fixed in this commit.**

### I.2 — The Voice Library tab

Delete `components/studio/{voice_library,words,sentence,recorder}.ex`,
`live/studio/{voice_state,recorder_state}.ex`, `assets/js/hooks/voice_audition.js`.
Drop `"voice"` from the registry and its dispatch clause.

**Keep** `assets/js/hooks/voice_recorder.js` and `assets/js/lib/meter.js` — D9.
They are orphaned for exactly as long as **Part VI** takes, and the hook guard
will fail on the orphan, so either Part VI lands in the same branch or the hook
registration is removed here and restored there. **Say which in the commit
message**; a hook that disappears and reappears with no note reads as a mistake.

Tests: `voice_library_test.exs`, `studio/voice_state_test.exs`,
`studio_panel_test.exs` (partial — it also covers Sketch).

### I.3 — The command surface

Delete `commands/sound_capture.ex`, and from `commands/sound.ex` and
`commands/catalog/sound.ex` remove **30 of the 34 entries**:

`sound_align · sound_assemble · sound_concat · sound_corpus · sound_delete ·
sound_devices · sound_fade · sound_find · sound_gaps · sound_import ·
sound_index_delete · sound_index_import · sound_index_list · sound_index_search ·
sound_index_words · sound_input_level · sound_input_level_set · sound_normalize ·
sound_probe · sound_record · sound_record_save · sound_sentence · sound_sources ·
sound_transcript_search · sound_transcript_words · sound_trim · voice_bank_create ·
voice_bank_delete · voice_bank_list · voice_bank_select`

**Four survive**, and all four read or write the *chime library*, not the Studio:
`sound_list`, `sound_routes`, `sound_apply` (gated), `sound_restore_defaults`.
`commands/sound.ex` goes from 2,464 lines to roughly 300 and stops being the
FROZEN file `LEFTOVERS_AGENT_CORE` has been owed a split of since 08-13 — **the
oldest open item in that map is closed by deletion**, which is worth saying in
the commit.

`sound_apply`'s `studio_source/1` is repointed at `sounds/voice/lines/` in
**Part II**; until then it is repointed at the chime library itself, so the verb
is coherent at every commit rather than briefly nonsense.

**`sound_input_level` / `sound_input_level_set` are a judgement call.** They set
the OS input volume and have nothing to do with cut-up. They are listed for
deletion because after I.2 nothing in the app records except the Part VI
recorder, and if that recorder wants a level control it should have a slider, not
two agent verbs. **Flagged for the operator** — reinstating them later is two
catalog entries.

### I.4 — Extract the WAV codec, then delete the editor

**In this order, in two commits, because the second is not reviewable otherwise.**

**I.4a** — new `BusterClaw.Audio.Wav` carrying only what survives: `parse/1`,
`read/1`, `write/2`, `probe/1`, `duration_ms/1`, `peak/1`, `clamp16/1`,
`internal?/1`, `internal_format/0`, `content_type/1`, `frame_bytes/1`,
`samples/1`, `map_samples/2`. Callers updated. `sound_studio.ex` keeps everything
and delegates, so this commit changes no behaviour and the diff is a move.

**I.4b** — delete `sound_studio.ex` whole, along with `splice/3`, `fade/2`,
`normalize/2`, `mixdown/1`, `concat/1`, `render/1`, `store/2`, `save/2`,
`rename/2`, `delete/1`, `list/0`, `ensure/0`, `import_source/1`,
`decoder_available?/0`, `accepted_extensions/0` and the `afconvert` decode path.
Delete `studio_catalog.ex`, `studio_mix.ex`, `studio/effects.ex`,
`studio/render.ex`.

> **`import_source/1` and `decoder_available?/0` are the two to argue about.**
> They shell to `/usr/bin/afconvert` to turn a dropped `.m4a` into the internal
> WAV format. VoxCPM reads `.m4a` itself via torchaudio, so the *reference* path
> does not need them — but a dropped reference clip still wants probing, and
> **Part VI** may want to normalize one. **Recommendation: keep both, in
> `Audio.Wav`.** They are ~40 lines, they are tested, and rewriting an afconvert
> wrapper in November is a worse outcome than carrying one.

### I.5 — The cut-up engine

Delete `notifications/cutup/` entire (16 files, 7,947 lines) and
`test/buster_claw/notifications/cutup/` entire (6,101 lines). By this commit
nothing references it; if anything does, an earlier commit was wrong and this is
where that shows.

### I.6 — Capture, stripped

Delete `notifications/capture.ex` (the `ffmpeg` path — its own moduledoc says it
can return digital silence with exit code 0, and D10 puts the reference path on a
file drop). Keep `capture/devices.ex` and `capture/level.ex`. Rewrite
`capture/take.ex` down to its encoder half: Float32 → PCM16 → `Audio.Wav.write/2`,
plus the silence and clipping checks. Everything touching `Cutup.Align`, `Bank`,
`Dtw`, `Gaps`, `Index`, `Vad` goes.

**This is the one file in the demolition that is edited rather than deleted, and
it is where a mistake hides.** Its tests (`capture/take_test.exs`, 379 lines of
subject) must be pruned rather than deleted, and the encoder assertions must
survive. **Break the guard before trusting it**: reintroduce a silent-take bug and
watch the pruned test fail.

### I.7 — Settings, workspace and derived state

- Delete the `studio.voice.banks` and `studio.voice.active_bank` Settings rows
  (D7) with a one-off migration or a boot sweep — say which and why.
- Sweep `sounds/studio/index/` and `sounds/studio/features/` (D8). **Leave
  `sounds/studio/*.wav` alone.**
- Update `workspace.ex`'s `sounds` entry note — it names `studio/` as "the Sound
  Studio's working files".
- **Do not touch the `{"studio", "sounds/studio"}` relocation.** It folds a
  pre-08-01 layout forward and an install that skipped a release still needs it.

### I.8 — The gates

- `scripts/check_file_sizes.sh`: **remove 32 entries and re-cap 6.** The script
  fails on a capped file that does not exist, so this is not optional and not
  deferrable. Re-cap `commands/sound.ex` (was FROZEN at 2,464 → ~300),
  `commands/catalog/sound.ex` (530 → ~90), `studio_panel.ex`,
  `studio/registry.ex`, `studio_live.ex` and — if IV.3 does not grow it back —
  `notifications/sound.ex`. The ratchet fails a file *far under* its cap too,
  which is the point: the number gets lowered in the commit that earns it.
- `scripts/check_docs_drift.sh`: the command-count check reads the compiled
  catalog and fails every `"N commands"` in `README.md`, `docs/*.md` and
  `user-guide/*.md`. **It does not scan `introduction/` or `skill-seeds/`** — see
  **VII.2**.
- `check_cycles.sh` names accepted cycles; confirm none of them was a Studio edge.
- Dialyzer: the baseline is a *rule*, not a file list (`1d52cff`), so deleting
  files cannot rot it. Confirm exit 0 rather than assuming.

### I.9 — Prose

- `components/explained/studio.ex` (431 lines) — rewritten in **Part VI**, not
  deleted, or the Explained rail gains a built tab pointing at a dead route.
- The five comment-only references from *"The four couplings"* above.
- `introduction/09-sound-pockets-and-chrome.md` — says **"29 `sound_*`
  commands"**, describes the cut-up engine and the `voice_bank_*` verbs. Outside
  every gate.
- `user-guide/introduction.md:39` — "**Studio** (sound editing)".
- `skill-seeds/sound-cutup.md` (183 lines) — see **VII.2**, which is the sharp
  part.
- `README.md` — "215 commands", twice.
- `SUPERMAP.md` Part II-b, and the stale Music row in Part III.
- `STUDIO_ROADMAP.md` → `daily-growth/archive/`, with a header saying what
  replaced it and why, so a reader who lands on it from a commit message is not
  misled.
- `LEFTOVERS_AGENT_CORE.md` — the `commands/sound.ex` split item, closed by
  deletion; `LEFTOVERS_SURFACES.md` §362–411 — five Studio items, all void.

### I.10 — What is deliberately NOT deleted

| Kept | Why |
|---|---|
| `Notifications.Sound` (578) | the chime library and the 18-key routing map — the thing spoken notifications extend |
| `Notifications.SoundGen` (184) | the 16 synthesized chimes; writes its own WAV header, depends on nothing |
| `Notifications.SoundBoard` (124) | event → key → chime, app-wide |
| `Notifications.{Schedule,Scheduler,Notification}` | timers, alarms, reminders |
| `NotifySoundController` + `/notify/sound/:name` | the media route pattern Part II copies |
| `assets/js/hooks/notify_sound.js` | the playback-unlock dance a webview requires — **Part III and IV both need this exact trick** |
| `AudioName` | shared filename sanitation |
| `Music` + the dock player | independent, sticky in `Layouts.app` |
| Sketch Pad, all of it | a different feature that shares a route |
| `voice_recorder.js`, `lib/meter.js`, `Capture.{Devices,Level}` | D9 |
| `desktop/tauri/src/voice.rs` | D2 rung 1 — the floor |
| `sounds/studio/*.wav` | D8 — the operator's audio |

---

## Part II — The engine

**~600 lines. The substrate for everything after it.**

### II.1 — `BusterClaw.Voice.Engine` — probe and spawn

Discovery, per call, never cached at build time (D1):

```
@candidates [
  Path.expand("~/.buster-claw/voxcpm/bin/voxcpm"),
  "/opt/homebrew/bin/voxcpm",
  "/usr/local/bin/voxcpm"
]
resolve: Enum.find(@candidates, &File.regular?/1) || System.find_executable("voxcpm")
```

`probe/0` returns a struct the whole app renders from: `available?`, `path`,
`version`, `device` (`mps`/`cpu`), `model_id`, `weights_present?`, and on absence
a `reason` plus the install line to show. **Cached in `:persistent_term` with a
short TTL and invalidated by an explicit "re-check" button** — an operator who
just finished `pip install` must not have to restart the app.

Invocation is `System.cmd/3`, `stderr_to_stdout: true`, an explicit `cd`, and a
timeout. Always `--local-files-only` once weights are cached and always an
explicit `--device`, because `auto` on a Mac under memory pressure is a decision
made silently.

**The three shapes we call:**

```
voxcpm design --text "<line>" --output <tmp>.wav
              [--control "<style>"] [--cfg-value 2.0]
              [--inference-timesteps 10] [--seed N] [--normalize]

voxcpm clone  --text "<line>" --reference-audio <ref>.wav --output <tmp>.wav

voxcpm clone  --text "<line>" --prompt-audio <ref>.wav
              --prompt-text "<transcript>" --output <tmp>.wav

voxcpm batch  --input <lines>.txt --output-dir <dir>
```

`batch` is the one that makes **IV.1** cheap: 18 lines, one model load.

Output lands in `System.tmp_dir!` and is **atomically renamed** into the cache
only after `Audio.Wav.probe/1` says it is a real WAV of non-zero duration. A
truncated render from a killed process must never become a cached line.

### II.2 — `BusterClaw.Voice.Renderer` — the queue

A `GenServer`, one render at a time (D5), with:

- a bounded queue and a documented policy for what happens when it is full
- per-job `{:ok, path} | {:error, reason}` broadcast on a PubSub topic, so a
  LiveView can show progress without polling
- a hard timeout per job, generous — a cold 2B load plus a long line is minutes
- **cancellation**, because a queued chime that is no longer wanted must not hold
  the queue behind it
- the work in a `Task.Supervisor` child, so a wedged `voxcpm` cannot take the
  GenServer down with it

### II.3 — `BusterClaw.Voice` — the context

- `render(text, opts)` → `{:ok, path}` from cache, or `{:queued, ref}`
- `cache_path(text, opts)` — `sha256(text <> voice <> params)` (D4)
- `profiles/0`, `put_profile/2`, `active/0`, `set_active/1` — reading
  `sounds/voice/refs/*.{wav,json}` (D6)
- `sweep/1` — cache eviction by age and total bytes

Workspace layout, declared in `Workspace.entries/0` as `:on_demand` with a seeded
README, the same shape as `shaders/`:

```
sounds/voice/
├── README.md
├── refs/    <name>.wav + <name>.json   (label, transcript, sample rate, captured)
└── lines/   <sha256>.wav               (the render cache)
```

### II.4 — The media route

`GET /voice/line/:hash` under `pipe_through :media`, resolved by
`Voice.cache_path/1` against the real listing — **never joined from raw input**,
the same posture `NotifySoundController` and `MusicController` already take.
Through `RangeResponse` so it gets `nosniff`, which the pipeline-less media routes
otherwise never get (`LEFTOVERS_SURFACES` §210, HIGH — **do not add a sixth route
without it**).

### II.5 — The verbs

| Verb | Type | Tier | Gated | What |
|---|---|---|---|---|
| `voice_engine` | `:read` | `:safe` | — | the probe: installed, where, which model, which device, and on absence the reason and the fix |
| `voice_list` | `:read` | `:safe` | — | profiles, which is active, and how many lines are cached |
| `voice_render` | `:mutate` | `:restricted` | — | text → a cached WAV. Reports cache hit vs render, and the wall-clock |
| `voice_profile_set` | `:mutate` | `:restricted` | — | point a profile at a reference clip already in `refs/` |

Plus **`voice_greeting_set`** in **Part V**, `gated` (D15).

`voice_render`'s description must carry a **measurement, not a default** — the
Part 0 wall-clock — for the same reason `sound_find` carries its 6.0 threshold and
its 109-second cold cost: a model choosing this verb has to know it will block for
a minute before it runs.

### II.6 — Tests

- Engine absent → every surface renders the honest sentence, no crash, no empty
  list pretending to be an answer.
- Engine present but weights missing → a *different* reason, not the same one.
- A render that produces a zero-length or non-WAV file is refused, not cached.
- Cache hit does not spawn a process. (Assert on a call counter, not a stopwatch.)
- Two concurrent `render/2` calls produce one spawn.
- A timed-out job leaves no partial file in `lines/`.
- The queue drains after a job crashes.
- **Break each guard before trusting it** — a test written in the same sitting as
  its code inherits its blind spot, and this repo has shipped three vacuous ones.

---

## Part III — Chat

### III.1 — Per-message render, on demand (rung 2)

**The design, and why it is not the obvious one.** Today
`status/chat.ex:333` pushes `bc:speak` with the message text for every
`:assistant` block, and `voice.js` hands it to Tauri's `speak` → `say(1)`. That
path stays exactly as it is.

Alongside it: **a speak-in-my-voice control on the message bubble.** Click →
`Voice.render/2` → queued → the bubble shows a spinner → on completion an
`<audio>` plays `/voice/line/<hash>`. Second click on the same message is
instant, because the cache is content-addressed.

**Why this and not streaming.** RTF 1.76 means a streaming reader falls further
behind with every sentence; there is no buffer size that fixes a producer slower
than the consumer. An explicit, per-message, cached render is the only shape that
is honest at RTF > 1 — and it turns the weakness into a feature, because the
operator chooses which replies are worth hearing.

**The playback-unlock trick is not optional.** `notify_sound.js` does a muted
play/pause inside the first pointer or key event to earn programmatic playback
permission, then reuses the same element by swapping `src`. A new `<audio>` per
message will be blocked by the webview. **Reuse `notify_sound.js`'s mechanism —
do not reinvent it.**

Barge-in: `bc:stop_speak` already exists and clears the `say` queue. The new
player needs the same treatment on the same event, or "stop talking" will stop one
of two voices.

### III.2 — Automatic readback (rung 3)

Gated on **the daemon** below. A third setting beside the existing Voice toggle —
`off` / `system voice` / `my voice (delayed)` — with the third option labelled
with its real latency, measured, not adjectival.

**The honest behaviour when the daemon is absent:** the option is visible,
disabled, and says why. Not hidden — a capability the app has and the machine
cannot currently do is exactly what `voice_engine` exists to explain.

### III.3 — The daemon, and the case against it

VoxCPM ships no server. Rung 3 needs one, because a CLI invocation per message
reloads a 2B model per message. That means **we write ~100 lines of Python** —
`VoxCPM.from_pretrained` held resident, `generate_streaming`, a loopback HTTP
endpoint — and ship it as a file the operator runs in their own venv.

**This is the Browserbase shape and it must be built as if it will be deleted.**
That deletion cost −2,158 lines because a local sidecar powered a feature with no
fallback and prod never bundled it. The defences here:

1. Rungs 1 and 2 are complete products. Deleting the daemon costs one setting
   option and nothing else.
2. The daemon is **discovered, never supervised.** The BEAM does not start it,
   restart it, or own its lifetime. It is a URL that answers or does not.
3. `voice_engine` reports daemon presence separately from CLI presence, so
   "installed" and "resident" are never one flag.
4. **A smoke test that runs against the real daemon**, or it does not ship.
   `chat_steering_roadmap` found four defects that only real-CLI smokes caught;
   the same will be true here.

**Recommendation: build III.1 and stop.** Reassess III.2 after living with III.1
for a week. If the operator finds himself clicking speak on most replies, the
daemon has earned itself. If he clicks it on one reply in twenty, it has not, and
that is a better answer than a working daemon nobody wanted.

---

## Part IV — Notifications

**The easy half, and the reason it is easy: notifications have lead time.** A
timer set for ten minutes gives ten minutes to render. Chat gives none. Every
design decision below falls out of that one asymmetry.

### IV.1 — The fixed spoken chime set

**Twelve to fifteen short lines, rendered once, cached forever.** One `voxcpm
batch` invocation, one model load. The set, one per *live* route key (D12 removes
`order`):

| Key | Fired by | A line like |
|---|---|---|
| `default` | the floor | "Something needs you." |
| `timer` | a fired timer | "Your timer is up." |
| `alarm` | a fired alarm | "Alarm." |
| `reminder` | a fired reminder | "Reminder." |
| `chat` | `Agent.Chat` (`chat.ex:1029`) | "New message." |
| `terminal` | notification source | "The terminal wants you." |
| `email` | a queued gmail dispatch item | "Mail arrived." |
| `voicemail` | Telephony inbound | "You have a voicemail." |
| `sms` | Telephony inbound | "A text arrived." |
| `manual` | notification source | — |
| `confirm` | Sentinel | "I need a confirmation." |
| `shift` | shift end | "The shift is over." |
| `blocked` | a blocked dispatch item | "I'm blocked." |
| `web` | browser events | "The browser needs you." |
| `security` | `:critical` only | "Security event." |
| `boot` | `SoundBoardLive` mount | "Buster Claw is up." |

**The lines are seeded and editable.** They are the operator's machine talking to
him; a line he cannot change is a line he will stop hearing. Store them as a
Settings map beside `notify_sound_map`, seeded with the defaults above.

**No bundled spoken set.** Rendering at build time would ship *somebody's* voice
in the DMG — which is the opposite of the point, and 1.6 MB of it. The spoken set
is rendered on the operator's machine into his workspace.

**The install path is `sound_apply`, unchanged.** Render 16 lines → for each,
`sound_apply(source: <rendered>, route: <key>)`. The existing gated verb does the
install and the routing. **The notification integration needs no new publish
path** — this is finding #2 from the top of the document, cashed.

### IV.2 — Spoken notification labels

A `Notification` carries a `label` of 1–500 characters. Render it **at schedule
time**, not at fire time:

- `Notifications.create/1` enqueues a render of the label when spoken
  notifications are on for that route key.
- The rendered hash is stored on the notification's `metadata` map — which already
  exists and needs no migration.
- At fire time, `NotifyLive` pushes `notify:play-sound` as it does now, and
  additionally `notify:speak` with the hash **only if the render finished**.
  If it did not, the chime fires alone. **A late voice is silence, never a delay.**

**The reminder case is the one that breaks this.** A `reminder` "fires
immediately (a message with no countdown)" — zero lead time, exactly like chat.
Reminders get the chime and no spoken label, or they get a spoken label that
arrives seconds late. **Recommendation: chime only, and say so in the setting.**

### IV.3 — The setting

Settings → Notify already renders the 18-key routing table with per-key audition.
Spoken notifications add **one column**: a per-key `chime · chime + speech ·
speech only` selector, defaulting to `chime` everywhere (D11). Stored as a second
Settings map; the existing `notify_sound_map` is not touched, because a routing
map that grew a second meaning is a map two features fight over.

**With the engine absent the column renders disabled with the probe's reason.**
Not hidden.

---

## Part V — The phone greeting

**The single highest-value output of this engine, and the smallest phase.**

Today `supabase/functions/voice/index.ts:99` emits `<Say
voice="Polly.Matthew">${greeting} If you have an access code…</Say>`, with
`greeting` from a `GREETING_TEXT` env var. Every caller hears Amazon.

**The change:**

1. `voice_greeting_set` (gated, D15) renders the greeting line locally and uploads
   the WAV to the Supabase `recordings` bucket — the same bucket `Relay` already
   uploads to and deletes from, with the same service-role key.
2. The Edge Function emits `<Play>${url}</Play>` when a greeting object exists,
   and falls back to the existing `<Say>` when it does not.
3. The PIN prompt and the "leave a message after the beep" line are **the same
   change** and should land together — a greeting in the operator's voice followed
   by Polly saying "leave a message after the beep" is worse than all-Polly.

**Constraints:**

- **Twilio `<Play>` wants a public URL.** The `recordings` bucket is private and
  the Mac reaches it with a service-role key. Either a signed URL with a long
  expiry regenerated on set, or a separate public object. **Decide this
  explicitly; do not make the recordings bucket public.**
- **8 kHz μ-law is what the caller hears** regardless of what we upload. Render at
  whatever the model gives and let Twilio downsample — but *listen to the result
  over an actual phone call* before believing it. Voice quality claims made from a
  laptop speaker are not claims about a phone.
- **The greeting is public speech in the operator's voice.** That is the whole
  point and also the reason for the gate. It is also the one place in this app
  where the right-of-publicity reasoning `STUDIO_ROADMAP` V.1 settled still
  applies at full force — **it is fine because it is his own voice, and for no
  other reason.** A profile cloned from anyone else must never reach this verb.
  Consider refusing `voice_greeting_set` for any profile not marked as the
  operator's own.
- **Supabase Edge Function tests** are already an open item
  (`LEFTOVERS_PLATFORM:76` — the voice function has none). This change is the
  reason to fix that, not another reason to skip it.

---

## Part VI — The Voice tab

**Where a person makes a voice and hears it.** Everything above is unusable
without this; an agent verb that needs a reference clip nobody can create is not
a feature.

### VI.1 — What happens to `/studio`

After I.1 and I.2 the Studio has one tab: Sketch Pad. Three options:

| | Shape | Cost | Verdict |
|---|---|---|---|
| A | Studio keeps `mix`-less, `voice`-less registry; Sketch alone under a "Studio" rail | ~0 | A rail with one button is a rail in the way |
| B | Delete `/studio`; promote Sketch to `/sketch` with its own dock tab | route, dock entry, tab labels, deep links, `SUPERMAP` | Clean, but it touches a shipped surface for cosmetic reasons |
| C | **Studio becomes two tabs: Voice (VoxCPM) and Sketch Pad** | one registry entry, one dispatch line | **Recommended** |

**C, and the registry is why it is cheap.** `Studio.Registry` is data-only and
depends on nothing; adding or removing a sub-tab is one `@tabs` entry and one
word in `@built`. Its own moduledoc records that a split and its reversal each
cost exactly that. The name still fits: a room where you make a voice and a
drawing.

**This is an operator decision, not mine.** It is listed under Open Questions.

### VI.2 — The Voice tab, three panes

**Pane 1 — Engine.** The probe, rendered as prose. Installed or not, where, which
model, which device, the measured cold and warm render time from the last job, and
when absent, the exact install command with a copy button. **A re-check button.**

**Pane 2 — Voices.** The profiles list. Per profile: a label, the reference clip
with a waveform and a play button, its transcript, its sample rate, and a
**"hear this voice say…"** field that renders an arbitrary line through it. Add a
voice two ways:

- **Drop a file** — the day-one path (D10), works with no microphone, no
  entitlement and no spike.
- **Record one** — `voice_recorder.js`, kept from D9, stripped of the word-index
  machinery. **Capture rules inherited wholesale from `STUDIO_ROADMAP` V.7 and
  they are not negotiable:** `autoGainControl` **off** and `noiseSuppression`
  **off** (both reshape exactly what a cloner listens to); AudioWorklet rather
  than `MediaRecorder` (blob URLs are refused under this CSP and the two hosts
  disagree on codec); display the **live stream's true sample rate**, never the
  device's advertised one; **warn hard on Bluetooth input**, which drops to
  8 kHz HFP and produces a clone of a bad phone line.

**Pane 3 — Lines.** The render cache: what has been spoken, how big it is, a play
button each, and a sweep. Unglamorous and the first thing anyone will want when a
line sounds wrong.

### VI.3 — The Explained tutorial

`components/explained/studio.ex` is rewritten rather than deleted (I.9). Its
subject changes completely — from "the experimental corner where you cut audio"
to "the app can speak in your voice; here is what that costs and what it will not
do." It must carry the demo contract every tutorial carries: **prerequisites,
side effects, where the stop is, expected result and failure state.** The
prerequisite here is a multi-gigabyte install, which is the largest prerequisite
any tutorial in this app has ever had — say so.

---

## Part VII — The things no gate covers

### VII.1 — `NSMicrophoneUsageDescription` is missing, and the comment saying it is unnecessary is false

`desktop/tauri/Info.plist:19` reads: *"there is no getUserMedia anywhere in
assets/js."* There is — `assets/js/hooks/voice_recorder.js:117`, mounted by
`components/studio/recorder.ex:158`, registered at `hooks/index.js:43`, shipped
08-16. The plist comment predates the recorder and `NSMicrophoneUsageDescription`
is still in its "deliberately absent" list.

**Why this is not a stale comment.** A hardened-runtime app that requests the
microphone with no usage string is **terminated by TCC**, not merely given a
generic prompt. So `STUDIO_ROADMAP` V.4a — *"does `getUserMedia` work in a
packaged build?"* — will fail, and it will look like a WKWebView ceiling when it
is a one-line plist omission. The `browser-roadmap-status` finding says wry owns
the single `uiDelegate` slot and **auto-grants camera and mic**, which means the
delegate is probably not the blocker at all.

**Add the key before anyone clicks that dialog**, or the wrong conclusion gets
banked and the recorder gets written off. It is notarization-affecting (a
re-sign), it is one line, and it is item 2 in the build order.

`scripts/check_docs_drift.sh` does not scan `Info.plist`. That is why this
survived — and it will survive the next time too unless the drift script grows a
`getUserMedia`-versus-plist assertion, which is the fix worth making while the
finding is fresh.

### VII.2 — `skill-seeds/sound-cutup.md` will outlive the feature in every existing workspace

183 lines teaching an agent 24 verbs that will not exist. It is embedded at
compile time (`skills.ex:346`) and written by `Skills.ensure/0` via
**`maybe_write`, which never overwrites**. `BusterClaw.Seed` — the upgrade path
that replaces a seed whose bytes still match a version we shipped — **covers Jobs
and not Skills** (`skills_upgrade_path` memory, `af27853`).

So deleting the seed file removes it from *new* workspaces and leaves it in
*every existing one*, where the agent will read it and try to call
`sound_index_search`.

**This is the same failure BusterPhone's deletion caused on 08-18** — every
existing workspace holding a job brief that named a deleted command — and it is
the reason `Seed` was built. **Converting `Skills` to `Seed.write/3` is the fix,
and it is the second half of `G-44`'s open work.** It is listed here rather than
waved at because a two-line deletion that leaves a landmine in every install is
not a two-line deletion.

Same class, lower stakes: `introduction/09-sound-pockets-and-chrome.md` is
seeded prose stating **"29 `sound_*` commands"** and outside `check_docs_drift`'s
`DOCS=(README.md docs/*.md user-guide/*.md)`.

### VII.3 — The `order` route key

D12. Nothing rings it; it has a label, a chime and a routing slot. Fix or remove
it as its own change, so the reasoning is legible.

### VII.4 — *"There is no LLM inside Buster Claw"*

The README's second paragraph, and the front-door claim on busterclaw.lol. A 2B
TTS model is not an LLM in the sense that sentence means — it does no reasoning,
it holds no conversation, it replaces no agent backend, and it costs no API key.
But it is a neural model with a MiniCPM-4 backbone, it is 2B parameters, and a
reader who installs multiple gigabytes of weights and then reads that sentence
will feel misled.

**Rewrite the sentence; do not quietly redefine it.** Something that keeps the
promise it was making — *there is no LLM inside: you bring the intelligence* —
and adds the true new fact: *speech is synthesized locally by a model you install
yourself, and the app works without it.* The claim that matters (no API keys, no
inference we bill for, your subscription) survives intact.

**`busterclaw.lol` is a separate repository and is covered by no gate here** —
`check_docs_drift.sh` says so in its own failure message. Update it by hand.

### VII.5 — Command count

`README.md` says **215 commands**, twice. The catalog loses 30 and gains 5. The
drift gate computes the real number from the compiled catalog and will fail CI
until the prose matches — which is the gate working. **Do not write a test
asserting the new count**; a universal over the catalog passed against `HEAD` and
failed against the merged tree once already, because three sessions write into it
at the same time.

---

## Risks, ranked

**R1 — Quality. VoxCPM's clone does not sound like the operator.** Everything
rests on this and it is unmeasured. Mitigation: **Part 0.1's last two rows, before
anything else.** If it fails, the deletion is probably still right and the build
is not.

**R2 — Speed. RTF on this Mac is much worse than 1.76.** That figure is Q8_0
GGUF on an M4 Pro; PyTorch/MPS on a 2B model may be several times slower.
Mitigation: the whole design pre-renders. The phase that dies is **III.2** and it
is already last and already optional. **IV.1's 16 lines are rendered once, ever.**

**R3 — The install is too big to ask of anyone but the operator.** Multiple
gigabytes, a Python venv, a `pip install` that pulls torch. For a
security-positioned product distributed as a 27 MB DMG this is a real
imposition. Mitigation: it is **entirely optional and the app is complete without
it** (D2 rung 1). But it means **this feature does not ship to R1 users as a
default** — it is an operator feature first, and calling it anything else would be
dishonest.

**R4 — The deletion is 19% of the codebase and touches five gates.** Mitigation:
nine ordered commits, each compiling; the size gate edited in the same commit that
deletes; explicit-path staging with other sessions live.

**R5 — The daemon becomes Browserbase.** Mitigation: D2's rungs, III.3's four
defences, and a standing willingness to delete it.

**R6 — Deleting the corpus tooling deletes the ability to evaluate the
replacement.** After I.5 there is no `sound_transcript_search`, no
`sound_index_words`, nothing that can compare a VoxCPM line to a real recording.
Mitigation: **do Part 0's quality judgement while the old system is still
standing**, so the comparison is A/B rather than remembered.

**R7 — Silent capability drift.** Nothing asserts that the notification layer
stays free of the voice engine, the way nothing asserted it stayed free of the
Studio. Mitigation: a lockstep-style test — the surviving chime path must not
reference `BusterClaw.Voice.*` except through the one seam Part IV defines.

---

## Open questions for the operator

1. **Which variant?** 2B at 48 kHz, or 0.5B at 16 kHz if it sounds good enough
   through a phone and a chime. Part 0 answers the second half; the first half is
   taste.
2. **`/studio` after the cut** — VI.1 options A, B or C. Recommended **C**: two
   tabs, Voice and Sketch Pad.
3. **Does automatic chat readback matter enough to justify the daemon?**
   III.3 recommends building III.1 and living with it for a week first.
4. **`sound_input_level` / `sound_input_level_set`** — delete with the rest, or
   keep two verbs that set the OS input volume?
5. **The greeting's public URL** — a long-lived signed URL, or a separate public
   object? Do not make the recordings bucket public.
6. **The spoken chime lines** — accept IV.1's defaults, or write them? They are
   the machine's voice talking to him and he is the only person who can pick them.
7. **`sounds/studio/`'s ten voicemails** — leave them (D8), or archive them out of
   the workspace now that nothing reads them? They are other people's voices,
   which is a reason not to use them as reference clips and possibly a reason not
   to keep them.

---

## Explicitly out of scope — and do not re-propose

- **Bundling the model, the weights, or a Python runtime in the DMG.** D1, and
  the size numbers are in the table.
- **Fine-tuning or LoRA.** VoxCPM supports both with 5–10 minutes of audio. It is
  a real option and it is a *later* one — zero-shot cloning must be measured
  first, or we will be tuning something we never established was insufficient.
- **Rebuilding concatenative synthesis "just for the collage effect."** If the
  cut-up instrument is wanted back as an *artistic* tool rather than a TTS engine,
  that is a new roadmap with a new argument, starting from git history. It is not
  a phase of this one.
- **STT / dictation.** Demolished 06-28 and re-settled 08-08. If dictation ever
  returns it is `SFSpeechRecognizer`, not Whisper, and not VoxCPM.
- **A Tauri command for audio playback.** D14.
- **Making the app a general TTS service** — an HTTP endpoint other programs
  call. The engine is for this app's own speech.
- **Voice cloning of anyone but the operator reaching the phone greeting.**
  Part V. The right-of-publicity reasoning from `STUDIO_ROADMAP` V.1 is closed
  research and it survives the engine change intact — recording yourself removes
  the layer; cloning someone else restores it.

---

## Appendix A — Deletion manifest

**Elixir, `lib/` — 19,498 lines**

```
lib/buster_claw/notifications/cutup/                    16 files   7,947
lib/buster_claw/notifications/sound_studio.ex                        745   (codec extracted first — I.4)
lib/buster_claw/notifications/studio_mix.ex                          836
lib/buster_claw/notifications/studio_catalog.ex                      222
lib/buster_claw/notifications/studio/effects.ex                      357
lib/buster_claw/notifications/studio/render.ex                       161
lib/buster_claw/notifications/capture.ex                             381
lib/buster_claw/notifications/capture/take.ex                        379   (rewritten, not deleted — I.6)
lib/buster_claw/commands/sound.ex                                  2,464   (→ ~300)
lib/buster_claw/commands/sound_capture.ex                            244
lib/buster_claw/commands/catalog/sound.ex                            487   (→ ~90)
lib/buster_claw_web/components/sound_studio/            7 files   1,668
lib/buster_claw_web/components/studio/recorder.ex                    270
lib/buster_claw_web/components/studio/voice_library.ex               185
lib/buster_claw_web/components/studio/words.ex                       214
lib/buster_claw_web/components/studio/sentence.ex                    173
lib/buster_claw_web/live/sound_studio_component.ex                   973
lib/buster_claw_web/live/studio/mix_state.ex                         232
lib/buster_claw_web/live/studio/recorder_state.ex                    261
lib/buster_claw_web/live/studio/voice_state.ex                       365
lib/buster_claw_web/studio/preview.ex                                 58
lib/buster_claw_web/controllers/studio_file_controller.ex             38
lib/buster_claw_web/components/explained/studio.ex                   431   (rewritten — VI.3)
```

**Tests — 14,167 lines**

```
test/buster_claw/notifications/cutup/                             6,101
test/buster_claw/notifications/studio/  + capture/                1,170
test/buster_claw/notifications/{capture,sound_studio,studio_mix}_test.exs  1,209
test/buster_claw/commands/{sound,sound_capture}_test.exs          2,716
test/buster_claw_web/components/studio_panel_test.exs               partial
test/buster_claw_web/live/{clip_actions,sound_studio_component,
                           voice_library}_test.exs + studio/voice_state_test.exs  2,971
```

**JavaScript — 1,734 lines**

```
assets/js/hooks/{studio_audition,studio_keys,studio_menu_bar,
                 studio_context_menu,wave_trim,track_arrange,
                 audio_clip,voice_audition}.js
assets/js/audio/clipwave.js
assets/js/lib/{arrange,audition,trim}.js  + their three .test.js
assets/js/hooks/index.js — 9 imports, 9 registrations
```

**Prose, config and gates**

```
skill-seeds/sound-cutup.md                                           183   (+ VII.2)
scripts/check_file_sizes.sh                          32 removed, 6 re-capped
daily-growth/roadmaps/surfaces/STUDIO_ROADMAP.md                   1,682   → archive/
introduction/09-sound-pockets-and-chrome.md                       partial
user-guide/introduction.md:39 · README.md ×2 · SUPERMAP II-b, III
lib/buster_claw_web/router.ex — the /studio/file/:name scope
Settings rows: studio.voice.banks · studio.voice.active_bank
Workspace: sounds/studio/index/ · sounds/studio/features/
```

**≈ 35,400 lines. ~19% of the codebase.**

## Appendix B — Survivor manifest

`Notifications.Sound` (578) · `SoundGen` (184) · `SoundBoard` (124) ·
`Schedule` (109) · `Scheduler` (83) · `Notification` (41) · `AudioName` ·
`NotifySoundController` + both `/notify/sound` routes ·
`assets/js/hooks/notify_sound.js` · `Music` + `MusicPlayerLive` +
`MusicController` + `/music/track/:name` · `Sketch.*` and everything under it ·
`Capture.Devices` (254) · `Capture.Level` (153) ·
`assets/js/hooks/voice_recorder.js` (284) · `assets/js/lib/meter.js` (91) ·
`desktop/tauri/src/voice.rs` (111) · **new** `BusterClaw.Audio.Wav` (~250,
extracted) · `sounds/studio/*.wav` on disk.

## Appendix C — The verb map

**Deleted (30):** `sound_align` `sound_assemble` `sound_concat` `sound_corpus`
`sound_delete` `sound_devices` `sound_fade` `sound_find` `sound_gaps`
`sound_import` `sound_index_delete` `sound_index_import` `sound_index_list`
`sound_index_search` `sound_index_words` `sound_input_level`
`sound_input_level_set` `sound_normalize` `sound_probe` `sound_record`
`sound_record_save` `sound_sentence` `sound_sources` `sound_transcript_search`
`sound_transcript_words` `sound_trim` `voice_bank_create` `voice_bank_delete`
`voice_bank_list` `voice_bank_select`

**Kept (4):** `sound_list` `sound_routes` `sound_apply` (gated)
`sound_restore_defaults`

**New (5):** `voice_engine` (safe) · `voice_list` (safe) · `voice_render`
(restricted) · `voice_profile_set` (restricted) · `voice_greeting_set`
(restricted, **gated**)

**Net: −25.** The catalog's `Sound` module goes from 34 entries to 9.
