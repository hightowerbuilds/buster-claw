# The Voice — what Buster Claw sounds like

**Scoped 09-02-26 · Status: READBACK SHIPPED. The rest is unstarted and gated on
one listen.**

> **What this map is now.** It was written this morning as a plan to delete the
> Studio's cut-up engine and put VoxCPM in its place. **That framing is gone.**
> The cut-up engine is being spun out into its own project, so its removal from
> this repo is a *migration* with its own timing and its own reasons, not
> something this map argues for or waits on. Nothing here deletes anything.
>
> This map is about one thing: **what the app sounds like when it talks to you.**

---

## What shipped, 09-02-26

**Buster Claw reads its replies aloud, in a voice you chose.** The mechanism was
already there and had been since 07-21 — `chat.ex` pushes `bc:speak` per
assistant message, the `VoiceBridge` hook invokes the Tauri `speak` command, a
worker thread runs `say(1)` and a barge-in cuts it off. What was missing was a
voice: `spawn_say` ran `say -- <text>` with no `-v`, so the app spoke in whatever
System Settings happened to be set to. It had no voice of its own; it borrowed
the machine's.

Now the voice and rate ride on each queued utterance, `list_voices` reports what
that Mac actually has installed, and **Settings → Voice** is a picker with a
speed slider and an audition instead of a page of prose.

**And it speaks prose, not markdown.** Until now the reply went to the
synthesizer verbatim, so `say` read every brace of a fenced block and every path
segment of a URL. Measured on one ordinary reply — a sentence, a seven-line
Elixir block, a link:

| Spoken | Audio |
|---|---|
| The reply verbatim | **23.6 s** |
| Through `Voice.Speech.to_spoken/1` | **5.6 s** |
| Its bare prose, for reference | 3.3 s |

`BusterClaw.Voice.Speech` drops structure that carries no sound (emphasis, heading
hashes, bullets, rules) and *announces* structure a listener needs to know about
but not hear: a fenced block becomes "elixir code block", a table becomes "a
table", a URL becomes "a link to example.com". **Announcing beats silence** — a
listener told there was code can go and look; one who hears a sentence quietly
missing its middle cannot. Nothing is truncated.

**What is spoken and what is displayed differ on purpose.** The bubble still
renders the real markdown. A change that made them equal again is the regression,
and `status_live_test.exs` asserts both halves.

**This is the pragmatic layer and it is done.** Everything below is about giving
the app a voice that is *its own* rather than one of Apple's — which is a
different, slower job, and one that does not block anything.

---

## The division of labour, and why it is not a preference

**`say(1)` does live speech. VoxCPM does not, and cannot.**

VoxCPM's best measured Apple Silicon figure is **RTF ≈ 1.76 on an M4 Pro** (Q8_0,
llama.cpp-omni). RTF > 1 means rendering is slower than speaking: a streaming
reader can never catch up, and the gap grows with every sentence. Add tens of
seconds of model load per cold invocation and live readback is not a tuning
problem, it is arithmetic.

So the split is fixed by the numbers, not by taste:

| Job | Engine | Why |
|---|---|---|
| Reading chat replies aloud | `say(1)` | Instant, offline, already shipped |
| Notification chimes | VoxCPM | Rendered once, cached forever — lead time is free |
| The phone greeting | VoxCPM | Rendered once when it changes |

**Notifications have lead time and chat does not.** That sentence is the whole
design.

---

## Part 0 — what the measurement actually found (09-02-26)

Part 0 ran and stopped at the first step, for a reason the original plan did not
anticipate: **this machine cannot run VoxCPM by any Python route**, and no amount
of RAM changes that. The plan assumed Apple Silicon throughout — `--device mps`,
"RTF 1.76 on an M4 Pro". The dev machine is not one.

**The machine.** `MacBookPro16,1` — 2019 16-inch, **Intel Core i9-9980HK,
x86_64**, 32 GB, macOS 26.6.2. Not Rosetta: `hw.optional.arm64` and
`sysctl.proc_translated` are both unknown OIDs, which they would not be under
translation.

**The wall, with receipts:**

| Measured | Result |
|---|---|
| `voxcpm` 2.0.3 declared requirement (wheel METADATA) | **`torch>=2.5.0`** |
| Last `torch` release with a macOS **x86_64** wheel | **2.2.2** |
| macOS x86_64 wheels in torch 2.3.0 → 2.14.0 | **zero**, every release; arm64 only |
| `pip index versions torch` here | `No matching distribution found` |
| `onnxruntime` 1.29.0 macOS wheels | 0 x86_64, 4 arm64 |
| `mlx` | arm64 only, by construction |
| Apple Neural Engine builds (`seba/VoxCPM-ANE`) | Intel Macs have no ANE |

The gap is **architectural and permanent**, not a pin to nudge. RAM was never the
constraint — fp16 weights for a 2B model are ~5 GB. **A 128 GB Intel Mac Pro
fails identically; a base 8 GB M1 Air would work.** That is the shape of any
hardware decision made for this feature.

**What survives on this hardware: llama.cpp-omni + GGUF, CPU-only, built from
source.** Weights are real — `VoxCPM2-BaseLM-Q8_0` 1.73 GB, `voxcpm2-q4_k`
1.69 GB, `voxcpm2-f16` 4.97 GB. **Two cautions before anyone spends a day on
it:** upstream `ggml-org/llama.cpp` shows almost no VoxCPM presence (two
Metal-kernel PRs, both Apple-GPU work), and two of the published GGUF repos are
named `VoxCPM2-gguf-notcpp` — "not cpp", i.e. those weights are for some other
runtime.

**What Part 0 did NOT measure, deliberately: the quality verdict.** It is
architecture-independent, so it does not need this machine —
`openbmb/VoxCPM-Demo` on HF Spaces answers it in ten minutes with no install.
**No RTF figure was invented for this CPU.** A speed number measured on a 2019
Intel laptop describes a machine no user runs.

> **The one gate left.** Does a clone of the operator's voice sound like him? It
> decides whether "buster-claw's own voice" means *his* voice or simply a better
> synthetic one. It does not block the chime set or the greeting, both of which
> are worth doing in any voice the model can produce.

---

## The audio door — and the one thing the spin-off must not take

`sound_import` takes any WAV on disk (`path`, relative to the Library root) and
normalizes it into `sounds/studio/`; `sound_apply` installs it into the chime
library and routes an event key at it. **Neither verb cares what produced the
audio** — a microphone, a rented GPU, a model on another machine.

That means a speech engine needs **no new publish path, no new gate, and no new
trust decision**. It needs a WAV to appear in a folder. Guarded 09-02-26 by
`describe "the external-render bridge"` in `test/buster_claw/commands/sound_test.exs`.

**The catch, and it matters for the spin-off.** Both verbs run through
`BusterClaw.Notifications.SoundStudio`, and the coupling is to its *data type*,
not just its functions:

```elixir
# commands/sound.ex — editable_clip/1
case SoundStudio.read(path) do
  {:ok, %SoundStudio{bits: 16} = clip} -> {:ok, clip}
```

That file is **two modules wearing one name**: a WAV codec (`parse`, `read`,
`render`, `write`, `peak`, `duration_ms`, `probe`) and a source-file store
(`dir`, `list`, `path_for`, `store`, `save`). **Neither is cut-up machinery.**
Only the editing operations layered on top are.

So when the cut-up engine leaves for its own project, **the codec and the store
must stay** — under a name that stops implying otherwise. Measured blast radius
if the struct moves: 63 `%SoundStudio{}` literals across 22 files, but only **6
in surviving lib code** (4 of them in `sound.ex`). The rename is compiler-enforced,
so it is mechanical rather than risky.

---

## The engine, when it is wanted

**`BusterClaw.Voice.Engine` — BUILT 09-02-26.** Resolution, availability and
command construction. It does not render; the queue below is still unbuilt.

**Three corrections to this section's original sketch, all found by reading
voxcpm 2.0.3's own `cli.py` out of the published wheel rather than its docs:**

1. **There is no `--version`.** The sketch had `probe/0` return one. Shelling
   `voxcpm --version` gets an argparse error and a non-zero exit, so a working
   install would have been reported broken. No version is exposed.
2. **There is no `--seed`**, which the sketch listed among the `design` flags.
3. **Resolution must not use `System.find_executable/1`**, which the sketch
   specified. A double-clicked `.app` inherits launchd's `PATH` — this is the
   exact bug the 08-15 signed build shipped, reporting `claude`, `codex` and
   `opencode` all missing on a machine carrying all three. `ShellPath` exists to
   close it, and a venv is a worse case than those three. The one hardcoded
   candidate is `~/.buster-claw/voxcpm/bin/voxcpm`, which is not a guess but the
   path the install line tells the operator to use.

Everything else in the sketch checked out: `design`, `clone`, `batch` (plus an
unmentioned `validate`), and every flag except those two. `--normalize`,
`--local-files-only` and `--no-denoiser` are `store_true`, so they appear alone
or not at all — `--flag false` would be read as a positional argument.

**Availability is split in two, because running the binary is expensive.**
`cli.py` imports only argparse, but the console script is `voxcpm.cli:main`, so
Python imports the package first: `__init__` → `core` → numpy, huggingface_hub
and the torch model modules. **Even `--help` pays a full torch import.** So
`probe/0` never spawns anything — it answers from the filesystem and is safe to
call while rendering — and `verify/0` actually runs the binary, is documented as
slow, and belongs behind an explicit re-check. The `:persistent_term` TTL is
long rather than short for the same reason plus a second one: persistent\_term
writes trigger a global scan and are documented not to be for frequently updated
values, so `refresh/0` is what makes a long TTL safe.

Every command names a `--device`, because `auto` is the default and decides
silently under memory pressure; `--local-files-only` defaults **on**, because a
render that quietly reaches for huggingface is a render that hangs on a plane.

On this machine the probe answers, correctly: `available? false`, `device cpu`,
`reason :not_installed`, with the install line to show.

`batch` is what makes the chime set cheap: one model load for the whole set.

Output lands in `System.tmp_dir!` and is **atomically renamed** into the cache
only after a probe says it is a real WAV of non-zero duration. A truncated render
from a killed process must never become a cached line.

**`BusterClaw.Voice.Renderer`** is a `GenServer` running one render at a time,
with a bounded queue, per-job `{:ok, path} | {:error, reason}` on a PubSub topic
so a LiveView can show progress without polling, and a generous hard timeout — a
cold 2B load plus a long line is minutes.

---

## The spoken chime set

**BUILT 09-02-26** — `BusterClaw.Voice.Chimes`, plus the panel in Settings →
Voice that edits the lines and installs them.

**Sixteen short lines, rendered once, cached forever.** One line per live route
key — and `order` deliberately has none: its routing slot survives but
`SoundBoard.event_key/1` can no longer emit it, so a line for it is a line nobody
will ever hear. A test asserts that absence rather than leaving it to be
rediscovered.

**Not built with `batch`, on purpose.** One model load for the whole set is the
right optimisation and is left undone: `batch` writes into a directory under
names this app does not choose, and guessing that mapping with no engine to check
against is how a chime ends up routed to the wrong sound. It is a measurement
away, not a design away.

Install overwrites in place rather than going through the library's
`install_file/2`, which picks a *free* name — that would have left
`voice-alarm-2.wav` on disk with the old chime still routed, so editing a line
and re-rendering would change nothing you could hear. There is a test named for
that too.

The seeded set:

| Key | Fired by | A line like |
|---|---|---|
| `default` | the floor | "Something needs you." |
| `timer` | a fired timer | "Your timer is up." |
| `alarm` | a fired alarm | "Alarm." |
| `reminder` | a fired reminder | "Reminder." |
| `chat` | `Agent.Chat` | "New message." |
| `terminal` | notification source | "The terminal wants you." |
| `email` | a queued gmail dispatch item | "Mail arrived." |
| `voicemail` | Telephony inbound | "You have a voicemail." |
| `sms` | Telephony inbound | "A text arrived." |
| `confirm` | Sentinel | "I need a confirmation." |
| `shift` | shift end | "The shift is over." |
| `blocked` | a blocked dispatch item | "I'm blocked." |
| `web` | browser events | "The browser needs you." |
| `security` | `:critical` only | "Security event." |
| `boot` | `SoundBoardLive` mount | "Buster Claw is up." |

**The lines are seeded and editable.** They are the operator's machine talking to
him; a line he cannot change is a line he will stop hearing. Store them as a
Settings map beside `notify_sound_map`.

**No bundled spoken set.** Rendering at build time would ship *somebody's* voice
in the DMG — the opposite of the point, and ~1.6 MB of it. The set is rendered on
the operator's machine into his workspace.

**The install path is `sound_apply`, unchanged.** Render the lines, then for each
`sound_apply(source: <rendered>, route: <key>)`.

---

## The phone greeting

**The highest-value single output of this engine, and the smallest piece of
work.** Today `supabase/functions/voice/index.ts:99` emits
`<Say voice="Polly.Matthew">${greeting} …</Say>`. Every caller hears Amazon.

1. `voice_greeting_set` (gated) renders the line locally and uploads the WAV to
   the Supabase `recordings` bucket — the bucket `Relay` already uses, same key.
2. The Edge Function emits `<Play>${url}</Play>` when a greeting object exists,
   falling back to the existing `<Say>` when it does not.
3. The PIN prompt and the "leave a message after the beep" line are **the same
   change** and land together — the operator's voice followed by Polly is worse
   than all-Polly.

**Constraints:**

- **Twilio `<Play>` wants a public URL.** The `recordings` bucket is private and
  the Mac reaches it with a service-role key. Either a long-expiry signed URL
  regenerated on set, or a separate public object. **Decide explicitly; do not
  make the recordings bucket public.**
- **8 kHz μ-law is what the caller hears** regardless of what we upload. Render
  at whatever the model gives and let Twilio downsample — but *listen over an
  actual phone call* before believing it. Quality claims made from a laptop
  speaker are not claims about a phone.
- **The greeting is public speech in a chosen voice.** That is the reason for the
  gate. Cloning the operator is fine because it is his own voice, and **for no
  other reason** — a profile cloned from anyone else must never reach this verb.
- **Supabase Edge Function tests** are an open item (`LEFTOVERS_PLATFORM:76`).
  This change is the reason to fix that, not another reason to skip it.

---

## Loose ends no gate covers

**`NSMicrophoneUsageDescription` — FIXED 09-02-26.** The plist listed the
microphone as "deliberately absent" on the grounds that *"there is no
getUserMedia anywhere in assets/js"*. There was:
`assets/js/hooks/voice_recorder.js` had been calling it twice since 08-16. A
hardened-runtime app that requests the microphone with no usage string is
**terminated by TCC**, not given a generic prompt — so the first person to press
record would have watched the app die and concluded the webview cannot capture,
which is the expensive half of the bug. The key is now declared and the false
comment is gone. **It is notarization-affecting (a re-sign).**

Guarded by `test/buster_claw/tcc_usage_lockstep_test.exs`, which fails in both
directions — capture with no string, and a string with no capture — and is the
first test in the repo to open `Info.plist` at all. It strips XML and JS comments
first, because both files discuss these keys by name.

> **Left open, and it is a security question rather than a plist one.** Whether an
> arbitrary page in the embedded browser can now reach the microphone. The comment
> that was removed asserted Tauri's `WKUIDelegate` denies capture before TCC is
> consulted; [[browser-roadmap-status]]'s finding asserts wry owns the single
> `uiDelegate` slot and **auto-grants** camera and mic. **Both cannot be true**,
> and neither has been exercised in a packaged build.

**`skill-seeds/sound-cutup.md` outliving the feature — FIXED 09-02-26.** 183
lines teaching an agent 24 cut-up verbs, written by `Skills.ensure/0` via
`maybe_write`, **which never overwrites**. Under that, removing the file would
have removed it from *new* workspaces and left it in *every existing one*, with
the agent still reaching for `sound_index_search` — **exactly the failure
BusterPhone's deletion caused on 08-18**, which is why `Seed` exists.

All six skill seeds now go through `Seed.write/3`, so a file the operator never
touched upgrades and one they edited is left alone. `SeedTest` grew a Skills
manifest block pinning each current digest, verified by editing a seed and
watching it fail with the digest to append.

> **A trap worth recording.** `Skills.ensure/0` looks uncalled — `grep` for
> `Skills.ensure` finds nothing in `lib/`. It is invoked as
> `seed: {BusterClaw.Skills, :ensure}` in `Workspace`'s registry, a `{module,
> fun}` tuple that is invisible to grep *and* to `--warnings-as-errors`. This is
> the same shape the 08-09 dead-code pass recorded, and it is still live. The
> return shape changed from `:ok` to `{:ok, outcomes}`; `run_seed/1` discards it,
> so boot is unaffected, but nothing would have told you that.

---

## Risks

**Quality.** A VoxCPM clone may not sound like the operator. Ten minutes on the
demo Space settles it, and it costs nothing to find out first.

**Speed.** RTF on any machine we control may be much worse than 1.76 — certainly
so on the Intel dev machine, where the only route is a CPU-only source build.
Mitigated by design: every VoxCPM job here is pre-rendered and cached.

**Install size.** Multiple GB of weights plus a Python or a built binary is a
large thing to ask of anyone but the operator. **This is an operator feature
first**, and calling it anything else would be dishonest. The shipped default
stays `say(1)`, which needs nothing.

---

## Open questions

1. **Which variant?** 2B at 48 kHz, or 0.5B at 16 kHz if it sounds good enough
   through a phone and a chime. 16 kHz is not a disqualifier — every chime we
   ship is 22.05 kHz mono and the phone path is 8 kHz by the time Twilio is done.
2. **The greeting's public URL** — long-lived signed URL, or a separate public
   object? Do not make the recordings bucket public.
3. **The spoken chime lines** — accept the defaults above, or write them? They
   are the machine's voice talking to him and he is the only one who can pick.

---

## Explicitly out of scope — and do not re-propose

- **Bundling the model, the weights, or a Python runtime in the DMG.** BYO, like
  ffmpeg.
- **Fine-tuning or LoRA.** A real option and a *later* one — zero-shot must be
  measured first, or we tune something we never established was insufficient.
- **Replacing `say(1)` for live chat readback.** The arithmetic is at the top of
  this file.
- **Making the app a general TTS service** — an HTTP endpoint other programs
  call. The engine is for this app's own speech.
- **Voice cloning of anyone but the operator reaching the phone greeting.**
  Recording yourself removes the right-of-publicity layer; cloning someone else
  restores it.
- **Voice input.** Handled outside the app by Wispr Flow today. If it ever comes
  in-house it is `SFSpeechRecognizer`, not Whisper, and not VoxCPM — and it needs
  the plist key above first.
