# 07-03-2026 Summary

Turned the lens on the **embedded browser**: a critical review against the field,
a code-quality audit of the browser stack, and a five-phase build-out roadmap.
Docs live in `daily-growth/roadmaps/` (`BROWSER_REVIEW.md`, `BROWSER_ROADMAP.md`);
`Shortlist.md` retired to `roadmaps/oldmaps/`.

## Browser review (new doc)

Full read of the stack — `browser.rs` (webview orchestration), the chrome page,
home page, `BrowseLive`, history/bookmarks contexts, co-presence commands —
scored against Safari/Firefox/Arc and the AI cohort (Dia, Comet, Atlas). Verdict:
**ahead of everyone as an agent co-presence surface, but a user hits something
broken within five minutes of using it as a browser.** Tier-1 breakage: the
omnibox can't search (schemeless input becomes an invalid `https://` URL),
`window.open` is stubbed to same-tab so OAuth popups break, downloads silently
no-op, and there are zero keyboard shortcuts (architectural — focus lives in the
content webview). Structural ceilings named honestly: WKWebView means no
extensions ever; one shared cookie jar across all tabs *and* split panes; a live
WKWebView per tab forever. One own-goal: favicons via `google.com/s2` leak every
visited host to Google — from the local-first, Sentinel-audited app. Strategic
frame for everything after: **never be the reason the user alt-tabs to Chrome**,
because every alt-tab removes the agent's eyes from the page.

## Code QX review (appended to the review)

Grep-verified every public function for production callers. Findings:
`BusterClaw.Browser.Reader` (117 lines + test) is fully orphaned pre-rewrite
reader-mode code — delete. ~60% of `BrowserHistory`'s API (`search`,
`grouped_by_day`, `visit_count(s)`, `clear`, `clear_range`, `list`) has test-only
callers: a shipped backend whose UI/agent commands were never built. Rust side
clean (all 15 commands registered + invoked). Modularity: macro-architecture is
crisp (Rust owns webviews, chrome JS owns the strip, Elixir owns durable state),
but the chrome is a ~330-line JS app inside an Elixir string literal, tab state
has three partial owners and none durable (why session restore is impossible),
cross-boundary logic is triplicated with only "mirrors X" comments guarding
drift, and history records on the wrong seam (chrome JS, active-tab-only). Test
coverage clusters where testing is easy (Elixir), not where the risk is — the
Rust/JS layers holding all four Tier-1 bugs have zero tests.

## Build-out roadmap (new doc)

Five phases with exit criteria and S/M/L effort tags. **Phase 0** foundations:
extract the chrome JS to real testable assets, delete Reader, de-dupe the
triplicated logic, move history recording to Rust's `on_page_load`. **Phase 1**
stop the bleeding: omnibox search, popups→tabs (WKUIDelegate for real OAuth
support), WKDownloadDelegate downloads with Sentinel audit events, native-menu
shortcuts, local favicon cache replacing the Google leak. **Phase 2** table
stakes: durable tab state + session restore (also the QX three-owners fix),
omnibox suggestions + history page (wires the dead backend), find-in-page, zoom.
**Phase 3** extend the moat: `browser_read` (authed rendered DOM), audited
click/fill verbs, agent sandbox tabs on ephemeral data stores. **Phase 4**
stretch: content blocking via `WKContentRuleList` (Safari's blocker engine, free
*because* we chose WKWebView), private mode, tab suspension. Non-goals stated:
extensions, sync, cross-platform parity, engine swap.

## Shipped the same day (Phases 0 → 1.5 + field fixes)

**Phase 0 — foundations (all four items).** The ~330-line chrome JS moved out
of the Elixir string literal into `assets/js/chrome.js` (own esbuild entry);
shared URL heuristics in `assets/js/lib/browser_url.js` imported by chrome and
hook, with bun tests; dead `Browser.Reader` deleted; `sanitize_sid` parity
pinned by one fixture set in Rust unit tests + the Phoenix controller test;
history recording moved to Rust's `on_page_load` (every tab records, real
titles, chrome is pure presentation).

**Persistence fixed (Phase 0.5 #1).** Root cause of browser tabs dying on
every app-tab switch: the app shell renders inside each LiveView, so TabStrip
remounts on live navigation and `reconcileBrowserSurfaces()` was *closing* all
surfaces off-/browse — destroying what `destroyed()` had just hidden.
Reconcile now hides instead of closes; tabs survive navigation. Confirmed
working in the field.

**Phase 1.1 — omnibox search.** Schemeless non-host input (spaces, or dotless
non-localhost) routes to DuckDuckGo (`browser_search_url` setting overrides),
instead of erroring as `https://<query>`.

**Phase 1.5 — favicon privacy.** New `BusterClaw.Favicons`: URLGuard-vetted
direct fetch of `/favicon.ico`, disk-caches hits *and* misses 7 days, served
by `GET /browser/favicon?host=`. Chrome, bookmark bar, and homepage all moved
off `google.com/s2`; bookmark entries stop persisting `favicon_url` and
renderers always derive, so old stored Google URLs stop leaking too.

**App-tab switcher in the chrome (Phase 0.5 #2 mitigation).** The native
webviews cover the DOM tab strip, so the chrome now carries its own: a Home
chip + every open app tab (from the shared `bc:tabs` localStorage), navigating
the main webview via the new `browser_app_navigate` Tauri command (absolute
app paths only, ACL'd to the browser-chrome capability). App chips get a
translucent hazard-orange fill — one bar, two temperatures. In-app
diagnostics proved the hook's JS geometry correct (strip `0,0,w,39`, surface
`y=39`, `offY=0` — WKWebView reports `outerHeight` 0) and wry/tao sources were
read to rule out the flip math; the residual native offset is parked as
Phase 2 polish with findings recorded in the roadmap.

**Verification at close:** mix test 710/710, bun test 17/17, cargo test 2/2.

## Afternoon/evening — Phases 1, 2, and 3 all shipped the same day

**Phase 1 completed.** Popups/target=_blank → real tabs via a bcpopup://
sentinel the nav guard intercepts (window.opener OAuth stays the known
ceiling); native Tabs menu with ⌘T/⌘W/⌘R/⌘L/⌘F/⌘±0/⌘⇧[]/⌘1-9 routed to the
shown surface's chrome or the app TabStrip (menu accelerators fire regardless
of webview focus — the whole point); downloads via tauri's on_download (wry
ships the WKDownloadDelegate — the budgeted objc bridge wasn't needed) with a
chrome shelf, reveal-by-id, and a Sentinel event per download.

**Phase 2 completed.** Durable tab state + session restore (settings blob per
surface; deep links own tab 1); omnibox suggestions as bookmark-row chips
(the 112px chrome clips dropdowns) from bookmarks + FTS history; find-in-page
(window.find via browser_find); zoom; ⌘/middle-click links → tabs; drag
reorder + middle-click close. History moved INTO the browser by operator
call: /browser/history is a content-webview-native page linked from the
homepage; the dock entry and LiveView were cut. history_search/history_recent
joined the safe tier (snapshot reviewed).

**Phase 3 core completed — the co-presence moat.** browser_read returns the
active tab's RENDERED DOM (objc evaluateJavaScript-with-result — page CSP
can't block it), Sentinel-audited, restricted tier. Two parallel worktree
agents then shipped browser_capture_page (read + screenshot → tagged Library
artifact) and the interaction verbs browser_find_elements/click/fill
(per-page window.__bcEls index registry; click/fill record :outbound_send
with provenance, value LENGTH only). Finale: agent sandbox tabs —
browser_open_tab is EPHEMERAL BY DEFAULT (wry incognito →
WKWebsiteDataStore.nonPersistentDataStore; the "L" collapsed to a builder
flag); session: "user" opts back in; dashed-orange tabs, excluded from
restore. browser_tabs reads the strip from durable state.

**Also:** app-tab switcher in the chrome (unified bar, orange chips) after
diagnosing the covered DOM strip with an in-app measurement loop; operator
shipped sidecar seatbelt hardening + sandboxed launch in parallel.

**Close:** mix 747/747, cargo 3/3, bun 17/17. The review's Tier 1+2 scorecard
rows all flipped in one day; Phases 0–3 of the roadmap shipped.

## Next

Phase 4 stretch (WKContentRuleList content blocking, human private mode, tab
suspension) + two small leftovers: the "agent is reading" chrome indicator
and opt-in navigation events. The window.opener OAuth ceiling and the
residual native-offset bug stay documented in the roadmap.

## Evening — Humo: the shader-driven chat surface (new workstream, 0→lens in one sitting)

**Humo** ("smoke"): a new tab where a second, independent headless Claude's
replies are *written in a WebGPU smoke shader* — text condenses out of fog,
reads out page by page, dissolves to make room. Roadmap written
(`daily-growth/roadmaps/HUMO_ROADMAP.md`) with three operator decisions locked:
text-condenses-from-smoke (not a backdrop), illegibility-is-expressive (guarded
by an always-available DOM transcript), separate showcase surface.

**Phase 0.1 — the load-bearing spike, VERDICT: WebGPU (Path A).** Key fact
uncovered first: BusterClaw had no GPU shader surface (all "shaders" were CSS),
but Luke's own WGSL library exists in another runtime — `foreshadow` (Rust/wgpu
scenes) + `gemma-construct/shaders/smoke.wgsl`. The fork: WebGPU-in-WKWebView
(run WGSL near-verbatim) vs a GLSL/WebGL2 port. A throwaway spike page in the
real shell settled it: **adapter + device OK, `smoke.wgsl` ran near-verbatim**,
50 fps, text-texture upload 4.4 ms enqueue, 0 context losses. One shader
language across foreshadow and Humo; spike archived to
`daily-growth/archive/humo-spike-0.1.html`.

**Phase 0.2 — renderer library.** `assets/js/humo/`: `smoke_wgsl.js` (WGSL
source of truth), `renderer.js` (bare WebGPU, one fullscreen tri, fail-soft
`HumoGpuError` + `device.lost` → status line, never a dead canvas), `params.js`
(**`mapChatState` — the uniform-mapping layer v0**, the "teach the shader"
seam), `text_layout.js`; all pure math bun-tested.

**Phase 1 — its own Claude.** Discovery that collapsed the design:
`Agent.Chat` is *already* per-conversation (DynamicSupervisor + Registry), so
`BusterClaw.Humo` is a **40-line facade** pinning reserved conv_id `"humo"` —
queue, interrupt, thinking timer, persistence, Sentinel audit all inherited.
No `Conversations` row (no FK on `Message.conv_id`) keeps it out of the
homepage tabs. `HumoLive`: accessible DOM transcript + input + Stop +
ThinkingTimer; smoke live-wired to real turns (`humo:phase`/`humo:text`
push_events → `mapChatState`).

**Field-driven UX round (operator eyeballing):** transcript now **closed by
default** behind a "show text" disclosure (the smoke is the primary reading
surface); replies **read out** — words at ~90 ms cadence fill a page
(`layoutPage`), the page dissolves (`pageReveal` clock) to make room, final
page settles; letters shrunk 30→14 px and made *of* smoke — persistent curl
shimmer + fine-field flutter, triple-tap ghost smear, noise-modulated ink
density; field tuned smaller/wispier (higher frequencies, second swapped-reuse
curl warp).

**The still lens (unplanned finale).** Hover holds a circle of the fog
perfectly still — per-pixel clock blend toward a hover-start freeze timestamp
(cheap: all motion flows through one `drift`) — with rim-weighted chromatic
aberration on the letters and a warm/cool-fringed ring. A loupe that magnifies
nothing.

**Close:** mix 782/782, bun 37/37, esbuild clean. Humo phases 0.1, 0.2, 1.1–1.3
shipped + chunks of 2/3/4 (readout paging, text toggle, lens) in one day.
