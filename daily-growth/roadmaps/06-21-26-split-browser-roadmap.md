# Two browsers side-by-side (instanceable native browser)

**Date:** 2026-06-21 · **App version:** 0.1.0

> **Status:** Shipped — commit `6420a63`. `cargo check` passes (tauri-build accepts the
> capability glob); 662 Elixir tests green. **Pending:** user-driven desktop smoke test
> (needs a Tauri rebuild — the capability is compiled in) and push.

## Context

The in-app browser was a **singleton**: Rust (`desktop/tauri/src/browser.rs`) kept one
`browser-chrome` webview, a set of `browser-content-<id>` webviews, and a single
active-tab pointer (`BrowserState { active: Mutex<Option<String>> }`). The
`EmbeddedBrowser` JS hook (`assets/js/app.js` ~608) glued that one surface to whatever
`/browse` pane was on screen.

The split system already existed and is generic: `/split?left=<path>&right=<path>`
(`SplitLive`) renders two embedded LiveViews with a draggable divider, swap, and
per-pane close (all built). You could already pick `/browse` for a pane — but two
`/browse` panes both drove the **one** singleton browser: they fought over
`browser_set_bounds` and only one content webview was ever visible. So "two browsers side
by side" didn't work.

**Goal:** make the native browser *instanceable* (keyed by a surface id), so two
`/browse` panes become two fully-independent browsers — each with its own tab strip,
address bar, bookmark bar, back/forward, and active tab. Reuse the existing split UI
entirely. Solo `/browse` is unchanged (surface id `"main"`).

**Decided:** closing one side of a browser+browser split (or "separating" them) does a
**cold restart** of the kept browser — simplest, leak-free, matches today's
close-Browser-tab behavior. Swap is exempt (it stays a split).

## Approach

Thread a sanitized `surface_id` (`"main"` | `"left"` | `"right"`) through every layer.

### 1. Rust — `desktop/tauri/src/browser.rs`

State becomes per-surface:
```rust
pub struct BrowserState { surfaces: Mutex<HashMap<String, String>> } // sid -> active tab id
// helpers: set(sid,tab) / get(sid) / clear(sid) / clear_all() / any_sid()
```
Label scheme (sid is hyphen-free, so concatenation parses unambiguously):
```rust
const CHROME_PREFIX:  &str = "browser-chrome-";   // browser-chrome-<sid>
const CONTENT_PREFIX: &str = "browser-content-";  // browser-content-<sid>-<tabid>
const DEFAULT_SID:    &str = "main";
fn sanitize_sid(s) -> String     // [A-Za-z0-9] only, empty -> "main" (mirror split_live dom_id_part)
fn chrome_label(sid)             // browser-chrome-<sid>
fn content_label(sid, tab_id)    // browser-content-<sid>-<tabid>
fn content_labels_for(app, sid)  // filter by prefix "browser-content-<sid>-"
fn all_browser_labels(app)       // every chrome-*/content-* (for close-all)
```
Every command and helper gains `surface_id` (frontend sends camelCase `surfaceId`):
`browser_open / set_bounds / new_tab / switch_tab / close_tab / navigate / back /
forward / reload / hide`. Per-surface fixes:
- `sample_content_bounds(app, sid)` filters to that surface (previously grabbed *any* content view — would copy the wrong pane's box).
- `create_content`'s `on_navigation` closure captures `sid` and targets `chrome_label(&sid)` so nav events reach the right chrome.
Two-mode teardown + default screenshot:
- `browser_close(app, state, surface_id: Option<String>)` — `Some(sid)` closes that surface; `None` closes `all_browser_labels` + `clear_all()`. Serde maps absent arg → `None`, so the global `invoke("browser_close")` still means close-all.
- `browser_screenshot(app, state, surface_id: Option<String>)` — default `surface_id.or(any_sid()).unwrap_or("main")`, then capture that surface's active tab.

`main.rs` invoke_handler list and `build.rs` command list are **unchanged** (same command names; only signatures change). `.manage(BrowserState::default())` unchanged.

### 2. Capability — `desktop/tauri/capabilities/browser-chrome.json`

`"webviews": ["browser-chrome"]` → `"webviews": ["browser-chrome-*"]`.
(Verified: Tauri v2 `webviews` accepts glob patterns — `tauri-utils-2.9.1` ACL compiles
each entry with `glob::Pattern`; `cargo check`'s tauri-build accepted it.) Use
`browser-chrome-*`, **not** `browser-*` — content webviews (`browser-content-…`) must
stay out of every capability (no IPC). `default.json` unchanged (the hook + screenshot
bridge run in the main window's webview).

### 3. Chrome controller — `lib/buster_claw_web/controllers/browser_chrome_controller.ex`

- `show/2`: read + sanitize `params["sid"]` (default `"main"`); pass into `page/2`.
- In the inline `<script>`, define `const SID = "<sid>"`.
- Inject `surfaceId: SID` into **every** `browser_*` invoke centrally in `inv()` (the one
  wrapper all browser commands flow through) rather than per call site.
- Bookmarks/history fetches (`/browser/bookmarks`, `/browser/history`) stay
  origin-relative and **global/shared** across surfaces — desired (bookmarks are global).

### 4. JS hook — `assets/js/app.js`

`EmbeddedBrowser` (~608):
- `this.sid = this.el.dataset.surfaceId || "main"`.
- chrome URL: `…/browser/chrome?sid=<sid>(&url=…)`.
- add `surfaceId: this.sid` to `browser_open`, `browser_set_bounds`, and the
  `destroyed`→`browser_hide`.

Teardown on split→solo transitions (cold restart): `closeSplitPane` and `separateTabs`
call a new `tearDownSplitBrowsers(...panePaths)` → `invoke("browser_close")` (no arg →
close-all) **before** navigating, when the split being left contained any `/browse` pane.
`swapSides` is **exempt** (it stays a browser+browser split; surfaces persist and just
reposition). `TabStrip.closeTab`'s existing global `browser_close` for `/browse` is
unchanged.

### 5. LiveViews — `split_live.ex` + `browse_live.ex`

- `SplitLive`: thread `side` through `pane_spec/pane_child_session`; for a `/browse` pane,
  put `"surface_id" => side` (`"left"`/`"right"`) into the child session (same mechanism
  terminal panes use).
- `BrowseLive.mount/3`: read `session["surface_id"]` (default `"main"`); assign it.
- `BrowseLive.render`: unique container id `id={"browse-shell-" <> @surface_id}` + a
  `data-surface-id` attribute (fixes the duplicate `id="browse-shell"` when two instances
  mount).

## Files modified
- `desktop/tauri/src/browser.rs` (bulk of the work)
- `desktop/tauri/capabilities/browser-chrome.json` (one line; regenerates `gen/schemas/capabilities.json`)
- `lib/buster_claw_web/controllers/browser_chrome_controller.ex`
- `assets/js/app.js` (EmbeddedBrowser hook + closeSplitPane/separateTabs)
- `lib/buster_claw_web/live/split_live.ex`
- `lib/buster_claw_web/live/browse_live.ex`

## Risks / notes
- Capability changes need a full Tauri/cargo rebuild (compiled at build time; `mix
  phx.server` hot-reload won't pick it up). Native behavior is user-verified.
- Use `browser-chrome-*` (keeps content webviews IPC-isolated). Sanitize sid to a
  hyphen-free alphabet so labels parse.
- Screenshot in a 2-browser split defaults to "a" browser (any/first surface) — fine for
  v1; can add a `last_focused` pointer later if needed.
- Bookmark/history bars are per-chrome-load; a save in one chrome won't live-update the
  other until it reloads. Minor, acceptable.

## Verification
1. **Done:** `cargo check` (Rust compiles; tauri-build accepts the glob); `mix test` —
   662 green, +4 (split left/right surfaces, chrome sid threading/sanitizing); assets
   bundle clean; `mix format` clean.
2. **Pending — user-driven desktop run** (`scripts/dev.sh`, then rebuild Tauri):
   - Solo `/browse` still works (sid "main"), multiple tabs.
   - Join two `/browse` tabs → `/split?left=/browse&right=/browse`: two independent
     browsers, each navigable, own tabs/address bar/bookmark bar; divider resize keeps
     both glued.
   - Swap sides: each browser (with its tabs+page) moves to the other side.
   - Close one pane / separate: kept browser cold-restarts at the homepage; no lingering
     or ghost webviews.
   - Screenshot command still returns a page.

## Follow-ups (deferred)
- Focused-surface screenshot (`last_focused` pointer) instead of any-surface default.
- Sid continuity on pane close (preserve the kept browser's tabs/page instead of cold
  restart) — explicitly declined for v1 in favor of the simpler cold restart.
