# Voice Roadmap — Give Buster Claw a Voice (2026-06-21)

**Date:** 2026-06-21 · **App version:** 0.1.0 · **Surface:** Home chat (`StatusLive` + `ChatPanel`)

## Why this exists

The home chat is text-only. We want Buster Claw to **speak its replies** (TTS) and **listen to spoken input** (STT) directly in the chat, so the user can talk to it hands-light instead of typing. This is the first step toward a conversational, voice-driven assistant.

The whole feature runs **inside the Rust/Tauri shell** and is exposed to the webview as Tauri commands, exactly like the existing `browser_*`, `terminal_*`, and `browser_screenshot` bridges. Nothing here goes through `BusterClaw.Commands` — voice is local device I/O (microphone, speaker), not an agent-callable capability, so it does not belong on the policy/tier/audit command surface.

> **Status (2026-06-21):** Phase 1 (TTS output) shipped — Buster Claw speaks its replies.
> - Phase 0 (TTS slice) — capability + permissions + non-desktop fallback — ✅
> - Phase 1 — TTS output (speak/stop, bridge, server push, barge-in, toggle) — ✅
> - Phase 0 (STT slice) — mic entitlement, cpal/whisper deps, model bundle — ⏳ (with Phase 2)
> - Phase 2 — STT input — ⏳
> - Phase 3 — polish — ⏳
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
- [ ] Add `NSMicrophoneUsageDescription` (e.g. "Buster Claw uses the microphone for voice input in chat.") to the macOS Info.plist. In Tauri v2, add/merge a `desktop/tauri/Info.plist`.
- [ ] Add the `com.apple.security.device.audio-input` entitlement (hardened runtime needs it for notarized builds). Fold into the existing Apple-signing entitlements file / `tauri.conf.json` `bundle.macOS`.
- [ ] Note in `daily-growth/roadmaps` cross-ref: this rides the distribution roadmap's Apple-signing critical path.

### 0B. Rust dependencies
- [ ] Add `cpal` (CoreAudio microphone capture) to `desktop/tauri/Cargo.toml`.
- [ ] Add `whisper-rs` (statically compiles whisper.cpp — no separate binary to ship/sign; Metal/Accelerate backend on macOS) to `Cargo.toml`.
- [ ] Confirm a clean `cargo build` and that whisper-rs links against the macOS backend. **Fallback if linking/notarization fights us:** ship a prebuilt `whisper-cli` binary in resources and shell out instead.

### 0C. Bundle the model
- [ ] Add `ggml-base.en.bin` (~142MB; good speed/accuracy for v1) to `desktop/tauri/resources/release/`.
- [ ] Resolve the model path at runtime the same way `main.rs` resolves the bundled release binary (resource dir lookup).
- [ ] Document the model + bundle-size delta (~150MB) in `docs/DESKTOP_PACKAGING.md` and `BUILD.md`.

### 0D. Tauri command capabilities
- [x] Register `speak`, `stop_speaking` in `desktop/tauri/capabilities/default.json` + invoke_handler. *(`start_recording`/`stop_recording` deferred to Phase 2.)*
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
- [x] Emit `bc:stop_speak` on: `cut_run` / Esc, and a new user `chat_send`. Toggle-off fires the local `bc:voice-stop` event. (Recording-start hook lands in Phase 2.)
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
- [ ] `start_recording()` — open a `cpal` input stream into a shared PCM buffer (16 kHz mono f32, whisper's expected format). One in-flight recording at a time (Mutex-guarded; reject re-entry).
- [ ] `stop_recording()` — stop the stream, run `whisper-rs` on the captured buffer with the bundled model, return `{ text }`.
- [ ] Resample/convert if the device's native sample rate ≠ 16 kHz mono.
- [ ] Handle the empty/too-short capture case → return empty text (not an error).

### 2B. Composer UI (`lib/buster_claw_web/components/chat_panel.ex`)
- [ ] Add a 🎤 mic button to the chat `<form>`, between the textarea and Send.
- [ ] Recording state visuals: a pulse on the button while capturing, a spinner while transcribing (reuse the thinking-chip visual language).
- [ ] Hide the mic button when `__TAURI__` is absent (plain browser).

### 2C. `AgentChat` hook — wire push-to-talk (`assets/js/app.js`, extend the existing hook)
- [ ] On mic `pointerdown` (and hotkey, e.g. `⌘/`): first `stop_speaking()` (don't transcribe our own TTS), then `invoke("start_recording")`, set "listening" state.
- [ ] On `pointerup` / hotkey-release: `invoke("stop_recording")` → insert the returned text into `[data-chat-input]`.
- [ ] **v1:** fill the textarea and let the user review + Enter (do **not** auto-send).
- [ ] Clean up listeners in `destroyed()` (the hook already follows this pattern).

### 2D. Robustness
- [ ] Mic-permission-denied path → inline `:error` chat message ("Microphone access denied — enable it in System Settings").
- [ ] Recognizer/model-load failure → graceful inline error, button returns to idle.
- [ ] Guard against starting a recording while one is already in flight.

### Exit criteria
- [ ] Hold the mic (or hotkey), speak, release → transcript appears in the composer; user reviews and sends; errors degrade gracefully; speech is paused while recording.

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
