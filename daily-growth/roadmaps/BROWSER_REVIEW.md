# Browser Review — Buster Claw vs. the field

*2026-07-03. A critical, honest assessment of the embedded browser as it ships today,
compared against mainstream browsers (Safari, Firefox, Chrome, Arc) and the new
AI-native cohort (Dia, Comet, ChatGPT Atlas). Written to anchor the build-out roadmap.*

## What we actually built

The browser is ~2,500 lines total: a Rust webview orchestrator
(`desktop/tauri/src/browser.rs`, 863 lines) that manages one 112px "chrome" webview
(tab strip + toolbar + bookmark bar, served by Phoenix as a single vanilla-JS HTML
page) and one WKWebView per tab, shown/hidden natively. Elixir owns bookmarks
(file-first JSON with folders/tags/import/export), SQLite history (search, visit
counts, day grouping), the SSRF-guarded fetch/download pipeline, and the Sentinel
audit trail. The agent gets six co-presence commands: `browser_current`,
`browser_navigate`, `browser_open_tab`, `browser_screenshot`, `browser_fetch`,
`browser_download`.

So: we did not build a browser engine, and we did not build a browser application in
the Firefox sense. We built a **thin, well-isolated multi-tab viewport with an agent
riding shotgun**. That's the right framing for everything below.

## The verdict up front

**As an agent co-presence surface, it's ahead of every browser named above. As a
browser, it would frustrate a user within the first five minutes.** The failure isn't
polish — it's that several behaviors every user has had since ~2004 are missing or
actively broken. The good news: the architecture is sound, the gaps are almost all in
the cheap-to-fix tier, and none require touching the engine.

## Scorecard

| Capability | Safari | Firefox | Arc | Dia/Comet/Atlas | **Buster Claw** |
|---|---|---|---|---|---|
| Engine | WebKit | Gecko | Chromium | Chromium | WKWebView (WebKit) |
| Search from address bar | ✅ | ✅ | ✅ (command bar) | ✅ (AI-routed) | ❌ **broken** — typed queries become `https://<query>` and fail |
| Omnibox suggestions (history/bookmarks) | ✅ | ✅ | ✅ | ✅ | ❌ (backend exists, no UI) |
| Keyboard shortcuts (⌘T/⌘W/⌘L/⌘R/⌘1-9) | ✅ | ✅ | ✅✅ | ✅ | ❌ none at all |
| target=_blank / window.open | new tab | new tab | new tab | new tab | ❌ forced same-tab; breaks OAuth popups |
| Downloads | ✅ | ✅ | ✅ | ✅ | ❌ silently do nothing in-webview (agent `browser_download` works) |
| Find in page (⌘F) | ✅ | ✅ | ✅ | ✅ | ❌ |
| Page zoom | ✅ | ✅ | ✅ | ✅ | ❌ |
| Session restore after quit | ✅ | ✅ | ✅ | ✅ | ❌ tabs live in chrome-JS memory only |
| Tab reorder / pinning | ✅ | ✅ | ✅✅ (spaces) | ✅ | ❌ |
| Context menu (open in new tab, copy link) | ✅ | ✅ | ✅ | ✅ | ❌ WKWebView defaults only |
| Private mode / containers | ✅ | ✅✅ | profiles | varies | ❌ one shared cookie jar (even across split panes) |
| Extensions / content blocking | ✅ | ✅✅ | ✅ | ✅ | ❌ structural (no ecosystem for WKWebView-in-Tauri) |
| Password manager / autofill | ✅ | ✅ | ✅ | ✅ | ❌ (no Keychain autofill hookup) |
| Sync across devices | ✅ | ✅ | ✅ | ✅ | ❌ (arguably out of scope) |
| Split view | ❌ | ❌ | ✅ | varies | ✅ built-in, independent surfaces |
| Workspace-native addressing (`/path`) | ❌ | ❌ | ❌ | ❌ | ✅ unique |
| Agent can see/drive the *user's* live tab | ❌ | ❌ | ❌ | partial, cloud-LLM | ✅✅ CLI-drivable, local, auditable |
| Every fetch/browse on an audit feed | ❌ | ❌ | ❌ | ❌ | ✅✅ Sentinel |
| Page isolation from app privileges | n/a | n/a | n/a | n/a | ✅ content webviews get zero Tauri capability |
| Memory per tab | shared-process pools | shared | shared | shared | ⚠️ one live WKWebView per tab, never evicted |

## Where we are genuinely ahead

1. **Agent co-presence is the real product and nobody else has it in this shape.**
   Dia, Comet, and Atlas bolt a cloud LLM onto Chromium; the assistant belongs to the
   browser vendor. Ours inverts it: any terminal agent (Claude Code, Codex) can read
   the user's active tab, navigate it, open tabs through the chrome so the tab strip
   stays honest, and screenshot it via an in-process WKWebView snapshot — no screen-
   recording permission, no cloud, and every action lands on the Sentinel feed. That
   trust story (local loopback, token-tiered, audited) is *stronger* than the AI
   browsers', not weaker.
2. **The isolation model is textbook.** Content webviews are created with no Tauri
   capability, nav-guarded to http(s)/about:blank, and the chrome↔Rust eval bridge
   escapes page-controlled strings (incl. U+2028/29). A hostile page can deface its
   own tab, not the app. Most embedded-webview apps get this wrong.
3. **Workspace addressing.** `/path` in the omnibox rendering workspace files, with
   the library and agent artifacts one keystroke away, is a feature no general
   browser has a reason to build.
4. **Small and legible.** ~2.5k lines that one person can hold in their head, versus
   ~30M for Chromium. Instant tab switching from kept-alive webviews. This is only a
   strength while the scope stays honest — see below.

## Where we are behind — ranked honestly

### Tier 1: broken, not missing (a user hits these in minutes)

- **The address bar can't search.** `resolve()` prefixes anything without a scheme
  with `https://`, so typing `tauri webview zoom` produces an invalid URL. This is
  the single most-used browser interaction and it errors. Table stakes since the
  Firefox awesome bar.
- **`window.open` is stubbed to same-tab navigation** (`NO_POPUPS_JS`). Reasonable
  when we had one tab; now it breaks every OAuth popup flow (Google/GitHub sign-in
  on third-party sites), sites that depend on the returned window handle, and it
  turns every `target=_blank` link into losing your current page. We have a tab
  system and an `__agentOpenTab` path — popups should become tabs.
- **Downloads silently no-op.** A click on a PDF/zip link neither saves a file nor
  shows UI; our own chrome code even carries a 20s spinner "safety net" for exactly
  this case. WKWebView needs a download delegate wired to disk + some minimal shelf.
- **Zero keyboard shortcuts.** No ⌘T, ⌘W, ⌘L, ⌘R, ⌘1-9, ⌘F. Worse, this is
  architectural: focus usually sits in the *content* webview, which the chrome JS
  can't hear — shortcuts need native menu accelerators or injected key handlers
  forwarded over the bridge, not a quick JS patch.

### Tier 2: missing table stakes

- **No omnibox suggestions** — while `BrowserHistory.search/2`, visit counts, and
  bookmarks all sit in SQLite/JSON ready to serve them. Highest ratio of
  already-built-backend to missing-frontend in the app.
- **No session restore.** Tab state (`tabs`, `activeId`) lives in the chrome
  webview's JS heap. Surviving a route change via `browser_hide` is not persistence;
  an app restart loses every tab. History is durable, tabs are not.
- **No find-in-page, no zoom** (WKWebView exposes both; nothing is wired).
- **No context-menu control**: no "open link in new tab" even though tabs exist.
- **Tab strip ergonomics**: no reorder, no pinning, no overflow handling beyond
  scroll, 200px cap with no middle-click close.
- **History has no full UI** — the home page shows recents, but the searchable,
  day-grouped, clearable history backend has no page. Also, only the *active* tab
  records history (`record()` guards on `id === activeId`), so a tab loaded in the
  background then never revisited leaves no trace.

### Tier 3: structural ceilings (know them, don't fight them yet)

- **WKWebView is the ceiling.** No extension ecosystem, no uBlock, Safari-tier site
  compat (fine) but Safari-tier only. The trade was correct — Chromium embedding
  (CEF/Electron) would cost us the tiny footprint and the snapshot/title objc
  bridges — but it caps "real browser" ambitions permanently.
- **One cookie jar for everything.** All tabs and both split surfaces share the
  default WKWebsiteDataStore. No private mode, no containers, no second account of
  anything. For an agent runtime this matters more than for a normal browser: the
  agent browses *as the user's sessions* with no way to sandbox that.
- **Kept-alive webviews don't scale.** Every tab is a live WKWebView forever; 30
  tabs ≈ 30 web processes. Mainstream browsers all evict/suspend background tabs.
- **macOS-only in load-bearing places** — titles and screenshots stub out elsewhere.
  Acceptable (distribution target is macOS), but it forecloses cheap Linux/Windows
  ports of exactly the features that differentiate us.

### Tier 4: an own-goal worth naming

- **Favicons leak browsing history to Google.** Both the chrome and bookmarks derive
  icons from `google.com/s2/favicons?domain=<host>` — every distinct host the user
  visits is reported to a third party, from an app whose identity is a local-first,
  Sentinel-audited trust story. This contradicts our own pitch. Fetch favicons
  server-side (we already have an SSRF-guarded fetcher) and cache them locally.

## What this means

We should not chase Arc or Firefox on breadth — that game is unwinnable and, given
the agent-runtime thesis, unnecessary. The bar to clear is different: **the browser
must never be the reason the user alt-tabs to Chrome**, because every trip to Chrome
removes the agent's eyes from the page. Today, search-from-omnibox, popups/OAuth,
downloads, and shortcuts each force that alt-tab within minutes of real use.

The strategic read: Tier 1 + the omnibox are one focused sprint and mostly reuse
backends that already exist; co-presence (our moat) deepens from there — DOM
read/extract for the active tab, click/fill primitives, per-surface ephemeral
sessions for agent work. That ordering — *stop the bleeding, then extend the moat* —
is the skeleton of the roadmap this review exists to justify.

---

# Code QX Review

*Same date. Dead-code audit + modularization assessment of the browser stack,
verified by grepping every public function for production callers.*

## Dead code

**One fully orphaned module: `BusterClaw.Browser.Reader` (117 lines + its test).**
It's the pre-native-webview "reader mode" — HTML → safe `{:text}/{:link}` token
stream for HEEx rendering. The WKWebView browser replaced it wholesale; its only
callers are its own tests, and a stale comment in `content_security_policy.ex:68`
still justifies a CSP rule by it. Delete the module, the test, and fix the comment
(the image-src rule is still justified by the native browser itself).

**`BrowserHistory` is ~60% speculative backend.** Of its public API, only
`record/2` and `recent/1` have production callers. `list/1`, `search/2`,
`grouped_by_day/1`, `visit_count/1`, `visit_counts/1`, `clear/0`, and
`clear_range/2` are exercised by tests alone — there is no history page, and no
`history_*` command in the agent catalog, so neither the user nor the agent can
reach any of it. This isn't cruft to delete so much as a shipped backend whose
frontend was never built (the review above flags the missing history UI). Decision
for the roadmap: wire it (a history page + `history_search` catalog entry are
cheap) or cut it — but today it's dead weight that makes the module read as more
feature-complete than the product is.

**Trivia:** `Bookmarks.grouped/0` is a one-line test-only wrapper (the home page
calls `group/1` directly). The Rust side is clean — all 15 `#[tauri::command]`s
are registered in `main.rs` and invoked from JS; every `BrowserState` helper has
callers; no dead Rust found.

## Modularization — the verdict

**The macro-architecture is genuinely good; the micro-packaging of the chrome is
the debt.** Layer ownership is crisp and documented: Rust owns webview lifecycle
and the per-surface active-tab pointer; chrome JS owns the tab-strip model; Elixir
owns everything durable (history, bookmarks) plus the fetch boundary; and the
co-presence path (`Commands` → `Bridge` pub/sub → `BrowserCaptureHook` →
`ScreenshotBridge` JS → Tauri → POST back) is a long seam but every segment is
small, single-purpose, and independently replaceable. The seven one-job browser
controllers are fine — that's cohesion, not sprawl. `browser.rs` at 863 lines is
single-file but sectioned, with the objc bridges properly quarantined behind
`cfg(target_os = "macos")`.

Four real problems:

1. **The chrome UI is a ~330-line JavaScript application inside an Elixir string
   literal** (`browser_chrome_controller.ex`), and the home page is a second one
   (310 lines, its own inline CSS/JS). No linting, no syntax highlighting, no
   tests, double-escaped regexes (`/^[a-z]+:\\/\\//`), and interpolation
   (`SID = "#{sid}"`) mixing template and program. This is the single worst file
   in the browser stack and it's the one that grows with every feature (the last
   three PRs all edited it). Move the JS to a real asset (`assets/js/chrome/`),
   serve it as a static file or EEx template — a prerequisite for omnibox
   suggestions, shortcuts, and everything else in Tier 1/2.

2. **Tab state has three partial owners and no durable one.** Chrome JS holds the
   truth (tab list, labels, favicons, `nextId`); Rust holds only the active-tab
   pointer; Elixir holds nothing. This split is *why* session restore is
   impossible today, and why `resolve_target` in Rust needs a three-step fallback
   chain for when "the chrome/Rust active pointers briefly diverge" — the code
   itself documents the race. The fix (persist tab state to Elixir, chrome hydrates
   from it) is the enabler for session restore and belongs early in the roadmap.

3. **Cross-boundary logic is triplicated by design.** `sanitize_sid` exists in
   Rust, the chrome controller, and `split_live.ex`; the `resolve()` URL heuristic
   exists in chrome JS and the `EmbeddedBrowser` hook; favicon derivation exists in
   chrome JS and `Bookmarks.favicon_url/1`. Each copy carries a "mirrors X" comment
   — honest, but comments don't fail CI when the copies drift, and all three are
   wire-protocol-adjacent where drift breaks silently. The JS pair is fixable today
   (shared module once the chrome JS is a real asset); the Rust/Elixir pair at
   minimum deserves a test asserting both sanitizers agree.

4. **History recording sits on the wrong seam.** It's a `fetch()` POST from chrome
   JS on the navigated callback, gated on `id === activeId` — so background-tab
   loads never record, and a chrome-webview hiccup silently drops history. Rust
   already observes every page load in `on_page_load`; recording should flow
   Rust → Phoenix directly and treat the chrome as pure presentation.

Minor: `CHROME_HEIGHT = 112.0` is hardcoded in Rust while the layout it must match
lives in the chrome CSS (`height: 112px`) — same silent-drift class as #3.

## Test coverage, honestly

Elixir is well covered (history, bookmarks incl. import/export round-trips,
browser fetch, the dead Reader). But the two layers where the actual browser
behavior lives — `browser.rs` and the chrome/hook JS — have **zero tests**
between them. Every Tier-1 bug in the review above (search, popups, downloads,
shortcuts) lives precisely in the untested layers. That's not a coincidence:
the tests cluster where testing is easy, not where the risk is. The chrome-JS
extraction in #1 is what makes JS unit tests possible; it should be treated as
the first roadmap item for that reason too, not just hygiene.
