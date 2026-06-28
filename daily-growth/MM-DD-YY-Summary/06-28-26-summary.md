# 06-28-2026 Summary

Returned to the **voice STT** effort and finally found the root cause that five
prior laps had missed. Diagnosed it, proved the wrong fixes wrong, made the code
crash-safe, and rewrote the roadmap around the real path (the packaged `.app`).

## Root cause — found it

The "garbage transcripts" were **whisper hallucinating on pure silence.** Every
recording in `~/Library/Application Support/BusterClaw/voice-debug.log` logged
`peak=0.0000, rms=0.0000` — a buffer of literal zeros, captured at the right
length and rate. No audio was reaching the pipeline; the model, resampler, and
decode settings were never the problem.

The cause is **macOS TCC** (privacy permissions), environmental not a code bug:

- A bare `cargo tauri dev` binary is handed a *silent* microphone — the stream
  runs, but every sample is zero. No prompt, no error.
- You **cannot** fix that by signing the bare binary. Signing it with the
  `audio-input` entitlement flipped silent-denial into a **hard crash**
  (`EXC_CRASH / Namespace TCC … without a usage description`), because macOS
  reads `NSMicrophoneUsageDescription` from a real `.app` **bundle's** Info.plist,
  not from a bare executable's embedded section.

**Conclusion: the mic only works from a bundled `.app`.** Prod already is one, so
voice is a packaging-milestone feature to verify, not something to chase in dev.

## Dead ends ruled out (don't re-try)

- Sign the bare dev binary with a self-signed cert + `audio-input` entitlement →
  SIGABRT crash on mic access.
- Run the bare debug binary directly (to create a signing seam) → webview lost the
  dev `:4000` origin and rendered blank.
- Pre-`cargo build` + sign cargo's `deps/` artifact, then `cargo tauri dev
  --no-watch` → built the non-dev (frontendDist) binary → placeholder/blank screen.

Reverted `scripts/dev.sh` to its original `exec cargo tauri dev`, removed the
throwaway `scripts/setup_dev_cert.sh`, and stripped the leftover signatures. The
`BusterClaw Dev` self-signed cert remains in the login keychain (harmless, unused).

## Code change that survived

`desktop/tauri/src/voice.rs` now asks macOS for mic access explicitly and
**crash-safely** (`mic_auth::ensure_authorized()`, called from `stt::start`):

- Always *reads* `AVCaptureDevice authorizationStatusForMediaType:` (safe; no UI,
  never crashes).
- Only *requests* access (`requestAccessForMediaType:`, the crashy call) when
  `in_app_bundle()` — i.e. inside a packaged `.app`. From a bare dev binary it
  returns a clear error instead of crashing or recording zeros. AVFoundation is
  now linked for this.

In the bundle this makes the system mic prompt fire and turns a denial into a real
error; in the bare dev binary the feature degrades gracefully.

## Roadmap housekeeping

- Wrote `daily-growth/roadmaps/06-28-26-voice-stt-packaging-verification-roadmap.md`
  — captures the verdict, the dead ends, the current code state, and the remaining
  work framed around the build-to-`.app`/DMG milestone (fetch the model in
  `build_desktop.sh`, on-device mic verification in the bundle, decode/resampler
  fallbacks, notarization survival, gate the debug WAV dumps, tests + acceptance).
- Moved the now-superseded
  `06-27-26-voice-stt-quality-roadmap.md` to `daily-growth/old-maps/` — its "name
  the failing layer" gate is done.

## Notes

- Decode anti-hallucination knobs from 06-27 (BeamSearch, `no_speech_thold`,
  `suppress_blank`/`suppress_nst`, `single_segment`, `no_context`, temperature 0,
  `trim_silence`) are in place but still **untested on real audio** — the packaged
  build is their first honest test.
- Open distribution gap noted in the roadmap: `scripts/build_desktop.sh` does not
  yet call `scripts/fetch_whisper_model.sh`, so a clean build bundles an empty
  models dir → voice silently dead in the `.app`.
