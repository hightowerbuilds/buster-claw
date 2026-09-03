# 09-02-26 — Twice I said it was impossible

The day began with a map written that morning: **The Voice**, scoped as "VoxCPM
replaces the Studio — delete 35,000 lines, build 3,000." It ended with the whole
map built, the Studio decoupled from it entirely, and a 2019 Intel MacBook Pro
saying *"Your timer is up."* in a voice it was not supposed to be able to
produce.

The useful part of the day is the two places I was confidently wrong.

---

## Part 0 stopped at the first step

The map's own rule is that nothing gets built until VoxCPM is measured on this
machine. It was never measured, because it would not install:

| Measured 09-02 | Result |
|---|---|
| `voxcpm` 2.0.3's declared requirement | **`torch>=2.5.0`** |
| Last `torch` with a macOS **x86_64** wheel | **2.2.2** |
| macOS x86_64 wheels in torch 2.3.0 → 2.14.0 | **zero**, every release |
| `onnxruntime` 1.29.0 macOS wheels | 0 x86_64, 4 arm64 |
| `mlx` | arm64 only, by construction |

The dev machine is a `MacBookPro16,1` — 2019 Intel i9, x86_64. **RAM was never
the constraint**: a 2B model is ~5 GB at fp16, so a 128 GB Intel Mac Pro fails
where a base 8 GB M1 Air succeeds. I wrote that up as an architectural wall and
moved on.

> **That was the first wrong call, and it took eleven hours to find out.** I
> checked that no wheel existed *past* 2.2.2 and stopped. I never asked whether
> **2.2.2 itself** would do, or which Python it needed.
> `torch-2.2.2-cp312-none-macosx_10_9_x86_64.whl` exists. `python@3.12` was
> already installed on this machine. See the last section.

---

## The map stopped being about the Studio

Mid-afternoon, an operator decision changed the shape of everything: **VoxCPM is
not a Studio replacement.** The cut-up engine is being spun out into its own
separate project, so its removal from this repo is a migration on its own
schedule — not something the Voice map argues for or waits on.

`STUDIO_ROADMAP.md` was deleted (1,682 lines, recoverable at `6f5e54f`), and
`VOICE_ROADMAP.md` went **1,278 lines → 322**, because most of it was demolition
planning for a decision that no longer existed. What survived was everything
about *voice* rather than about the Studio.

The division of labour that came out of it is arithmetic, not taste:

| Job | Engine | Why |
|---|---|---|
| Reading chat replies aloud | `say(1)` | Instant, offline |
| Notification chimes | VoxCPM | Rendered once, cached — lead time is free |
| The phone greeting | VoxCPM | Rendered once when it changes |

**RTF > 1 means VoxCPM can never read chat on any machine.** Notifications have
lead time and chat does not. That one sentence is the whole design, and it is
what made the rest of the day's architecture survive contact with a machine 55×
slower than the one the figure came from.

---

## What landed — twelve commits, `caa0ffe..4da0ddd`

| | |
|---|---|
| `42a88da` | A guard on the audio door, before the engine existed |
| `6f5e54f` | The app got **its own voice** — a `list_voices` command and a real picker |
| `9d94dc7` | Part 0's measured wall, written into the map |
| `5fab0df` | Studio map deleted; Voice map cut to 322 lines |
| `d2ce925` | **Speak the reply, not the markdown it arrived in** |
| `17ee35f` | `NSMicrophoneUsageDescription` — a TCC termination since 08-16 |
| `3f69ed8` | `Voice.Engine`, with flags read from voxcpm's own parser |
| `3185660` | `Voice.Renderer` — one render at a time, cached by content |
| `2adcc15` | The spoken chime set |
| `dbbc54d` | Skill seeds that can be corrected after they ship |
| `6c5d810` | The map at the end of the night |
| `4da0ddd` | **Callers hear the operator, not Amazon** |

### The app was already speaking; it just had no voice

Chat readback has worked since 07-21. What was missing was that `spawn_say` ran
`say -- <text>` with **no `-v`** — so the app spoke in whatever System Settings
happened to be set to. It had no voice of its own, it borrowed the machine's, and
Settings → Voice was a page of prose with zero controls.

### It was also reading the markdown out loud

One ordinary reply — a sentence, a seven-line Elixir block, a link:

| Spoken | Audio |
|---|---|
| Verbatim, as it did | **23.6 s** |
| Through `Voice.Speech.to_spoken/1` | **5.6 s** |
| Its bare prose, for reference | 3.3 s |

`say` was reading every brace of the code block and every path segment of the
URL. **Seven times the listening for the same meaning.**

---

## Five guards, all broken on purpose, three of which caught something real

Every guard written today was verified by reintroducing the defect it exists to
catch. Three of them found bugs that were already there or that I had just
written:

**The RIFF chunk walker had no hermetic coverage.** Of 106 tests in
`sound_test.exs`, only 4 fail when the walk is broken — and the 2 pre-existing
ones are both `afconvert`-gated. **On Linux CI, a fixed-offset WAV parser
passed.**

**`data-confirm` would have shipped a dead button.** `claw_confirm_test.exs`
refused the greeting's first draft: `window.confirm()` is a **no-op returning
`false`** in the Tauri WKWebView, so every confirm-gated action silently never
fires. Perfect in a dev browser, dead in the packaged app.

**The greeting path lockstep found a bug in its own feature.** The storage path
lives in Elixir *and* TypeScript, in processes that never talk. Breaking the pin
exposed that `greetingPublished()` had the path written out again instead of
derived from the constant — so changing it would have moved what the function
*streams* without moving what it *looks for*. The phone would have answered in
Polly while the object sat exactly where it was published.

---

## Three corrections to a map written the same morning

Reading voxcpm 2.0.3's actual `cli.py` out of the published wheel — rather than
its documentation — corrected the engine sketch three times:

1. **There is no `--version`.** The sketch had `probe/0` return one. Shelling
   `voxcpm --version` gets an argparse error and a non-zero exit, so **every
   working install would have been reported broken.**
2. **There is no `--seed`**, which the sketch listed among the design flags.
3. **Resolution must not use `System.find_executable/1`.** A double-clicked
   `.app` inherits launchd's PATH — this is the exact bug the 08-15 signed build
   shipped, reporting `claude`, `codex` and `opencode` all missing on a machine
   carrying all three.

Also found: `Skills.ensure/0` looks dead to grep. It is invoked as
`seed: {BusterClaw.Skills, :ensure}` in Workspace's registry — a `{module, fun}`
tuple invisible to grep **and** to `--warnings-as-errors`. Same shape as the
08-09 dead-code lesson, still live.

---

## The second wrong call, and the machine talking

Late on, the question was put plainly: *can we install Vox on this computer at
all?*

The honest answer required testing rather than repeating the morning's
conclusion. **It installs. It runs. It works.**

| Step | Detail |
|---|---|
| Python | **3.12** — not 3.13; torch 2.2.2 predates it |
| torch | `2.2.2` + `torchaudio 2.2.2`, real x86_64 macOS wheels |
| Pins | `numpy<2` (torch 2.2.2 was built against 1.x), `transformers==4.46.3` (4.5x **disables PyTorch entirely** below 2.5), `librosa==0.10.2`, `llvmlite==0.45.1` |
| The one real blocker | `scaled_dot_product_attention(..., enable_gqa=True)` — added in **torch 2.5**, called at exactly two sites |

So the `>=2.5.0` pin is **precise, not cautious**. But `enable_gqa` is not new
maths — grouped-query attention shares one key/value head across several query
heads, and the keyword only asks SDPA to broadcast them rather than making the
caller materialise the repeats. A `repeat_interleave` back-port in
`voxcpm/__init__.py` is *exact*, not an approximation, and self-disables on torch
≥ 2.5.

**Then it spoke.**

| Measured, first render | |
|---|---|
| Model load / warm-up | **2 min 29 s** |
| Generation | **~2 min 20 s** for 1.44 s of audio |
| **RTF** | **≈ 97** (an M4 Pro is ~1.76) |

This machine is roughly **55× slower than the figure the roadmap was designed
around** — and it does not matter, because of how the day was spent. Every
VoxCPM job in this app is pre-rendered once and cached forever. The whole
sixteen-line chime set is one grind, then chimes forever at zero cost. **The
architecture built before the engine existed is exactly what makes the engine
usable on the machine that has it.** Had the day gone the other way — live
readback on VoxCPM — none of it would run here at all.

---

## And then it made the whole set

Sixteen lines, one model load, on the machine that was not supposed to run it:

```
Saved: output_001.wav (1.12s)   …   Saved: output_016.wav (1.44s)
16/16, no errors, ~43 minutes
```

The durations track the sentences, which is the cheapest sanity check there is —
0.64 s for *"Alarm."*, 1.92 s for *"Your timer is up."* They are installed in the
workspace as `voice-<key>.wav` and seeded into the render cache, so the first
press of **Speak them** is sixteen cache hits rather than another forty minutes.

Three things had to be fixed to get there, and each was invisible until an engine
actually existed:

**`render_set/1` ignored the cache.** The batch path always ran the engine, so
editing one line and pressing the button again would have cost the full forty
minutes. It now consults the cache first and batches only what is missing — one
changed line is one render. A batch result is filed under its *single-render*
key, because **a line's identity is what was asked for, not how it was
produced**; otherwise the same sentence lives in two cache entries and gets made
twice.

**The test suite stopped being hermetic.** `Engine.resolve/0` treated a
configured path as first-among-candidates, so a test pointing the override at
nothing fell *through* to the real venv and ran the actual model — hanging a unit
test for sixty seconds. A suite whose result depends on whether the developer
happens to have VoxCPM installed is not a suite. A configured path is now
authoritative.

**The LiveView stub only knew one shape.** Switching the button from `design` to
`batch` silently stopped installing anything, while every assertion about the
rendered page still passed.

---

## What is still open

- **A listen.** Does a VoxCPM clone sound like the operator? Free on
  `openbmb/VoxCPM-Demo`. It gates the phone greeting, not the chimes.
- **`supabase functions deploy voice`**, then phone the number. The greeting path
  is tested against a `Req.Test` plug, not against Twilio.
- **The GQA back-port lives in site-packages**, so `pip install --upgrade voxcpm`
  discards it. Documented at the top of the file it patches.
- **`Pockets.BrandTest` is red on any clean clone** — `/priv/static/images/brand/`
  is gitignored, so a release built anywhere but this Mac ships with no icons.
  Found 09-02, unrelated to voice, still open.
