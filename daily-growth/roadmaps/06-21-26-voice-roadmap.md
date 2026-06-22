# Voice Roadmap — Give Buster Claw a Voice (2026-06-21)

**Date:** 2026-06-21 · **App version:** 0.1.0 · **Surface:** Home chat (`StatusLive` + `ChatPanel`)

## Why this exists

The home chat is text-only. We want Buster Claw to **speak its replies** (TTS) and **listen to spoken input** (STT) directly in the chat, so the user can talk to it hands-light instead of typing. This is the first step toward a conversational, voice-driven assistant.

The whole feature runs **inside the Rust/Tauri shell** and is exposed to the webview as Tauri commands, exactly like the existing `browser_*`, `terminal_*`, and `browser_screenshot` bridges. Nothing here goes through `BusterClaw.Commands` — voice is local device I/O (microphone, speaker), not an agent-callable capability, so it does not belong on the policy/tier/audit command surface.

> **Status (2026-06-21):** Phase 1 (TTS) shipped; Phase 0 + Phase 2 (STT) code-complete.
> - Phase 0 (TTS slice) — capability + permissions + non-desktop fallback — ✅
> - Phase 1 — TTS output (speak/stop, bridge, server push, barge-in, toggle) — ✅
> - Phase 0 (STT slice) — mic entitlement + Info.plist, cpal/whisper-rs deps, model bundle plumbing + boot self-check — ✅
> - Phase 2 — STT input (cpal capture → whisper transcribe → composer) — ✅ **code-complete; `cargo build` PASSES (whisper.cpp builds + links statically, 39M binary), Elixir/JS + tests green. Only the on-device mic test remains.**
> - Phase 3 — polish — ⏳
>
> **Phase 2 note (2026-06-21):** `voice.rs` gained `start_recording`/`stop_recording`
> (macOS `mod stt`): cpal captures mono PCM on a dedicated thread (the `!Send`
> stream lives and dies there), downmixed + linear-resampled to 16 kHz, transcribed
> by a cached `WhisperContext` (loaded once). Commands registered in `main.rs` +
> capabilities + permission TOMLs; the model path is published via
> `voice::set_model_path`. UI: a hidden-until-Tauri 🎤 button in the composer
> (`chat_panel.ex`) with listening/transcribing states; the `AgentChat` hook
> (`app.js`) wires push-to-talk on press/hold and the ⌘/ hotkey, cuts TTS first
> (barge-in), and **fills the composer without auto-sending** (v1). Errors route
> through a new `voice_error` LiveView event → **flash** (a deliberate simplification
> of the roadmap's "inline :error chat bubble" — flash avoids touching the
> PubSub-owned transcript model; revisit in Phase 3 if a bubble is wanted).
>
> **Phase 0 STT note (2026-06-21):** Per the locked decision, de-risk the build
> before feature code. Added `cpal = "0.18"` + `whisper-rs = "0.16"` (metal) to
> the macOS target deps; a `voice::run_selfcheck` (called from `main.rs` `setup()`,
> threaded, non-fatal) references both crates so a plain `cargo build` actually
> links whisper.cpp — and at runtime logs a mic-present + model-load check.
> Model bundles via a new stable `resources/models/` mapping (NOT the volatile
> `resources/release/`), fetched by `scripts/fetch_whisper_model.sh`. Mic perms:
> `Info.plist` (`NSMicrophoneUsageDescription`) + `Entitlements.plist`
> (`audio-input`), wired in `tauri.conf.json`. **Next: user runs `cargo build`
> (or `cargo tauri dev`) in `desktop/tauri` to confirm whisper-rs links cleanly;
> if it fights notarization later, fall back to bundled `whisper-cli` + shell out.**
>
> **Implementation note:** v1 TTS drives macOS's built-in `say(1)` (the system
> synthesizer — same voices as AVSpeechSynthesizer, fully offline) from a worker
> thread in `desktop/tauri/src/voice.rs`, rather than AVFoundation FFI. Zero
> `unsafe`, far lower build risk, audibly identical. Swap to AVSpeechSynthesizer
> only if we later need pause/resume or word-boundary highlighting.

### Decisions (locked 2026-06-21)

| Question | Decision | Rationale |
|---|---|---|
| Speech stack | **whisper.cpp (local STT) + AVSpeechSynthesizer (native TTS)** | Fully offline, no audio egress, fits the local-first/privacy identity. Cost: ~150MB model in the bundle + native bridging. |
| Input trigger | **Push-to-talk button + hotkey** | Predictable, no false triggers, no TTS→mic feedback loop. Hands-free/VAD deferred. |
| Output mode | **Auto-speak every reply, toggleable, with stop/barge-in** | Strongest "has a voice" feeling; the toggle + barge-in keep it from being annoying. |

### The load-bearing technical facts (verified in the codebase)

- **WKWebView (the desktop shell's webview) does not support the Web Speech API's `SpeechRecognition`, and `speechSynthesis` is unreliable there.** Browser-native speech is off the table; speech must run shell-side.
- Capturing audio **natively in Rust** (vs. webview `getUserMedia`) sidesteps fragile WKWebView media-permission plumbing. The OS prompts the native process once.
- **Output seam:** every assistant reply funnels through one place — `StatusLive.apply_chat/3` handling `{:message, %{role: :assistant, text: text}}` → `push_msg/3` (`lib/buster_claw_web/live/status_live.ex:223`). This is the single point to fire TTS.
- **A single turn emits multiple `:assistant` messages.** `BusterClaw.Agent.Chat.project_event/2` calls `emit_message(:assistant, text)` for **each** `assistant_text` stream block (`lib/buster_claw/agent/chat.ex:373`), interleaved with tool calls. The `:result` event emits only a `:meta` cost/turns line, **not** the final text. → TTS must **enqueue per block** (AVSpeechSynthesizer queues utterances naturally); barge-in flushes the queue. Do **not** assume one final reply.
- **Input seam:** `chat_send` takes `%{"message" => text}` (`status_live.ex:73`); the `AgentChat` JS hook already owns the textarea/form/keydown (`assets/js/app.js:452`). STT only has to produce text and submit the existing form — **no backend dispatch change**.
- **Bridge precedent to copy:** `ScreenshotBridge` (`assets/js/app.js:425`) — an always-mounted hook that listens for a server push, calls `window.__TAURI__.core.invoke(...)`, and degrades gracefully when `__TAURI__` is absent (plain browser / dev).

## What we are NOT doing (v1)

- **Hands-free / voice-activity detection (VAD)** — push-to-talk only. Revisit after v1.
- **Auto-send after transcription** — v1 fills the composer and lets the user review + press Enter. Auto-send becomes an opt-in toggle in a later phase.
- **Cloud TTS/STT (ElevenLabs/OpenAI/Deepgram)** — rejected for privacy/offline. (Anthropic has no speech API regardless.)
- **Token-by-token streaming TTS** — we speak per assistant *block* (the unit Chat already broadcasts), not per token.
- **Voice in surfaces other than home chat** — terminal, browser, etc. are out of scope.
- **Windows/Linux voice** — macOS only (the shell is macOS-only today). Keep the Rust seam abstract enough to not actively preclude it.

---

## Phase 0 — Scaffolding, permissions, bundling

*Foundation. Nothing user-visible. De-risks the build (whisper linking, model bundling, mic entitlement) before any feature code.*

### 0A. Microphone permission + entitlement
- [x] Add `NSMicrophoneUsageDescription` to the macOS Info.plist — created `desktop/tauri/Info.plist` (Tauri v2 merges a project-root Info.plist).
- [x] Add the `com.apple.security.device.audio-input` entitlement — created `desktop/tauri/Entitlements.plist`, referenced from `tauri.conf.json` `bundle.macOS.entitlements`.
- [x] Cross-ref: rides the distribution roadmap's Apple-signing critical path (noted in `docs/DESKTOP_PACKAGING.md`).

### 0B. Rust dependencies
- [x] Add `cpal` (CoreAudio microphone capture) to `desktop/tauri/Cargo.toml` (`0.18`, macOS target deps).
- [x] Add `whisper-rs` (statically compiles whisper.cpp; Metal backend) — `0.16`, `features = ["metal"]`.
- [x] **Confirm a clean `cargo build` and that whisper-rs links** — ✅ **PASSED 2026-06-21.** whisper.cpp (whisper-rs-sys 0.15) built from source and linked statically; `cargo build` produces a 39M debug binary with 0 errors / 0 voice.rs warnings. The de-risk gate is cleared; the `whisper-cli` shell-out fallback is unneeded. (Fixing surfaced real cpal 0.18 / whisper-rs 0.16 API drift: `build_input_stream` takes `StreamConfig` by value, `SampleRate` is `type = u32`, `Device` name via `description().name()`, segment text via `get_segment(i).to_str_lossy()`.)

### 0C. Bundle the model
- [x] Stable bundle location: `desktop/tauri/resources/models/ggml-base.en.bin` via a new `resources/models` → `models` mapping (kept out of the volatile `resources/release/` that the build/dev launcher wipe). Fetched by `scripts/fetch_whisper_model.sh`; gitignored.
- [x] Resolve the model path at runtime — `resolve_voice_model(app)` in `main.rs` (resource-dir lookup in release, in-repo path in dev).
- [x] Document the model + bundle-size delta (~150MB) in `docs/DESKTOP_PACKAGING.md` and `BUILD.md`.

### 0D. Tauri command capabilities
- [x] Register `speak`, `stop_speaking` in `desktop/tauri/capabilities/default.json` + invoke_handler. *(`start_recording`/`stop_recording` added in Phase 2 — capabilities + `start_recording.toml`/`stop_recording.toml`.)*
- [x] Add matching `permissions/autogenerated/*.toml` entries (`speak.toml`, `stop_speaking.toml`).

### 0E. Non-desktop fallback plumbing
- [x] Graceful-degradation contract: in a plain browser (`window.__TAURI__` absent) `bc:speak` is a silent no-op (VoiceBridge gates on `__TAURI__`); the mic button (Phase 2) will hide.

### Exit criteria
- [ ] App builds and boots with the new deps + model bundled; no functional change yet; mic-permission string present in the built `.app`.

---

## Phase 1 — Voice output (TTS) — *ship first, fastest win*

*Get a talking Buster Claw and prove the Tauri-command + JS-bridge + server-push loop end to end, before the heavier STT work.*

### 1A. Rust — native speech (`desktop/tauri/src/voice.rs`, new module)
- [x] Create a `voice` module; register it in `main.rs` (`mod voice;`) and add its commands to the Tauri `invoke_handler`.
- [x] `speak(text: String)` — enqueue on a shared `VecDeque`; a background worker plays lines via `say(1)` in order → matches the multi-block reality.
- [x] `stop_speaking()` — bump a generation counter (worker kills the line now playing within ~40ms) and clear the queue.
- [x] Guard the shared queue behind a `Mutex` + `Condvar` (commands arrive on the Tauri worker thread).

### 1B. JS — `VoiceBridge` hook (`assets/js/app.js`)
- [x] Add an always-mounted `VoiceBridge` hook (layout header, like `ScreenshotBridge`).
- [x] Handle server event `bc:speak` → read the `bc:voice-out` localStorage toggle → if on **and** `__TAURI__` present, `invoke("speak", {text})`.
- [x] Handle `bc:stop_speak` → `invoke("stop_speaking")`.
- [x] No-op cleanly when `__TAURI__` is absent.
- [x] Mount the hook element in the layout header (beside `ScreenshotBridge`).

### 1C. Server — fire TTS on assistant messages (`lib/buster_claw_web/live/status_live.ex`)
- [x] In `apply_chat/3` for `{:message, %{role: :assistant, text: text}}` on the **active** conversation, also `push_event(socket, "bc:speak", %{text: text})` (via `maybe_speak/3`).
- [x] **Only `:assistant`** — never `:tool`, `:meta`, or `:error` lines.
- [ ] Confirm on-device that it fires once per assistant block (multiple per turn → multiple enqueued utterances, played in order).

### 1D. Barge-in
- [x] Emit `bc:stop_speak` on: `cut_run` / Esc, and a new user `chat_send`. Toggle-off fires the local `bc:voice-stop` event. (Recording-start also cuts TTS — `startListening` calls `stop_speaking` first; landed in Phase 2.)
- [ ] Verify on-device that Esc both stops the model **and** cuts speech.

### 1E. UI toggle (`lib/buster_claw_web/components/chat_panel.ex`)
- [x] Add a "Voice on/off" control in the chat header, beside the thinking chip / Stop button (`VoiceToggle` hook).
- [x] Persist state to `localStorage["bc:voice-out"]` (client-side; the server always pushes `bc:speak`).
- [x] Brutalist styling: `border-2`, hazard accent (`text-primary`/`border-primary`) when on, mono micro-label, muted when off.

### Exit criteria
- [x] Code complete + compiles (Elixir `--warnings-as-errors`, esbuild clean).
- [ ] **On-device:** with Voice ON, each assistant reply is spoken in order; Esc / new message / toggle-off cuts speech immediately; OFF is silent; plain-browser dev is unaffected. *(Requires the user to build/run the desktop app.)*

---

## Phase 2 — Voice input (STT)

*The heavier half: native mic capture + on-device whisper transcription, wired into the existing composer.*

### 2A. Rust — capture + transcribe (`desktop/tauri/src/voice.rs`)
- [x] `start_recording()` — opens a `cpal` input stream into a shared PCM buffer; capture thread owns the `!Send` stream and parks until stop. One in-flight recording (rejects re-entry).
- [x] `stop_recording()` — stops the stream, transcribes via a cached `WhisperContext`, returns `{ text }`.
- [x] Resample/downmix — callback downmixes to mono; `resample_to_16k` linear-resamples to 16 kHz when the device rate differs.
- [x] Empty/too-short capture (< ~0.2s) → returns empty text, not an error.

### 2B. Composer UI (`lib/buster_claw_web/components/chat_panel.ex`)
- [x] 🎤 mic button in the chat `<form>` between textarea and Send.
- [x] State visuals: hazard-accent border while listening, spinner while transcribing (`data-state` driven).
- [x] Hidden until the `AgentChat` hook confirms `__TAURI__` (plain browser never shows it).

### 2C. `AgentChat` hook — push-to-talk (`assets/js/app.js`)
- [x] mic `pointerdown` / ⌘/ hotkey: `stop_speaking()` first (barge-in), then `start_recording()`, "listening" state.
- [x] `pointerup` / hotkey-release: `stop_recording()` → insert text into `[data-chat-input]`.
- [x] v1: fills the textarea, does **not** auto-send.
- [x] Listeners cleaned up in `destroyed()`.

### 2D. Robustness
- [x] Mic-denied path → friendly message (System Settings hint), surfaced via the `voice_error` → flash. *(flash, not a chat `:error` bubble — see status note.)*
- [x] Model-load / transcription failure → error surfaced, button returns to idle (`finally`).
- [x] Re-entry guarded (`start` rejects while active; `setMicState` gates the hook).

### Exit criteria
- [x] Code-complete; Elixir `--warnings-as-errors` + esbuild clean; `StatusLiveTest` green (mic button rendered, `voice_error` flashes).
- [ ] **On-device:** hold mic/hotkey → speak → release → transcript fills the composer; user reviews + sends; mic-denied/model-missing degrade gracefully; TTS pauses while recording. *(Requires the user to build/run the desktop app with the model fetched.)*

---

## Phase 3 — Polish & hardening

*Make it feel intentional and configurable.*

- [ ] **Voice selection + rate/pitch** — enumerate `AVSpeechSynthesisVoice`; surface a picker + sliders in **Settings → Appearance** (`appearance_live.ex` / `settings_tabs.ex`), persisted via the existing appearance/settings store.
- [ ] **Speaking indicator** — show a "speaking" marker on the active assistant bubble; stop speech when switching conversation tabs (`select_chat`).
- [ ] **Auto-send toggle** — optional "send immediately after transcription" preference.
- [ ] **Hotkey discoverability** — surface the push-to-talk hotkey in the composer tooltip / a `kbd` hint (mirrors the existing Esc `kbd` chip).
- [ ] **Tests:**
  - [ ] `StatusLiveTest` — `assert_push "bc:speak"` fires on an assistant message and **not** on tool/meta/error lines.
  - [ ] Rust unit coverage for the record→transcribe path (fixture WAV → expected text within tolerance).
  - [ ] Manual end-to-end in the packaged `.app` (mic prompt, speak, transcribe, barge-in) — run by the user (dev server + Tauri build run on their side).
- [ ] **Docs** — short "Voice" section in the user guide / manual (`lib/buster_claw/manual.ex` or `user_guide.ex`).

### Exit criteria
- [ ] Voice is configurable, discoverable, tested, and documented.

---

## Key files

| Concern | File |
|---|---|
| Native TTS/STT (new) | `desktop/tauri/src/voice.rs` |
| Tauri wiring | `desktop/tauri/src/main.rs` (`mod voice;`, invoke_handler) |
| Rust deps / bundle | `desktop/tauri/Cargo.toml`, `desktop/tauri/resources/release/ggml-base.en.bin` |
| Permissions | `desktop/tauri/Info.plist` (mic usage), entitlements, `capabilities/default.json`, `permissions/autogenerated/*.toml` |
| JS bridges + hooks | `assets/js/app.js` (`VoiceBridge` new; `AgentChat` extended) |
| TTS trigger (server) | `lib/buster_claw_web/live/status_live.ex` (`apply_chat/3`) |
| Composer UI + toggle | `lib/buster_claw_web/components/chat_panel.ex` |
| Settings (Phase 3) | `lib/buster_claw_web/live/appearance_live.ex`, `components/settings_tabs.ex` |
| Tests | `test/buster_claw_web/live/status_live_test.exs`, Rust tests in `desktop/tauri/` |
| Docs | `docs/DESKTOP_PACKAGING.md`, `BUILD.md`, user guide |

## Open risks to validate during build

- [ ] **whisper-rs build/notarization** — confirm static whisper.cpp links cleanly in the Tauri build and survives notarization. Fallback: bundled `whisper-cli` binary + shell out.
- [ ] **Bundle size +~150MB** — accepted; document it.
- [ ] **First-run mic prompt** — OS prompts on first `start_recording`; make the denied path obvious.
- [ ] **Signing interaction** — audio-input entitlement + model-in-resources interact with the existing Apple-signing critical path; coordinate.
- [ ] **Multi-block utterance ordering** — verify enqueued utterances play in the order assistant blocks arrive, and barge-in flushes all of them.

## Suggested first action

Start with **Phase 0** (deps, model bundle, mic entitlement) to de-risk the build, then **Phase 1A–1C** — `voice.rs` `speak`/`stop_speaking`, the `VoiceBridge` hook, and the `bc:speak` push in `status_live.ex`. That yields a talking Buster Claw and proves the full command→bridge→server-push loop before the heavier STT work in Phase 2.
