# 07-04-2026 Summary

Two workstreams closed today: **Humo collapsed into the homepage** (smoke as
ambient background, SVGs as real SVGs), and the **embedded-browser roadmap was
driven to completion and retired** to `roadmaps/oldmaps/`.

## Morning — Humo → homepage collapse, and configurable backgrounds

**The Humo saga ended honestly.** The separate `/humo` tab tried to make the
smoke shader *the* reading surface (text condensing out of fog). Wrong altitude:
the smoke is gorgeous *atmosphere* but a poor *content engine*, and "drawing into
the shader" was never honest (the SDF attempt crashed WKWebView; rasterizing an
SVG into fog just hides a real SVG). So it collapsed into the main homepage chat
with honest roles: **smoke = background, chat = chat, SVG = SVG**. The `/humo`
route is deleted.

- **Smoke background.** The WebGPU smoke renderer moved to `assets/js/smoke/`
  (`createSmoke`), driven by a `SmokeBackground` hook as pure ambient backdrop
  behind the translucent homepage chat — no content/reveal/lens, subtler post
  (faint grain/scanlines, edge vignette), a gentle churn while the agent runs.
- **SVG Viewer sidebar** (renamed from "Sketchpad" — module/hook/id/event/CSS all
  swept). `BusterClaw.SvgViewer.extract/1` pulls ` ```svg ` blocks from replies;
  `sanitize/1` strips script/on*/foreignObject/external-href (a real trust
  boundary — rendered live via `raw/1`). Persists **per-conversation** by
  re-extracting from the transcript on load, so the bank accumulates every
  drawing; a full-screen modal pages with ←/→ and an n/total counter.
- **Configurable homepage background** (Settings → Appearance): pick a shader
  design (**smoke / waves / lava / zigzag**) or upload an image, with a
  **custom 3-color palette** toggle (base/accent/highlight) and a live
  `ShaderPreview` square. Each shader sources its palette from `colA/B/C`
  uniforms (`grad3` in the prelude). **Zigzag** = a Joy Division "Unknown
  Pleasures" waterfall (stacked ridgelines in perspective, hidden-line removal
  via a per-pixel silhouette march), rendered at 0.6× / capped for integrated
  GPUs; it replaced the retired Aurora shader.

## Afternoon/evening — the embedded-browser roadmap, closed

Picked up Phase 4 + the trust leftovers and drove every remaining item to a
resolved state. Five features shipped; the rest resolved with reasons.

**Co-presence indicator (Phase 3.1 leftover).** Every co-presence command
(`browser_current`/`_read`/`_find_elements`/`_click`/`_fill`/`_navigate`/
`_open_tab`) pings the chrome's `window.__agentActivity` (Rust
`ping_agent_activity` → eval), flashing a hazard-orange "Agent · reading /
clicking / typing…" pill that pulses and auto-fades ~1.7 s after the last action.
Reuses the existing `__agentOpenTab` eval channel — no Tauri event plugin. Trust
is the product: the agent could already act on the live session; now the user
always sees when.

**Background-tab suspension (Phase 4).** Each content tab is its own WKWebView
process, so N tabs = N web processes. A per-surface MRU in `BrowserState` now
keeps only the 6 most-recently-used content webviews live; the rest are evicted
(LRU) on every activation. The chip and its saved URL survive, so a switch-back
recreates and reloads it — `browser_switch_tab` now carries the URL for exactly
that resurrection. Active and ephemeral tabs are never suspended (an ephemeral
tab's non-persistent store can't survive an evict→reload); suspended chips
dim/italicize (`__onTabSuspended`), cleared the moment they reload.

**Content blocking via `WKContentRuleList` (Phase 4 flagship).** WebKit ships
Safari's content-blocker engine — uniquely ours *because* we chose WKWebView. A
curated EasyList subset (`desktop/tauri/src/blocklist.json`, 75 top ad/tracker/
analytics hosts, third-party load-type so visiting one directly is never blocked)
is compiled by `WKContentRuleListStore` and added to every content webview's
userContentController via the objc bridge (`apply_content_blocking`; the
controller is retained across the async compile so a tab closed mid-compile can't
UAF). `BrowserState` holds the ON-by-default flag; `browser_set_content_blocking`
flips it and re-applies to live tabs; a 🛡 shield button in the chrome persists
the preference in localStorage. Network block only — cosmetic filtering
deliberately skipped for v1. Bump `BLOCKLIST_ID`'s version when the list changes.

**TLS padlock + private tabs for humans (Phase 4).** A padlock left of the
address bar — muted 🔒 for HTTPS, hazard ⚠ for plaintext HTTP, hidden for
workspace/blank pages, synced from the active tab. A 🕳 button in the tab strip
opens an ephemeral private tab reusing the same non-persistent WKWebsiteDataStore
as the agent's sandbox tabs (nothing shared, nothing on disk, excluded from
restore); dashed hazard outline echoing the `.eph` chips.

**Resolved without building (honest, not skipped).** Nav-events *push* (3.5)
deferred — the read/poll half already ships (`browser_tabs` + `history_recent`),
and the reactive push needs a persistent consumer that doesn't exist, so building
the pipe now is dead plumbing. Reader mode stays a standing non-goal. The
native-offset bug stays parked. The **WKUIDelegate ceiling was researched from
wry-0.55.1 source and accepted by operator decision**: wry owns the single
uiDelegate slot, *auto-grants camera/mic to any page*, and drives `<input
type=file>` upload panels; replacing it to fix OAuth popups or add a permission
prompt risks silently breaking file uploads and still can't make a popup a
tracked tab. The `bcpopup://` shim (popups→tabs) stands as the shipped answer;
live-opener OAuth is the accepted rare caveat. All findings recorded in the
roadmap's Phase 1.2 note before it was retired.

**Roadmap retired.** `BROWSER_ROADMAP.md` marked CLOSED and moved to
`daily-growth/roadmaps/oldmaps/` alongside `Shortlist.md`.

**Verification at close:** `cargo check` clean, `node --check` clean,
`mix compile` + `mix assets.build` clean. The objc/WKWebView + chrome-webview
paths (content blocking, co-presence, suspension, TLS, private tabs) only verify
live — in-app pass pending: 🛡 lit → ad-heavy site → ads gone → toggle off +
reload → ads back; open/close ~8 tabs → old ones reload on click; 🕳 opens a
dashed private tab.

## Late — two more homepage shaders (Mandelbrot, Weather), Lava retired

The Appearance shader roster settled at five (smoke / waves / zigzag / mandel /
weather): Mandelbrot and Weather were added, and **Lava was retired** — file
deleted and stripped from the shaders/palettes registries, `@home_shaders`, and
the picker label map. A previously-saved `"lava"` mode falls back to the default
smoke via `home_background_state`'s stale-mode guard, so nothing breaks.

- **Mandelbrot.** A homepage background that slowly zooms/pans the Mandelbrot
  set, coloured through the `colA/B/C` palette. Per-pixel iteration loop, so it
  renders at 0.6× / capped 820px like Zigzag to stay cheap behind the blur.
- **Weather.** An evolving ~2-minute sky clock that blends overlapping
  conditions rather than switching them: **sunny → windy → rain + lightning →
  snow**, looping back to sunny. Domain-warped fbm clouds, three depth-layered
  rain/snow passes, a forked lightning bolt with a localized sky flash, and
  wind-driven slant/gusts — precip blocks are gated behind time-only `if`s so
  clear stretches stay cheap. The **sunny** spell is a palette-tinted sun (crisp
  disk + soft halo + slowly-turning god-rays) high in the sky, warmed into the
  whole gradient and occluded by drifting cloud cover. Weather needs its detail
  crisp, so it renders closer to retina (`dpr·0.85`, capped 1400px) — a higher
  budget than the Zigzag/Mandelbrot tier. Registered across `shaders.js`,
  `palettes.js`, the `@home_shaders` list, and the Appearance picker label map.

## Next

Browser roadmap is done. Open workstreams remaining: Browserbase (agentic cloud
web — Phase 3 live-view tab, then Phase 4 money-gating) and distribution
(Google restricted-scope verification + Apple signing).
