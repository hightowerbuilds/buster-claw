# 07-11-2026 Summary

A day with two faces. The morning's research found a fire (the app is
Intel-only and Apple is switching Intel apps off on a schedule with a date on
it), and the rest of the day shipped an entire new organ: **BusterPhone went
from a roadmap document to a deployed cloud relay and a living, shader-driven
Phone tab** — rotary dial, GPU waveforms, procedural contact faces and all.

## Distribution research → `roadmaps/DISTRIBUTION_ROADMAP.md`

The storefront research doc (written today, verified against the shipped
`Buster Claw_0.1.0_x64.dmg` and the repo at HEAD) started life as
`docs/DISTRIBUTION.md`; it was promoted into `daily-growth/roadmaps/` and
renamed to match the `*_ROADMAP.md` convention, since it's the live map for
this workstream. Its verdicts:

- **The Mac App Store is impossible, permanently** — not paperwork, physics.
  The defining feature is spawning the user's own `claude` binary from their
  `$PATH`, and the MAS sandbox has no entitlement that permits it. Ever.
- **Developer ID + notarization is the door standing open right next to it** —
  same $99, no sandbox, no review board, no revenue cut, automated approval in
  under an hour. The existing roadmap had already picked this path; the
  research confirms it and scopes it at roughly a week of real work.
- **iPhone is real but it isn't BusterClaw** — iOS forbids subprocesses at the
  kernel level, so what ships is a thin client talking to BusterClaw on your
  Mac. The load-bearing work is the Mac-side daemon + remote protocol, which
  is platform-agnostic and worth having regardless; the phone client becomes a
  small project after that.
- **There is no updater**, and the naïve way to add one (overwrite in place)
  corrupts the running Erlang VM. Parked, but on the map.

## The fire nobody set off the alarm for

**BusterClaw is Intel-only, and Rosetta 2 is being switched off.** Verified,
not speculated — every native binary in the shipped bundle was inspected:

- All **25 Mach-Os are x86_64** — the Tauri shell, the full ERTS
  (`beam.smp`, `erlexec`, `epmd`, …), and every NIF including `crypto.so`
  (OpenSSL-linked) and exqlite's `sqlite3_nif.so`.
- `scripts/build_desktop.sh` has **no `--target` anywhere**; it builds
  whatever the host is, and the host is the Intel i9.
- `.github/workflows/ci.yml` is **ubuntu-only and never builds the desktop
  app** — there is no macOS build automation to extend; anything here is
  greenfield.

The clock: macOS 26.4 (shipped) already warns users launching Intel apps;
macOS 27 (this fall) is the **last release with Rosetta** and its installer
actively removes it; macOS 28 (fall 2027) — Intel apps simply fail to open.
Essentially every Mac sold in the last five years is Apple Silicon, so the app
is already degraded for nearly all prospective users today and has roughly a
one-year fuse before it stops launching for them entirely.

Why it's not a build flag: Tauri's `universal-apple-darwin` target only makes
the *Rust shell* universal — the bundled BEAM is a resource Tauri never
touches. And **do not lipo a universal ERTS**: Apple's executable-memory
restrictions break the Erlang JIT in the x86_64 slice ("Cannot allocate
executable memory"), and the OpenSSL/NIF cross-arch merging is where even
ElixirKit's author got stuck. The sane pattern is Livebook's, verbatim: **two
single-arch DMGs, each built natively on its own architecture.** arm64 is a
prerequisite for shipping, not a follow-up — everything notarized before it
exists has the fuse on it.

**Operator decision: buy an Apple Silicon Mac sooner than later and build
natively on it.** The i9 flips to being the Intel build box for as long as
that market matters — and it's on its own clock anyway (macOS 26 is the last
release for Intel Macs, so the current build machine can't follow macOS
forward either). GitHub Actions' free arm64/Intel macOS runners stay on the
map as the fallback / eventual CI answer. All of this is recorded at the
forefront of the agent memory index so it frames every distribution decision
from here.

## BusterPhone: roadmap → deployed relay → living tab, in one day

The roadmap (`roadmaps/BUSTERPHONE_ROADMAP.md`, written this morning from the
07-06 telephony research) had its decision table **locked** — Twilio, Supabase
relay, built-in transcription, trusted-numbers list — and then most of Phases
0–1's cloud half plus Phase 3's UI shipped the same day.

**The relay is deployed.** `supabase/` in the repo holds the whole public
front door, versioned per the roadmap rule: the `voice` Edge Function
(X-Twilio-Signature verification fail-closed, greeting + `<Record>` TwiML,
recording → private Storage bucket + `telephony_events` row upsert,
transcription callback with retry), the SQL migration (deny-all RLS, Realtime
publication), and `SETUP.md`, the operator console checklist. Live at the
project's `/functions/v1/voice`; unsigned requests get 403. Honest caveats:
the operator chose to host it in the existing **shared multi-app Supabase
project** despite the service-role-key blast-radius warning (recorded; a
dedicated project is a 10-minute move later), and the migration went in via
the Management API + `migration repair` because that project's migration
history belongs to another repo. Twilio is a **trial account** with toll-free
**+1 844-687-8016**; the phone-numbers API is policy-blocked on trial, so the
voice webhook still needs 30 seconds of console clicking — deliberately parked
until the account upgrade (a few days out; 10DLC needs the paid tier anyway).

**The Phone tab** (`/phone`, dock entry) is the Message Machine, built as a
three-panel shader window on the local mirror (`telephony_events` +
`telephony_contacts` migrations, `BusterClaw.Telephony` context, Sentinel
`:untrusted_ingest` on inbound, PubSub live updates, `say`-synthesized demo
seeds):

- **Left — the clip rack.** Recordings render as Pro Tools-style regions with
  their **real decoded waveforms**: fetch → `decodeAudioData` → 256 peaks →
  a dedicated WGSL pipeline (`assets/js/audio/clipwave.js`) with hot core,
  edge glow, ruler ticks, shimmer, and homepage-matching scanlines. Unheard
  clips burn hazard orange. WKWebView scar tissue honored: peaks travel as a
  256×1 texture (no storage buffers), and all clips share **one** GPUDevice.
- **Top right — the rotary dial.** A fine-grain SVG replica with real Western
  Electric geometry (stop at 65°, travel = 30°+30°·n, exchange letters,
  subscriber card wearing the 844 number). The `RotaryDial` hook does
  drag-wind + governed return with WebAudio pulse ticks that land exactly on
  the digit's pulse count; the finger holes are mask cutouts so the panel's
  orange wave shader blazes through the spinning wheel.
- **Bottom right — contacts with shaderfaces.** A scrollable contact list
  (E.164-normalized, `trusted` flag = the future Phase-2 SMS gate); selecting
  one shows a **procedural face** — the new `face` built-in shader grows a
  head out of fbm smoke with blinking eyes and a seeded expression,
  deterministic per number (seed contract: `u.lens.x`). Contact names replace
  raw numbers across the whole tab. The **custom face maker** turned out to
  already exist: it's the file-first `workspace/shaders/` pipeline — ask
  Buster (shader-designer skill) for `face-<name>.wgsl` and it appears in the
  contact's face picker.

History rhymed: a backtick inside a WGSL template-literal comment broke the
esbuild bundle **again** (same failure as the 07-05 weather shader). Grep for
backticks in `*.wgsl.js` before building.

## Also committed today

The **zigzag built-in shader is removed** — `zigzag.wgsl.js` deleted,
de-registered from `shaders.js`/`palettes.js`/the SmokeBackground density
table, and the built-ins lists in `Skills` (shader-designer prompt),
`Introduction`, `Shaders`, and `AppearanceLive` now read smoke / waves /
mandel / weather (plus the new `face`). The name `zigzag` is freed up for a
workspace shader.

## What's next

- **BusterPhone:** upgrade the Twilio account → wire the voice webhook
  (console, 30 seconds) → call the number for the Phase 0/1 exit test; then
  build the Mac-side Realtime drain (`Slipstream` — Supabase Realtime speaks
  Phoenix Channels; no ws client dep in mix.exs yet) so voicemails land in the
  clip rack live. Start 10DLC registration day one of the SMS phase.
- The new machine. Until it (or a runner) exists, treat anything shipped as
  trusted-testers-only with a one-year fuse.
- The operator console checklist from 07-05 still gates seamless connect
  (GCP consent screen + Desktop client, Apple enrollment, buster.mom +
  privacy policy).
- When the arm64 build happens: CI-proof `build_desktop.sh` (non-interactive,
  arch-stamped DMG names) and the sign/notarize step — entitlements on every
  one of the 25 Mach-Os, including `beam.smp`, *before* Tauri bundles.
