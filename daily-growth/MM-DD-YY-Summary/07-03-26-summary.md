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

## Next

Phase 1 remainder: popups→new tabs (WKUIDelegate), downloads
(WKDownloadDelegate + Sentinel event), keyboard shortcuts (native menu
accelerators — ⌘1-9 across the unified bar). Then Phase 2.1 durable tab state
for app-restart session restore.
