# Voice STT — Finish Verification on the Packaged Build (2026-06-28)

**Date:** 2026-06-28 · **App version:** 0.1.0 · **Surface:** Home chat composer + Settings → Voice
**Supersedes** `daily-growth/old-maps/06-27-26-voice-stt-quality-roadmap.md` — that roadmap's Phase A ("name the failing layer") is now **done**; this one carries the remaining work and reframes it around the build-to-`.app`/DMG milestone.

## The verdict (this is the thing the last five laps were missing)

The garbage transcripts were **whisper hallucinating on pure silence.** Every recording in
`~/Library/Application Support/BusterClaw/voice-debug.log` reads `peak=0.0000, rms=0.0000` —
a buffer of literal zeros, captured at the right length and rate. The model, the resampler,
and the decode settings were never the problem; **no audio was reaching the pipeline.**

The reason is macOS TCC (privacy permissions), and it is environmental, not a code bug:

- **A bare binary is handed a *silent* microphone.** `cargo tauri dev` runs
  `target/debug/buster-claw-desktop` — a raw executable, not an `.app` bundle. macOS does not
  grant it real mic access; it lets the cpal stream run but fills it with zeros.
- **You cannot fix that by signing the bare binary.** We tried. Signing it with the
  `audio-input` entitlement flipped macOS from *silent denial* into a **hard crash**
  (`EXC_CRASH / Namespace TCC … without a usage description`), because macOS reads
  `NSMicrophoneUsageDescription` from a real **`.app` bundle's** `Info.plist`, not from the
  section embedded in a bare executable.

**Conclusion: the microphone only works from a bundled `.app`.** Prod already is one. So voice
is a *packaging-milestone* feature to verify, not something to keep chasing in the bare dev
binary. That is why this roadmap is scoped to "when we build the app."

## What already changed in code (committed-to-working-tree, 2026-06-28)

`desktop/tauri/src/voice.rs` now asks macOS for mic access explicitly and **crash-safely**:

- New `mic_auth::ensure_authorized()`, called at the top of `stt::start`. It always *reads*
  `AVCaptureDevice authorizationStatusForMediaType:` (safe; never shows UI, never crashes).
- It only ever *requests* access (`requestAccessForMediaType:`, which can crash without a
  bundle Info.plist) when `in_app_bundle()` is true — i.e. inside a packaged `.app`. From a
  bare dev binary it returns a clear error instead of crashing or recording zeros.
- Net effect: **in the bundle the system mic prompt fires and a denial is a real error; in
  the bare dev binary the feature degrades gracefully.** AVFoundation is linked for this.

Also already applied last session but **never tested on real audio** (because there was none):
the decode path is now `BeamSearch{beam_size:5}`, `no_speech_thold=0.6`, `suppress_blank`,
`suppress_nst`, `single_segment`, `no_context`, `temperature=0`/`temperature_inc=0`, plus an
energy-based `trim_silence` before whisper. These are the anti-hallucination knobs from the
06-27 plan; the packaged build is their first honest test.

## Abandoned approaches (don't re-try these)

| Approach | Why it failed |
|---|---|
| Sign the bare dev binary with a self-signed cert + `audio-input` entitlement | Turned silent denial into a **SIGABRT crash** — bare executables have no bundle Info.plist for TCC to read. |
| Run the bare debug binary directly (skip `cargo tauri dev`) to create a signing seam | Webview lost the dev `:4000` origin and rendered blank; also still a bare binary → no mic. |
| Pre-`cargo build` + sign `deps/` artifact, then `cargo tauri dev --no-watch` | Built the *non-dev* (frontendDist) binary → placeholder/blank screen; still bare → crash on mic. |

The `BusterClaw Dev` self-signed cert is still in the login keychain (harmless, now unused;
remove with `security delete-identity -c 'BusterClaw Dev'` if desired).

---

## Phase A — Build the packaged app with the model riding along

*The bundle is the prerequisite for every mic test below.*

- [ ] **Make the build fetch the model.** `scripts/build_desktop.sh` does NOT call
      `scripts/fetch_whisper_model.sh` today, so a clean build bundles an empty `models/` dir →
      voice silently dead in the `.app`. Add the (idempotent) fetch call before the Tauri bundle.
- [ ] Run `./scripts/build_desktop.sh`; confirm the `.app` (and DMG) contain
      `Contents/Resources/models/ggml-base.en.bin` and that `resolve_voice_model` finds it in the
      packaged layout (not just the dev `CARGO_MANIFEST_DIR` path).
- [ ] Confirm the bundled `Info.plist` carries `NSMicrophoneUsageDescription` and the app is
      signed with `Entitlements.plist` (`com.apple.security.device.audio-input`).

### Exit criteria
- [ ] A from-clean `build_desktop.sh` yields a launchable `.app` that contains the whisper model.

---

## Phase B — On-device mic verification in the bundle (the real Phase A from 06-27)

*This is the test that has never been run with actual audio. Do it in the built `.app`.*

- [ ] Launch the `.app`. First recording → macOS shows the **microphone prompt** → allow.
      (This is the prompt that never appeared from the bare dev binary — its absence was the bug.)
- [ ] Record one known sentence in Settings → Voice. In `voice-debug.log`, confirm
      `peak`/`rms` are now **non-zero** (e.g. peak > 0.05) and `duration` matches what you spoke.
      **Non-zero peak is the single milestone this whole effort has been blocked on.**
- [ ] Play `voice-debug-raw.wav` (native rate) and `voice-debug-16k.wav` (what whisper hears):
  - Raw silent/wrong-source → device/permission issue persists → re-examine TCC.
  - 16k distorted vs. raw → resampler issue → Phase D below.
  - Both clean → judge the transcript: accurate enough to press Enter on?
- [ ] Test the denied path: deny the prompt once → confirm the UI shows the
      "enable under System Settings → Microphone" error (via `voice_error` flash), no crash.

### Exit criteria
- [ ] Real audio reaches whisper (non-zero peak), and a normal spoken sentence transcribes
      usefully with the decode settings already in place. If transcription is poor on *clean*
      audio → Phase C.

---

## Phase C — Decode / model tuning (only if clean audio still transcribes poorly)

*The anti-hallucination knobs are already in; this is the fallback if they're insufficient.*

- [ ] Re-measure against the saved `voice-debug-16k.wav`; tweak `no_speech_thold`, beam size,
      or the `trim_silence` threshold before anything heavier.
- [ ] If `base.en` can't clear the bar on clean audio, A/B `small.en` (466 MB) or a quantized
      `base.en-q5_1` / `small.en-q5_1`. Update `MODEL=` in `scripts/fetch_whisper_model.sh`
      **and** the path in `main.rs` (`resolve_voice_model`) in lockstep.
- [ ] Re-check first-load + per-utterance latency on the target Mac; keep it interactive.

### Exit criteria
- [ ] Chosen model + decode config clears the quality bar at acceptable size/latency.

---

## Phase D — Resampler hardening (only if Phase B blames the 16k buffer)

- [ ] If the box-average downsample still aliases, swap `resample_to_16k`'s downsample path to a
      proper sinc/polyphase resampler (e.g. `rubato`); keep linear upsample for sub-16k devices.
- [ ] Consider requesting a 16 kHz / 48 kHz-mono cpal config directly when the device supports it.

### Exit criteria
- [ ] `voice-debug-16k.wav` is audibly faithful to the raw capture.

---

## Phase E — Notarization + entitlement survival (the open distribution risk)

- [ ] Confirm the statically-linked whisper.cpp lib + the `audio-input` entitlement survive
      **codesign + notarization** end to end. Fallback if it fights notarization: bundle
      `whisper-cli` and shell out instead of linking.
- [ ] Verify mic works on first launch of the **notarized, Gatekeeper-quarantined** `.app`
      (download/copy it fresh, not the local build), not just an ad-hoc-signed local bundle.

### Exit criteria
- [ ] A signed, notarized `.app` transcribes on first launch with no manual model step.

---

## Phase F — Gate the debug scaffolding (do before shipping the DMG)

*`write_debug_wav` + `debug_log` currently run on EVERY recording and write audio to users' disks.*

- [ ] Gate the WAV dumps + log file behind `std::env::var("BUSTER_CLAW_VOICE_DEBUG") == Ok("1")`
      (default OFF) via one `voice_debug_enabled()` helper at the call sites
      (`voice.rs` `write_debug_wav` / `debug_log` callers).
- [ ] Document the flag in `docs/DESKTOP_PACKAGING.md` ("set `BUSTER_CLAW_VOICE_DEBUG=1` to dump
      capture WAVs for triage").

### Exit criteria
- [ ] A default release build writes nothing to `~/Library/Application Support/BusterClaw/`
      during voice use; the dumps reappear only with the env flag set.

---

## Phase G — Tests + acceptance

- [ ] **Rust fixture test:** check a short known WAV into `desktop/tauri` test assets; assert
      `transcribe()` returns expected text within a token-overlap tolerance — catches decode/model
      regressions without a mic.
- [ ] **Resample unit test:** a synthetic 48k→16k tone stays in-band (no alias).
- [ ] **On-device acceptance:** hold/click mic → speak → composer fills accurately; mic-denied +
      model-missing degrade gracefully; TTS pauses while recording (barge-in). Use Settings → Voice
      as the standing manual harness.

### Exit criteria
- [ ] CI-runnable fixture coverage for transcribe + resample; a green on-device acceptance pass.

---

## Optional — Dev-mode mic (nice-to-have, not on the critical path)

Voice is verifiable in the packaged build (above); dev-mode mic is a convenience, not a blocker.
If we want it: wrap the dev binary in a **minimal unsigned `.app`** (`Contents/MacOS/<bin>` +
`Contents/Info.plist` with the usage string) and launch *that* instead of the bare binary — a real
bundle lets macOS read the usage string and prompt, and `main.rs`'s debug branch still points the
webview at live Phoenix on `:4000`. Build it as a separate script so `dev.sh` stays untouched, and
verify it both renders and prompts before adopting it.

## Key files

| Concern | File |
|---|---|
| Capture + resample + transcribe + mic auth + debug dumps | `desktop/tauri/src/voice.rs` |
| Model path resolution (dev vs packaged) | `desktop/tauri/src/main.rs` (`resolve_voice_model`) |
| Model fetch (pin/swap the model here) | `scripts/fetch_whisper_model.sh` |
| **Build must fetch the model** (Phase A gap) | `scripts/build_desktop.sh` |
| Bundle mapping + entitlement + usage string | `desktop/tauri/tauri.conf.json`, `Entitlements.plist`, `Info.plist` |
| Mic hook + device picker (JS) | `assets/js/app.js` (`Mic`, `VoiceDevices`, `VoiceBridge`) |
| Settings mic-test harness | `lib/buster_claw_web/live/voice_live.ex` |
| Packaging/size docs | `docs/DESKTOP_PACKAGING.md`, `BUILD.md` |

## Open risks

- [ ] **Notarization vs. static whisper.cpp + `audio-input` entitlement** — unproven end to end.
- [ ] **Decode quality on real audio is still unmeasured** — the tuning may need Phase C.
- [ ] **Bundle size** — `small.en` ~triples the model footprint; quantized variants mitigate.
- [ ] **Debug WAVs still ship hot** until Phase F lands — don't cut a DMG before gating them.

## Suggested first action (when we pick this back up)

Phase A: add the `fetch_whisper_model.sh` call to `build_desktop.sh`, build the `.app`, and do
the one recording that has been blocked this whole time — confirm a **non-zero peak** in the log.
Everything else branches off that single observation in the bundle.
