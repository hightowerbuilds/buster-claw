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

## Front-end — modularized `assets/js/app.js`

A code-quality pass flagged `app.js` as the largest file in the app at **2,094
lines** (a single monolith holding every LiveView hook plus shared helpers). Split
it into focused ES modules; `app.js` is now **72 lines** and just wires up the
LiveSocket.

- **`lib/`** — shared helpers: `theme.js` (terminal color themes + the
  `liveTerminals` registry), `ansi.js` (the CSI/SGR transparent-background
  stripper), `tabs.js` (tab model + path/label helpers), `voice.js`
  (`voiceOutEnabled`), `globals.js` (documents sidebar + copy buttons).
- **`hooks/`** — one file per hook domain: `tab_strip.js` (547), `terminal.js`
  (TerminalView + TermThemePicker), `voice.js` (Bridge/Toggle/Devices/Mic),
  `chat.js` (AgentChat/ThinkingTimer/QueueRail), `browser.js`
  (ScreenshotBridge + EmbeddedBrowser), plus `corner_widget`, `split`,
  `calendar`, `crt`. `hooks/index.js` merges all 16 into one `Hooks` export.

Behavior-preserving — code was moved, not rewritten; shared state like
`liveTerminals` lives in one module and is imported where needed (ES modules are
singletons). esbuild bundles it back into one file at build time, so the split has
zero runtime cost. Verified: `mix esbuild buster_claw` builds clean (exit 0), all
16 hooks present (one per module, all wired into the index), and every
shared-helper reference is properly imported (no silent runtime `ReferenceError`).
Not yet smoke-tested live in the running app.

## Shortlist consolidation + parallel batch (5 PRs)

Consolidated the leftover items from the two retired roadmaps
(`06-20-26-browser-review`, `06-20-26-ecosystem-roadmap-refined`) into
`daily-growth/roadmaps/Shortlist.md` — only the *unshipped* work, since most of
both maps already landed (screenshots, bookmark tags/agent commands, favicons,
search, bookmark bar; ecosystem Phases 0–4). Archived both maps to `old-maps/`.

Then ran a parallel batch — 5 background worker agents, each in its own git
worktree, one PR apiece — to clear the actionable Shortlist items (1, 2, 4, 5, 6,
7). Item 3 (CRT calendar) was already done; item 8 (LRU eviction) deferred as "not
urgent"; item 9 (swarm smoke-test) stays a manual live-app test.

- **PR #1 — Tab UX (items 1 & 2):** Cmd-W never quits (falls back to a home tab,
  Cmd-Q untouched) + "Rename" added to the tab flyout menu, reusing the existing
  inline-rename path.
- **PR #2 — History → SQLite (item 6):** moved `BrowserHistory` to an Ecto/SQLite
  table with FTS5 search, visit counts, day-grouping, ranged clear; no 50-cap, no
  silent-drop. Added a deduped `recent/0` for display.
- **PR #3 — Chrome polish (item 5):** loading indicator (spinner + top progress
  bar), real page-title tabs via a new `on_page_load` WKWebView title read, tab
  favicons, + a 20s spinner safety timeout.
- **PR #4 — Bookmark folders + import/export (item 7):** `folder` field +
  grouped rendering, `export`/`export_html`/`import`, two new agent commands
  (`bookmark_export`/`bookmark_import`); backward-compatible with flat files.
- **PR #5 — Agent co-presence commands (item 4):** `browser_current` /
  `browser_navigate` / `browser_open_tab`, all `:restricted` + Sentinel-audited,
  copying the `browser_screenshot` bridge pattern (Elixir bridge + Tauri command +
  JS hook).

Verification bar was **compile + tests** (each passed `mix test` 660–673, 0
failures; `cargo check` where relevant) — interactive desktop click-through is
left as a manual checklist appended to `Shortlist.md`. Each worker ran the
`code-review` skill and fixed real findings (spinner-stuck, history dup-flood,
folder-clobber, dead-command wiring).

Two follow-ups flagged: (1) the `assets/js/hooks/` + `assets/js/lib/` split is
still uncommitted on `main`, so PRs #1/#5 (JS) need that committed/rebased before
merge; (2) `mix precommit` halts on a pre-existing repo-wide `credo --strict`
backlog (fails on `main` too) — worth a dedicated cleanup pass.

### Solid.js — considered and declined

Evaluated Solid.js for the modularization (raised as a "premiere option"). Declined:
this is a **Phoenix LiveView** app where the server owns and patches the DOM and
client JS is imperative hook glue, not declarative UI components. Solid would fight
LiveView for DOM ownership (`phx-update="ignore"` islands + manual lifecycle
bridging) and add a JSX/compile step + runtime dependency to solve a problem the
file doesn't have. Plain ES modules — already in the toolchain — delivered the full
modularization win with no new dependency.

## Home widget — calendar & contacts redesign

Reworked both tabs of the home corner widget (`HomeWidget` + `TrustedContactsPanel`,
`StatusLive`) toward a compact, non-scrolling, CRT-flavored look.

**Calendar tab** — replaced the single-day Pro Tools timeline with a **month grid**.
`StatusLive` now loads a Sunday-aligned 6-week grid (42 cells, `{date, in_month?,
events}`) via `events_in_range/2` instead of just today's events. The grid fills the
container (`grid-cols-7 grid-rows-6`), today is the solid-primary tile, and **days
with events tint the whole cell** with their category color (`bg-info/35` etc.) —
dropped the earlier dot. Cells are spread apart with `gap-1.5` (no continuous ruling)
and tightened to `rounded-xs`. A new **`CalendarPopover`** JS hook shows a floating
event popover above a hovered day, populated from a hidden per-cell detail block and
appended to `<body>` so it escapes the widget's overflow clip. Removed the
"This Month / Open" header per design feedback; dropped the dead timeline helpers.

**Scanlines** — added `ic-scanlines` to the whole widget card, so the CRT scanline
overlay sits over both tabs (pointer-events-none, interaction intact).

**Contacts tab** — redesigned minimalist + **no scroll**: a compact add row over
**wrapping sender chips** that fill the panel (each = value + `×` remove, green
border for an address, blue for a `*@domain` wildcard). Dropped the redundant
header/description/count. Same functions (`add_contact`/`remove_contact`, domain
distinction) preserved. Tradeoff noted: many contacts clip rather than scroll —
fine for typical counts, revisit if it bites.

Verified: `mix compile --warnings-as-errors`, `mix esbuild`, and `mix tailwind` all
clean. Not yet smoke-tested live (popover positioning, tint/scanline legibility,
chip density are the eyeball items). This commit also finally lands the
`assets/js/{hooks,lib}` split that was described but uncommitted — unblocking the
JS PRs (#1/#5) that depend on it.

## Full calendar page restyled to echo the widget

Brought `CalendarLive` (the `/calendar` page) into the same industrial/CRT language
as the home widget — a restyle pass, every behavior preserved (drag-to-move,
inspect, select-date, view switching, prev/today/next, add/edit/delete).

**Shared color module** — extracted `BusterClawWeb.CalendarColors` (`cell_fill`,
`cell_wash`, `chip`, `text`, `swatch`) as one source of truth for category hues, so
the widget and the full page can't drift. Both now route through it; the widget
fix-along-the-way is that "neutral" events render gray instead of orange. Class
strings are full literals so Tailwind's scanner picks them up.

**CalendarLive** — panels (grid, inspect, event form, result banner) → `ic-panel`;
header → `ic-scanlines` chrome + `ic-eyebrow` + `font-display` title + brutalist
view-switcher/nav with the primary accent on the active view + Today. Day cells
implement the two locked decisions: **scanlines on chrome + empty cells only** (the
day number and chips are pulled to `z-[2]` so they stay crisp above the stripes —
event text never sits under scanlines), and **faint cell-wash + chips on busy days**
(a day with events gets a faint `cell_wash` of its first event's color under the
chips). Today = primary wash + a solid-primary day-number badge. Event chips and
day-view rows use the shared `chip` tint (`rounded-xs`, `font-mono`). Removed the
old `@color_classes` / `color_class` / `swatch_class`.

Scanlines are `pointer-events:none`, so CalendarDrag and clicks pass through — no JS
change. Verified clean under `--warnings-as-errors` + esbuild + tailwind; not yet
smoke-tested live (empty-cell scanline legibility and wash visibility on the dark
theme are the eyeball items).
