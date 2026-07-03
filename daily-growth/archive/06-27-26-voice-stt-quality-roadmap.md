# Voice STT Quality Roadmap — Make Transcription Actually Work (2026-06-27)

**Date:** 2026-06-27 · **App version:** 0.1.0 · **Surface:** Home chat composer + Settings → Voice
**Supersedes the STT half of** `daily-growth/roadmaps/06-21-26-voice-roadmap.md` (TTS is done and stays as-is).

## Why this exists

STT was marked "code-complete" on 06-21, but "code-complete" only ever meant
*compiles + Elixir/JS tests green* — **every on-device exit criterion is still
unchecked.** When the pipeline was finally run against a real microphone (evening
of 06-23) it returned garbage: roughly *two inaccurate words for a whole spoken
sentence*. That is the signature of **whisper hallucinating on bad audio**, not a
broken model — the model loads and runs fine.

Five commits that night iterated on the pipeline (anti-alias resample, gain
normalize, WAV/​log diagnostics, a Settings mic-test page, a device picker) **but
never reached a root-cause verdict.** The diagnostic WAV dumps were added
specifically to isolate *capture vs. resample vs. model* — and then nobody is on
record having listened to them. This roadmap stops the blind rebuild loop: it
**diagnoses first**, then fixes the proven layer, then hardens and ships.

> **Status (2026-06-27):** STT is wired end-to-end but produces unusable
> transcripts on-device. Root cause **unknown** (capture / resample / decode /
> model all still suspects). Debug scaffolding is live and unconditional. No model
> fetch in the build script. This roadmap is the path from "wired" to "works well."

---

## The trial log (what's already been tried — don't repeat it)

| # | Commit | Hypothesis | Change | Verdict |
|---|---|---|---|---|
| 1 | `eb07deb` | — (UX) | Reusable `Mic` hook; click-to-talk; listening animation | n/a — not a quality change |
| 2 | `45420e0` | Resample aliasing + quiet mic | Naive decimation → **box-average downsample** (cheap low-pass); **peak normalize** when `0.02 < peak < 0.7`; added start/stop diagnostics (rate/channels/format/peak/rms/transcript) | **Unconfirmed** — shipped without an on-device A/B |
| 3 | `22fa5bd` | Can't tell which layer is bad | **Dump raw + 16 kHz WAVs + `voice-debug.log`** on every recording to isolate capture vs. resample vs. model by ear | **The dumps exist; nobody has reported listening to them** ← the open gate |
| 4 | `a93ea0b` | Need a repeatable test surface | Settings → Voice tab with a live mic test box | Useful harness; doesn't change quality |
| 5 | `b2d87d1` | Wrong/silent input device captured | `list_input_devices` + device picker; `start_recording(device)` binds a chosen mic | **Unconfirmed** — plausible but untested as the actual cause |

**Lesson:** four of five changes were pipeline edits made *before* the captured
audio was ever inspected. The instrumentation to end the guessing already exists
(trial #3). Phase A just makes us use it.

---

## Current shape (verified in code, 2026-06-27)

**Model** — `desktop/tauri/resources/models/ggml-base.en.bin` (142 MB), loaded once
into a cached `WhisperContext` (`voice.rs:600`). `base.en` is the second-smallest
tier; it is *known* to hallucinate on short, quiet, or non-speech audio.

**Decoding** (`stt::transcribe`, `voice.rs:621`) — `SamplingStrategy::Greedy
{ best_of: 1 }`, `language: "en"`, `n_threads ≤ 8`. **Missing every
anti-hallucination knob:** no `no_speech` threshold, no `suppress_blank`, no
temperature-fallback control, no `single_segment`, no VAD / silence trim.

**Audio path** (`stt::stop` / `resample_to_16k` / `capture`) —
cpal native-rate capture → per-callback downmix to mono → **box-average**
downsample to 16 kHz → conditional peak-normalize (`0.02 < peak < 0.7`, gain ≤ 12×)
→ whisper. Captures `< 0.2 s` post-resample return empty text.

**Diagnostics** (`voice.rs:404–505`) — `write_debug_wav` (raw + 16k), `debug_log`,
and `eprintln!` lines run **unconditionally on every recording** and write to
`~/Library/Application Support/BusterClaw/`. No `cfg`/flag gate. *This will ship.*

**Distribution** — model is gitignored; `scripts/fetch_whisper_model.sh` fetches it
into `resources/models/`; `tauri.conf.json` bundles that dir. **But
`scripts/build_desktop.sh` does NOT call the fetch script** — a clean build bundles
an empty models dir → voice silently dead in the packaged app.

---

## Decisions (proposed — confirm before Phase B)

| Question | Proposed decision | Rationale |
|---|---|---|
| Fix order | **Diagnose → decode tuning → model → resampler**, in that order | Cheapest, highest-information-first. Don't upsize the model until decode tuning is proven insufficient on *clean* audio. |
| Decode strategy | Move to **BeamSearch + no_speech/suppress_blank/no-temp-fallback** | Greedy+best_of:1 with no thresholds is the single most likely decode-layer cause of "few hallucinated words." |
| Model ceiling | Allow upgrade to **`small.en`** (466 MB) or a **quantized `*-q5_1`** variant if `base.en` can't hit the bar on clean audio | Quality/size tradeoff; the swap is already a one-line `MODEL=` + `main.rs` path change. |
| Debug scaffolding | **Gate behind `BUSTER_CLAW_VOICE_DEBUG=1`** (default off), don't delete | Keep the isolation tool for the next regression; just stop shipping disk writes to users. |
| Hands-free / VAD | Still **deferred**; add only *silence-trim* VAD (a denoise/quality aid), not push-to-talk replacement | Trimming non-speech is a hallucination fix, not a UX change. |

---

## Phase A — Diagnose with the instrumentation already in place

*Gate. No pipeline edits until the failing layer is named. The WAV dumps from
trial #3 are the whole point — use them.*

- [ ] Build/run the desktop app, record one known sentence via Settings → Voice.
- [ ] Play `~/Library/Application Support/BusterClaw/voice-debug-raw.wav` (native rate):
  - **Silent / wrong source / tiny level** → **capture/device problem** → Phase A1.
  - **Clean, audible speech** → capture is fine; continue.
- [ ] Play `voice-debug-16k.wav` (exact buffer handed to whisper):
  - **Distorted / robotic / aliased vs. the raw** → **resample problem** → Phase D.
  - **Clean speech, but transcript still wrong** → **decode/model problem** → Phase B → Phase C.
- [ ] Read `voice-debug.log`: confirm `peak`/`rms` are non-trivial (e.g. peak > 0.05)
      and `duration` matches what you spoke. Record the numbers in the next daily summary.
- [ ] **Write the verdict down** (which layer) before touching code. This is the
      deliverable of Phase A.

### A1 — Capture/device branch (only if raw WAV is bad)
- [ ] Confirm macOS mic permission is actually granted (TCC), not just prompted.
- [ ] Verify the device picker selects a *real* input; log the bound device name on `start`.
- [ ] Check channel/downmix: if the device is multi-channel, confirm `capture<T>`
      averages the right interleaving (a wrong channel count → silence or noise).
- [ ] Confirm sample format (`F32`/`I16`/`U16`) conversion is correct for the chosen device.

### Exit criteria
- [ ] The failing layer is named and written down. Subsequent phases touch only that layer.

---

## Phase B — Decode-layer anti-hallucination (cheap, no model change)

*Highest-probability fix if Phase A says "clean audio, wrong text." Apply and
re-measure against the same `voice-debug-16k.wav` before anything heavier.*

- [ ] Switch `Greedy { best_of: 1 }` → `BeamSearch { beam_size: 5, patience: -1.0 }`
      (verify the exact `SamplingStrategy` shape in whisper-rs 0.16).
- [ ] Set a **no-speech threshold** so near-silence yields empty text, not a hallucinated word
      (`set_no_speech_thold`, ~0.6 — verify setter name in 0.16).
- [ ] `set_suppress_blank(true)` and suppress non-speech tokens if exposed.
- [ ] Disable temperature fallback hallucination: `set_temperature(0.0)` /
      `set_temperature_inc(0.0)` (verify availability).
- [ ] For push-to-talk-length clips, try `set_single_segment(true)` and
      `set_no_context(true)` (don't condition on prior text — there is none).
- [ ] Add a lightweight **energy-based silence trim** before whisper: drop leading/
      trailing frames below an RMS floor so whisper never sees dead air (the prime
      hallucination trigger). Keep it simple — not a full VAD.
- [ ] Re-run the same utterance; compare transcript to baseline. Record WER-ish delta.

### Exit criteria
- [ ] On clean 16 kHz audio, a normal spoken sentence transcribes accurately enough
      to be useful (subjective bar: "I'd press Enter on this"). If not → Phase C.

---

## Phase C — Model upgrade (only if B is insufficient on clean audio)

- [ ] A/B `base.en` vs **`small.en`** (466 MB) vs a **quantized `base.en-q5_1` /
      `small.en-q5_1`** on the same recorded fixtures; note accuracy vs. bundle size
      vs. latency on the target Mac.
- [ ] Pick the smallest model that clears the quality bar. Update `MODEL=` in
      `scripts/fetch_whisper_model.sh` **and** the path in `main.rs`
      (`resolve_voice_model`) — keep them in lockstep (the script already warns about this).
- [ ] Re-check first-load latency (model load is one-time + cached) and per-utterance
      transcription latency; confirm it stays interactive for a short clip.
- [ ] Update the `~150 MB` bundle-size note in `docs/DESKTOP_PACKAGING.md` / `BUILD.md`
      if the model changes.

### Exit criteria
- [ ] Chosen model + decode config clears the quality bar with an acceptable size/latency cost.

---

## Phase D — Resampler / audio hardening (only if Phase A blames the 16k buffer)

- [ ] If the box-average low-pass still aliases/distorts, replace `resample_to_16k`
      with a proper sinc/polyphase resampler (e.g. the `rubato` crate) for the
      downsample path; keep linear upsample for the rare `< 16 kHz` device.
- [ ] Consider requesting a 16 kHz (or 48 kHz mono) cpal config directly when the
      device supports it, to shrink/avoid resampling.
- [ ] Re-emit `voice-debug-16k.wav` and confirm by ear it matches the raw capture.

### Exit criteria
- [ ] The 16 kHz buffer is audibly faithful to the raw capture.

---

## Phase E — Gate the debug scaffolding (do before any release)

*Currently `write_debug_wav` + `debug_log` + `eprintln!` run on every recording and
write audio to users' disks. Keep the tool, stop shipping it hot.*

- [ ] Gate all WAV dumps + the log file behind `std::env::var("BUSTER_CLAW_VOICE_DEBUG")
      == Ok("1")` (default OFF). One `voice_debug_enabled()` helper checked at the
      call sites (`voice.rs:407, 444, 459, 474`).
- [ ] Keep the `eprintln!` diagnostics (stderr only, harmless) or fold them under the
      same flag — pick one and be consistent.
- [ ] Document the flag in `docs/DESKTOP_PACKAGING.md` ("set `BUSTER_CLAW_VOICE_DEBUG=1`
      to dump capture WAVs for triage").

### Exit criteria
- [ ] A default release build writes nothing to `~/Library/Application Support/BusterClaw/`
      during voice use; the dumps reappear only with the env flag set.

---

## Phase F — Distribution: the model must ride the build

- [ ] **Call `scripts/fetch_whisper_model.sh` from `scripts/build_desktop.sh`** (idempotent;
      it skips when the model is present) so a clean clone produces a voice-capable `.app`.
      *This is the silent-breakage fix from the code-quality pass.*
- [ ] Verify the bundled `.app` actually contains the model under `resources/models/`
      and that `resolve_voice_model` finds it in the packaged layout (not just dev).
- [ ] Confirm the static whisper.cpp lib + `audio-input` entitlement survive **codesign +
      notarization** (the open risk from the 06-21 roadmap). Fallback if it fights
      notarization: bundle `whisper-cli` and shell out.
- [ ] First-run mic prompt: confirm the OS prompts once on first `start_recording`, and
      the denied path surfaces the System-Settings hint (already wired via `voice_error` → flash).

### Exit criteria
- [ ] A from-clean `./scripts/build_desktop.sh` yields a signed, notarized `.app` where
      voice transcribes on first launch with no manual model step.

---

## Phase G — Tests + acceptance

- [ ] **Rust fixture test:** check a short known WAV into `desktop/tauri` test assets;
      assert `transcribe()` returns the expected text within a tolerance (token overlap).
      This makes decode/model regressions catchable without a mic.
- [ ] **Resample unit test:** a synthetic tone downsampled 48k→16k stays in-band (no alias).
- [ ] **On-device acceptance checklist** (the unchecked items from the 06-21 roadmap):
  hold/click mic → speak → transcript fills composer accurately; mic-denied + model-missing
  degrade gracefully; TTS pauses while recording (barge-in).
- [ ] Use Settings → Voice as the standing manual harness for each rebuild.

### Exit criteria
- [ ] CI-runnable fixture coverage for transcribe + resample; a green on-device acceptance pass.

---

## Carry-over polish (from 06-21 Phase 3 — after quality is solved)

- [ ] Auto-send-after-transcription toggle (currently fills composer only).
- [ ] TTS voice selection + rate/pitch in Settings.
- [ ] Speaking indicator on the active assistant bubble; stop on tab switch.
- [ ] Push-to-talk hotkey discoverability (`kbd` hint in the composer).
- [ ] Short "Voice" section in the user guide / manual.
- [ ] Drop the reusable `Mic` hook into terminal/browser/calendar inputs (the `eb07deb` "next").

---

## Key files

| Concern | File |
|---|---|
| Capture + resample + transcribe + debug dumps | `desktop/tauri/src/voice.rs` |
| Tauri command wiring + model path resolution | `desktop/tauri/src/main.rs` (`resolve_voice_model`, invoke_handler) |
| Model fetch (pin/swap the model here) | `scripts/fetch_whisper_model.sh` |
| Build must fetch the model | `scripts/build_desktop.sh` |
| Bundle mapping + entitlement | `desktop/tauri/tauri.conf.json`, `Entitlements.plist`, `Info.plist` |
| Mic hook + device picker (JS) | `assets/js/app.js` (`Mic`, `VoiceDevices`, `VoiceBridge`) |
| Composer mic button | `lib/buster_claw_web/components/chat_panel.ex` |
| Settings mic-test harness | `lib/buster_claw_web/live/voice_live.ex` |
| Packaging/size docs | `docs/DESKTOP_PACKAGING.md`, `BUILD.md` |

## Open risks

- [ ] **Root cause is still unknown** — Phase A could send the work to B, C, *or* D.
      Don't pre-commit to a fix; let the WAVs decide.
- [ ] **whisper-rs 0.16 API drift** — verify the exact names of the decode setters
      (`set_no_speech_thold`, `set_suppress_blank`, `set_temperature_inc`, `set_single_segment`,
      `BeamSearch` fields) against the installed crate before relying on them.
- [ ] **Notarization vs. static whisper.cpp + audio-input entitlement** — unproven end to end.
- [ ] **Bundle size** — `small.en` roughly triples the model footprint; quantized variants
      mitigate but need an accuracy check.

## Suggested first action

**Phase A, today:** record one sentence, play the two WAVs already being written to
`~/Library/Application Support/BusterClaw/`, read `voice-debug.log`, and write the
one-line verdict (capture / resample / decode / model). Everything else branches off
that single observation — and it costs one recording, not another rebuild-and-guess.
