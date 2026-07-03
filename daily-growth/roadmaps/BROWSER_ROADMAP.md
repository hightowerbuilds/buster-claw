# Browser Build-Out Roadmap

*2026-07-03. Sequenced from `BROWSER_REVIEW.md` (same folder). Governing principle:
**the browser must never be the reason the user alt-tabs to Chrome** — every
alt-tab removes the agent's eyes from the page. Strategy: stop the bleeding, then
extend the moat. We do not chase Arc/Firefox breadth.*

Effort tags: **S** = a sitting, **M** = a day-ish, **L** = multi-day / has unknowns.

---

## Phase 0 — Foundations (unblocks everything else)

*No user-visible features. Every later phase edits the chrome; make it editable first.*

1. **Extract the chrome UI out of the Elixir string literal.** (M)
   Chrome JS → `assets/js/chrome/` as real modules; CSS alongside; controller
   becomes a thin EEx template that injects only `sid`/`initial`. Do the home page
   (`browser_home_controller.ex`) the same way if it's cheap, else defer.
   *Done when:* chrome logic is lintable, importable, and covered by JS unit tests
   (bun test — `bun.lock` is already in the repo).
2. **Delete `BusterClaw.Browser.Reader`** + its test; fix the stale CSP comment
   (`content_security_policy.ex:68`). (S)
3. **De-duplicate cross-boundary logic.** One shared `resolve()`/`display()` URL
   module imported by both the chrome and the `EmbeddedBrowser` hook; a test
   asserting the Rust and Elixir `sanitize_sid` implementations agree on a fixture
   set; single source for favicon derivation (see Phase 1.5). (S)
4. **Move history recording to the Rust seam.** `on_page_load Finished` → POST
   `/browser/history` directly for *every* tab (not just active); chrome becomes
   pure presentation. Fixes the background-tab history hole for free. (S)

**Exit criteria:** chrome JS has tests; `mix precommit` + `bun test` green; no
behavior change visible to the user.

## Phase 0.5 — Field findings (07-03, from first real desktop use)

1. **Browser tabs were destroyed on every app-tab switch.** ~~Root cause: the
   app shell (and its TabStrip hook) renders *inside* each LiveView, so the
   hook remounts on every live navigation, and its `reconcileBrowserSurfaces()`
   — written to heal surfaces left stuck by full-page reloads — called
   `browser_close` on all surfaces whenever the page wasn't `/browse`,
   destroying the tabs that `EmbeddedBrowser.destroyed()` had just hidden for
   persistence.~~ **Fixed 07-03:** reconcile now hides instead of closes — hide
   is idempotent, safe on absent surfaces, and solves the only real stuck-case
   (a surface left *visible* over the wrong page) while keeping every tab
   alive. Note for Phase 2.1: this preserves tabs across navigation within an
   app session; app-*restart* restore still needs the durable tab state.
   Related cleanup for 2.1: `tearDownSplitBrowsers()` still closes surfaces on
   split rearrangement — revisit whether hide + reposition suffices there too.
2. **The app-wide tab strip is not visible while the browser is open.**
   **Mitigated 07-03** by an app-tab switcher carried *in the browser chrome*:
   a Home chip + every open app tab (read from the same `bc:tabs` localStorage
   the TabStrip persists — the chrome shares the app's origin and data store),
   navigating the main webview via a new `browser_app_navigate` Tauri command
   (absolute app paths only). The chrome is our own native webview, so it's
   visible above content *by construction* — no geometry required — and it's
   arguably the better switcher while browsing anyway.

   The underlying offset bug stays open (downgraded to Phase 2 polish).
   Measured 07-03 with in-app diagnostics: the JS side is **correct** — strip
   present at `0,0,w,39`, surface at `y=39`, and `offY = 0` because WKWebView
   reports `window.outerHeight` as 0 (so the old outer−inner "title-bar
   correction" in `hooks/browser.js` is dead code — a no-op by accident, kept
   harmless). wry 0.55.1 source (read, not guessed): child webviews are
   subviews of the window's `contentView`, flipped within the *parent view's*
   frame — so pure DOM coords should land exactly right, and tao only sets
   `FullSizeContentView` for custom title-bar styles we don't use. The
   remaining suspect is the *initial* `add_child` placement path diverging
   from `set_bounds`. Next probe when it matters: a Rust command that reads
   back `webview.position()` for the chrome and compares with intent.

## Phase 1 — Stop the bleeding (Tier 1: broken → working)

*Each of these currently forces the alt-tab within minutes. Highest priority.*

1. **Omnibox search.** (S–M) — **SHIPPED 07-03** (DuckDuckGo default, `browser_search_url` setting)
   Schemeless input with no dot/`localhost` → search engine query; everything else
   keeps current behavior (`/path` → workspace, URL-ish → https). Default engine a
   Settings entry (DuckDuckGo default — fits the privacy posture; Google/Kagi
   options).
2. **Popups and `target=_blank` open new tabs.** (M–L) — **SHIPPED 07-03** via mechanism (b): sentinel-scheme shim + nav-guard intercept → `__agentOpenTab`. The `window.opener` ceiling stands (needs (a), WKUIDelegate).
   Replace the same-tab `NO_POPUPS_JS` stub: the shim routes the URL through the
   existing new-tab path instead of clobbering the current page. Two candidate
   mechanisms, in order of preference: (a) a WKUIDelegate
   `createWebViewWithConfiguration` handler via the objc bridge pattern we already
   use for titles/snapshots; (b) keep the JS shim but have it navigate to a
   sentinel URL the `on_navigation` guard intercepts, cancels, and reopens as a
   tab. **Honest caveat:** OAuth flows that require a live `window.opener` /
   `postMessage` back-channel may still break under (b); (a) is the real fix.
   *Done when:* GitHub sign-in-with-Google on a third-party site completes
   in-app.
3. **Downloads.** (L) — **SHIPPED 07-03** via tauri on_download (no objc needed — wry ships the WKDownloadDelegate): deduped ~/Downloads saves, chrome shelf chips with reveal-by-id, Sentinel :untrusted_ingest per download, tab spinner cleared on download start.
   WKDownloadDelegate (macOS 11.3+) via objc bridge → save to `~/Downloads` (or
   the workspace downloads dir — decide in Settings), minimal shelf strip in the
   chrome (filename, progress, reveal-in-Finder), and a **Sentinel
   `:untrusted_ingest` event per download** so the audit story stays whole. The
   20s spinner "safety net" in the chrome dies with this.
4. **Keyboard shortcuts.** (M) — **SHIPPED 07-03**: Tabs menu with ⌘T/⌘W/⌘R/⌘L, ⌘⇧[/], ⌘1-9; routed to the shown surface chrome, else the app TabStrip.
   Native menu accelerators (shortcuts must work while focus is inside a content
   webview — chrome-JS key handlers can't hear it): ⌘T new tab, ⌘W close tab,
   ⌘L focus omnibox, ⌘R reload, ⌘⇧] / ⌘⇧[ and ⌘1–9 tab switching. Menu events
   route to the active surface's chrome via the existing eval bridge.
5. **Favicon privacy fix.** (S–M) — **SHIPPED 07-03** (`BusterClaw.Favicons` disk cache + /browser/favicon; bookmarks stop persisting favicon_url)
   `/browser/favicon?host=` endpoint: SSRF-guarded fetch of `/favicon.ico` (+
   HTML `<link rel=icon>` fallback), cached on disk. Swap both consumers (chrome
   JS, `Bookmarks.favicon_url/1`) off `google.com/s2`. Kills the
   browsing-history-to-Google leak named in the review.

**Exit criteria:** a normal person can use this as their browser for an afternoon
without opening Chrome once.

## Phase 2 — Table stakes (Tier 2: missing → present)

1. **Durable tab state + session restore.** (M) — **SHIPPED 07-03**: settings-blob per surface via GET/POST /browser/tabs; chrome saves debounced on every mutation, hydrates on cold load (deep links own tab 1, saved tabs append).
   Persist per-surface tab state (url, label, order, active id) to Elixir —
   `browser_tabs` table or a settings blob — written on every mutation, hydrated
   by the chrome on mount. Kills the three-owners problem from the QX review
   (Rust's `resolve_target` fallback chain shrinks), and app relaunch restores
   every tab. This is the QX fix and the user feature in one change.
2. **Omnibox suggestions.** (M) — **SHIPPED 07-03** as bookmark-row chips (the 112px chrome would clip a dropdown): /browser/suggest merges bookmarks + FTS history; ↓/↑/Tab select, Enter opens, Esc restores bookmarks.
   Dropdown under the address bar fed by the *already-built* backends:
   `BrowserHistory.search/2` + visit-frequency ranking (`visit_counts`) +
   bookmark matches. Keyboard navigable (↑↓ Enter Esc). This single item wires
   most of the dead `BrowserHistory` API.
3. **History page + agent commands.** (S–M) — **SHIPPED 07-03**: /history LiveView (day-grouped, FTS search, per-day + full clears, dock entry) + history_search/history_recent safe-tier commands. Nothing in BrowserHistory is dead. REVISED same day: history lives in the BROWSER, not the app dock — /browser/history is a content-webview-native page (home styling, GET ?q= search, POST clears) linked "Full history →" from the homepage; the /history LiveView + dock entry were cut.
   `/history` LiveView: day-grouped (`grouped_by_day/1`), searchable, clear /
   clear-range controls. Catalog additions: `history_search`, `history_recent`
   (safe tier). After this, nothing in `BrowserHistory` is dead.
4. **Find-in-page (⌘F).** (M) — **SHIPPED 07-03**: find bar in the bookmark row, browser_find → WebKit window.find (select+scroll, wraps; no match counts — needs the objc find API if ever missed). Small find bar in the chrome; match
   navigation via WKWebView's find API (objc bridge) or eval-based highlighting.
5. **Zoom (⌘+ / ⌘− / ⌘0).** (S) — **SHIPPED 07-03**: Tabs-menu items → chrome per-tab factor → browser_set_zoom (clamped 0.25–5). Tauri `set_zoom` per content webview; persist
   per-host zoom in settings if cheap.
6. **Context menu: "Open link in new tab".** (M) — **SHIPPED 07-03 as modifier-click** (⌘-click + middle-click any link → new tab, via the injected shim; a real context-menu entry needs the WKUIDelegate objc work, same ceiling as popups (a)). Injected handler routes through
   the popup→tab path from Phase 1.2.
7. **Tab strip ergonomics.** (S–M) — **SHIPPED 07-03**: drag-reorder (persisted), middle-click close; modifier-click links land in 2.6. Opened tabs are active-not-background (background needs show-less tab creation — punt). Drag-reorder, middle-click close, ⌘-click a
   link opens a background tab (recorded in history thanks to Phase 0.4).

**Exit criteria:** feature checklist parity with "a minimal but real browser" —
the scorecard's ❌ rows in Tiers 1–2 all flip.

## Phase 3 — Extend the moat (co-presence v2)

*What no mainstream or AI browser offers: a local, audited, CLI-drivable agent
sharing the user's live session. All new commands are Sentinel-audited; anything
that acts on (not just reads) the page lands in the restricted tier.*

1. **`browser_read`** — **SHIPPED 07-03** (restricted tier, Sentinel :untrusted_ingest per read; objc evaluateJavaScript-with-result bridge, so page CSP can never block it; visible-text + 200 links, 200KB cap). The "agent is reading" chrome indicator is still open — — extract the active tab's rendered DOM as
   markdown/text+links via the eval bridge. This reads *logged-in* pages the
   server-side `browser_fetch` can never see. Audited as `:untrusted_ingest`;
   consider requiring an open co-presence "session" the user can see in the
   chrome (a visible "agent is reading" indicator — trust is the product). (M)
2. **Page → Library capture.** `browser_capture_page`: `browser_read` +
   screenshot bundled into a Library artifact (the authed-DOM sibling of the
   existing fetch pipeline). (S after #1)
3. **Interaction primitives: `browser_find_elements`, `browser_click`,
   `browser_fill`.** Restricted tier, Sentinel-logged with selector + value
   provenance, and a visible in-chrome indicator while the agent drives.
   Deliberately *not* a full CDP/Playwright surface — small verbs the audit feed
   can narrate. (L)
4. **Agent sandbox tabs.** Ephemeral, non-persistent `WKWebsiteDataStore` for
   agent-opened tabs by default (`browser_open_tab` gains `session: "user" |
   "ephemeral"`), so agent work stops riding the user's cookies unless
   explicitly granted. Doubles as the foundation for user-facing private
   mode. (L — data-store-per-webview needs the objc bridge)
5. **Tab-aware events for the agent.** — browser_tabs command **SHIPPED 07-03** (reads the durable Phase-2.1 state, works while hidden); the opt-in navigation events remain open. `browser_tabs_list` command + optional
   Dispatch/PubSub event on navigation, so an on-duty shift can react to what
   the user is browsing (opt-in, off by default — Sentinel visibility again).
   (S–M)

**Exit criteria:** an agent can research *as the user* (read authed pages, file
artifacts), act under audit, and do scratch work in a sandbox that leaves no
trace in the user's sessions.

## Phase 4 — Opportunistic / stretch

- **Private mode & containers for humans** — falls out of Phase 3.4's data-store
  work; UI is a tab-strip affordance. (M after 3.4)
- **Content blocking via `WKContentRuleList`** — WebKit ships Safari's
  content-blocker engine; compiling an EasyList subset gives real ad/tracker
  blocking with no extension ecosystem needed. Uniquely available to us *because*
  we chose WKWebView. (L, high delight)
- **Background-tab suspension** — evict content webviews beyond N most-recent
  (tab entry survives via Phase 2.1 state; switch = reload). Caps the
  process-per-tab memory ceiling. (M)
- **Per-site permissions & TLS indicator** — camera/mic prompt handling, padlock
  in the omnibox. (M)
- **Reader mode** — only if a real need reappears; note the old `Reader` module
  was deleted for cause, don't resurrect its approach.

## Non-goals (on purpose, revisit only with cause)

- **Extensions / WebExtensions** — structural WKWebView limit; content blocking
  above covers the #1 use case.
- **Sync, profiles-across-devices, password manager** — the OS keychain +
  Safari/1Password autofill territory; not our fight.
- **Cross-platform (Windows/Linux) browser parity** — titles, snapshots,
  downloads, and data stores all ride the objc bridge; distribution target is
  macOS. Revisit only if distribution strategy changes.
- **Engine swap to Chromium/CEF** — would trade our footprint, snapshot bridge,
  and isolation model for compat we don't need.

## Sequencing notes

- Phase 0 → 1 is strict (every Phase 1 item edits the chrome). Within Phase 1,
  items are independent; search (1.1) and favicons (1.5) are the cheapest wins.
- Phase 2.1 (durable tabs) should land before 2.2/2.7 touch the tab strip again.
- Phase 3 is independent of Phase 2 except 3.4/3.5 benefiting from 2.1 — the
  moat work can interleave with table-stakes work if motivation calls for it.
- Ship order within a phase is by effort-to-payoff, and every phase ends with a
  dated dev summary + the scorecard rows in `BROWSER_REVIEW.md` flipped to ✅.
