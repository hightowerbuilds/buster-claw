# Sound in Buster Claw — Roadmap V.2

**Date:** 2026-07-28 · **Status:** SCOPED (operator decisions locked), not started ·
**Scope:** sound effects for app events — the second half of the "music and sound
effects" ask that `MUSIC_ROADMAP.md` deliberately scoped out. Music is built;
this is everything else that rings.

**Operator decisions, locked 07-28:**
- **All four event groups are in scope** — A agent-attention, B comms arrivals,
  C security-critical, D playful/identity.
- **Bundled defaults, ON.** Sound works out of the box; the operator can
  replace, re-route, or silence anything.

---

## Part I — What exists, and the two facts that shape everything

**Today's only sound path:** a notification fires → the `NotifySound` hook plays
a chime routed by `Notifications.Sound` (`sources chat/terminal/email/voicemail/
manual`, kinds `timer/alarm/reminder`, first match wins, resolved by
`/notify/sound/:name`). Settings → Notify already has the routing UI. TTS
(`say`) is a separate speech channel and stays one.

**Fact 1 — no new event plumbing is needed.** Twenty modules already broadcast
on PubSub; every moment worth a sound is already announced. Sound is a
*subscriber*, and the sticky dock — where the music player now lives — is the
proven app-wide home for one.

**Fact 2 — the licensing question dissolves.** Every bundled default can be
**synthesized by a checked-in script**: DTMF is two sine waves by definition,
and short chimes/alarms are envelope-shaped tones. Generated WAVs are ours,
CC0-by-construction, reproducible, and tiny. We never source third-party audio,
so the GTM licensing check the "bundle defaults" decision implied simply never
opens. (Rejected alternative: sourcing CC0 packs — provenance audit, taste
lottery, and a bigger repo for a worse fit with the Industrial Claw identity. A
synthesized set *sounds* like this app looks.)

---

## Part II — The sound map (what rings, on which event)

New routing keys widen the existing `@route_keys` — one system, not a second
one. Workspace files override bundled defaults per key (Part III).

### Group A — Agent attention (silence here costs time)

| Key | Moment | Event that already exists |
|---|---|---|
| `confirm` | **Confirmation needed** — a gated action queued for human approval | `Sentinel.Pending` `{:pending_action, ...}` — the highest-value sound in the app; a queued refusal nobody hears is a stalled agent |
| `chat` *(existing key)* | Chat answer ready | `Agent.Chat` `{:status, :idle}` after `:running` |
| `order` | Trading order card pinned above the composer | **No broadcast today** — `TradingLive` assigns the card locally; it pushes the sound event itself when it pins (the one place sound is not a PubSub subscriber) |
| `shift` | Shift stopped: budget cap, STOP file, crash brake | `{:orchestration, ...}` |
| `blocked` | Dispatch item blocked — the agent is stuck and said so | `{:dispatch, ...}` |
| `web` | Agent-mode browser run finished, or **halted at the payment gate** | `{:agent_mode, ...}` |

### Group B — Comms arrivals (the answering-machine identity)

| Key | Moment | Event |
|---|---|---|
| `voicemail` *(existing key)* | Voicemail landed | `Telephony` broadcast on drain persist |
| `sms` | SMS from a trusted number | `Telephony` broadcast |
| `email` *(existing key)* | Trusted-sender mail → Dispatch item queued | `{:dispatch, ...}` queued |

### Group C — Security (one severity, alarm-grade)

| Key | Moment | Event |
|---|---|---|
| `security` | Sentinel `:critical` **only** (`security_block`) | `{:security_event, ...}` on `"security_alerts"` |

`:warning`/`outbound_send` deliberately never rings — it fires on routine sends,
and an alarm that is always ringing is not an alarm (the DataState lesson,
applied to audio). The rubric is pinned by test: severity `< :critical` → no
sound, ever.

### Group D — Playful / identity

| Key | Moment | Mechanism |
|---|---|---|
| — | DTMF tones on the dialpad | **Client-side WebAudio oscillators in the keypad hook** — real DTMF frequency pairs, zero files, zero latency, no server round-trip. The dialpad is decorative; now it is decorative *and correct* |
| `boot` | App ready (first LiveView connect of a session) | once per BEAM boot, not per page load |

### Never (decided, so it stays decided)

UI clicks, tab switches, per-command sounds, terminal bell passthrough,
upload-complete, music-error (has its visual note). Annoyance compounds hourly
in a daily driver. Cheap to add later if genuinely craved; miserable to live
with meanwhile.

---

## Part III — Design rules

1. **Two-layer resolution, workspace wins.** Bundled defaults live in
   `priv/static` (shipped, read-only); a matching file in `<workspace>/sounds/`
   overrides per key. **No seeding into the workspace** — a boot-time copy
   would resurrect files the operator deleted, which is how "delete that sound"
   becomes a bug report. Deleting a workspace override falls back to the
   bundled default; silencing a key is a routing choice in Settings, not a file
   deletion.
2. **Per-key cooldown.** One sound per key per N seconds (~5s), so a burst of
   dispatch events is one chime, not a slot machine. `security` and `confirm`
   get the shortest cooldowns; nothing bypasses cooldown entirely.
3. **Master switch + per-key routing** in Settings → Notify — extending the UI
   that already exists, including "silent" as a routing target per key.
4. **Audible over music, no ducking.** SFX are short and spectrally distinct
   from music; V.1 ships zero ducking machinery. If real-world use proves the
   need, ducking becomes a V.3 line with evidence behind it.
5. **The sound player is app-wide and sticky**, next to `MusicPlayerLive` in
   the dock — same reasoning, same pattern, third tenant. A sound must ring on
   whatever page you're on, including none of the home tabs.
6. **TTS stays separate.** Speech is content; SFX are signals. No key routes to
   `say`.

---

## Part IV — The phases

### Phase 0 — The bundled set, generated

A checked-in generator (`scripts/gen_sounds.exs`: pure-Elixir PCM→WAV, no
deps) producing the default set into `priv/static/sounds/` — distinct short
chimes for `confirm`/`chat`/`order`/`shift`/`blocked`/`web`/`voicemail`/`sms`/
`email`/`boot`, one alarm-grade `security`. Two-layer resolution lands in
`Notifications.Sound` (workspace override → bundled fallback), plus the master
switch setting.
*Acceptance:* deleting a workspace override falls back to bundled; the
generator is deterministic (same script → byte-identical WAVs); every new key
resolves; master switch off → total silence including notifications.

### Phase 1 — The SoundBoard

`SoundBoardLive`, sticky in the dock: subscribes to the Part II topics, maps
event → key → URL, pushes to a hook holding a small pooled `Audio` set.
Per-key cooldown server-side (testable), Sentinel severity filter pinned by
test. The `order` key wired directly from `TradingLive`.
*Acceptance:* a burst of N dispatch events in cooldown → exactly one play; a
`:warning` security event → provably no sound; rings while music plays; rings
from `/browse`.

### Phase 2 — Routing UI

Settings → Notify grows the new keys with the existing assign/preview
affordances, grouped A/B/C/D, each key routable to any library sound or
"silent".
*Acceptance:* every Part II key visible, auditioning works, "silent" sticks.

### Phase 3 — DTMF + boot

WebAudio oscillator pairs in the keypad hook (true frequencies, ~80ms,
envelope so no clicks); `boot` once per BEAM boot.
*Acceptance:* keypad audible with an empty sound library (no files involved);
boot chime does not re-fire on navigation or reconnect.

---

## Part V — Risks

1. **Sound fatigue is the product risk.** Mitigations are structural: cooldowns,
   the Never list, per-key silence, one master switch. If any default proves
   annoying in practice, the fix is re-routing, not code.
2. **Autoplay policy.** A webview may refuse audio before a user gesture —
   the music hook already handles this pattern (report, don't lie); the
   SoundBoard inherits it. Sounds before first interaction may be dropped;
   acceptable, and the packaged-app walk should confirm the Tauri webview's
   actual policy.
3. **Synthesized taste.** Generated chimes can sound cheap. The generator gets
   envelope + harmonic control, and the operator audition in Settings is the
   review gate — plus everything is replaceable per key by dropping a file.
