# Browser Review & Roadmap (2026-06-20)

A code-QX + feature + performance review of Buster Claw's embedded browser,
benchmarked against Arc / Safari / Firefox. Scope per the request: **styling,
bookmarking, history, and enabling the Agent to easily capture screenshots of what
real-time users are seeing.** Dev tools are explicitly out of scope.

## Verdict

A clean, well-architected webview **navigator — not yet a browser frame**. The
engineering underneath is good (Tauri v2 + Wry/WKWebView, a smart two-webview model,
proper isolation, no polling, instant tab switching), but it's feature-thin vs real
browsers, the chrome is styled by hand outside the design system, and — the headline
gap — **the Agent is blind to the live browser**: it can fetch/download URLs
headlessly but cannot see, navigate, or screenshot what the user is actually looking
at. Closing that is the highest-value work.

## Scorecard (vs Arc / Safari / Firefox)

| Dimension | Grade | Notes |
|---|---|---|
| Core architecture | A− | Native multi-webview, reuse-not-recreate, isolated content tabs, event-driven. |
| Navigation basics | B | Tabs, back/fwd/reload, address bar, workspace paths work. |
| Styling / QX | C | On-brand colors but raw inline CSS; no favicons, loading state, page-title tabs, hover/transitions. |
| Bookmarking | C− | JSON file add/list/remove + dedupe. No folders/tags/search/bar/favicons; no agent commands. |
| History | C− | JSON file **capped at 50**, dedupe collapses revisits; no search/grouping/clear-range; silent drop on failure. |
| **Agent integration** | D | Agent can't navigate, read current URL, or screenshot the live view. |
| Performance | B+ | No polling / no main-thread blocking / instant switch. Nit: unbounded live tabs, no eviction. |

## Architecture (the parts that are good — don't touch)

- **Two-webview model** (`desktop/tauri/src/browser.rs`): an 80px Phoenix-served
  chrome strip (`browser-chrome`) + N content webviews (`browser-content-<id>`),
  exactly one visible, the rest hidden-but-alive → instant tab switch with preserved
  scroll/DOM. Right design.
- **Security**: content webviews run in *no* Tauri capability (loaded pages get zero
  IPC); a navigation guard allows only `http/https/about:blank`; `window.open` /
  `target=_blank` hijacked to navigate in-place (`browser.rs` init script).
- **No perf foot-guns**: navigation reports back via a single `eval()` callback
  (`window.__onContentNavigated`), no polling; release/PTY work is off-main-thread.
- Stack: **Tauri 2.11.1 / Wry 0.55.1 (WKWebView on macOS)**. No image/capture crates.

## Priority 1 — Agent screenshots of the live view (the unlock)

**Today:** absent. Agent has only `browser_fetch` (markdown) and `browser_download`
(bytes) — both *headless refetches*, not the user's actual view. No command reads the
current tab/URL; no screenshot path exists. `BrowserState.active` (the live tab id)
is private to Rust. WKWebView *has* a native snapshot API; Wry/Tauri just don't
surface it.

**Recommended approach — `browser_screenshot` via Tauri v2 `with_webview` + WKWebView
`takeSnapshot`, no Wry fork:**
- Tauri v2 exposes the platform webview handle via `Webview::with_webview(|pw| …)`;
  on macOS that's the `WKWebView` pointer. Call its native
  `takeSnapshot(with:completionHandler:)` via `objc2`, bridge the async completion
  back over a channel, return PNG bytes.
- **No permission prompt** — `takeSnapshot` is in-process DOM rendering, so it does
  NOT trip macOS Screen Recording (TCC), unlike OS window capture. This is the
  "easy" path the request asks for.
- Captures exactly the **active content tab** the user is looking at, at real size.
- Effort: ~**1 day** (`with_webview` avoids the Wry fork the raw route would need).

**Pipeline to wire end-to-end:**
1. **Tauri** `browser_screenshot(tab_id?) -> Vec<u8>` in `browser.rs` (resolve active
   tab from `BrowserState`, `with_webview` → `takeSnapshot`); register in
   `desktop/tauri/src/main.rs` `invoke_handler`.
2. **Bridge**: capture must originate host-side (content tabs have no IPC). Invoke
   from the chrome webview (which has IPC) or add a tiny loopback route the Phoenix
   side calls.
3. **Command surface**: a `browser_screenshot` catalog command
   (`lib/buster_claw/commands.ex`) that saves the PNG into the workspace (new
   `screenshots/<date>/` or reuse `downloads/`) and returns the path — composes with
   `drive_upload`, gmail attachments, etc.
4. **Audit/tier**: capturing the user's content is sensitive → make it
   **`:restricted`** and record a Sentinel capture event.

**Pair with it (cheap, high value):** `browser_current` (expose active tab URL/title
from `BrowserState`) so the agent knows *what* it's looking at; and agent-facing
`browser_navigate` / `browser_open_tab` (all `:restricted`, audited) so the agent can
drive the user's view, not just observe it. "Screenshot + current URL + navigate" is
what makes the agent co-present with the user.

**Judgment call:** if a screenshot must include the chrome strip or native
video/canvas (things a DOM snapshot misses), that needs OS-level capture
(ScreenCaptureKit) which requires a one-time Screen Recording grant. Ship the
no-permission `takeSnapshot` first; add OS capture only if a real case demands it.

## Priority 2 — Styling QX

The chrome (`lib/buster_claw_web/controllers/browser_chrome_controller.ex`) is raw
HTML with **hardcoded inline CSS** duplicating the `#121212/#F4F1EA/#FF4D1C` tokens
(it can't use the `ic-` utilities — those are HEEx-only). Gaps vs a real browser, in
value order:
- **No favicons** on tabs (text labels only) — biggest "unfinished" tell.
- **No loading indicator** — zero feedback during navigation.
- **Tab labels derive from the URL, not the page `<title>`** — wire `document.title`
  back through the existing `__onContentNavigated` callback.
- No security/lock affordance, no hover states/transitions, chrome ignores light mode.

Most fixes live in that one controller's inline `<script>`/`<style>` plus the
`on_navigation` callback already in `browser.rs`. Favicons + loading state + real
titles lift perceived quality C → B+ cheaply.

## Priority 3 — Bookmarking

`<workspace>/.browser-bookmarks.json` (`lib/buster_claw/bookmarks.ex`) with
add/list/remove + dedupe works but is flat. Missing: **folders, tags, search, a
persistent bookmark bar** (only a homepage list + "+ Bookmark" button), favicons,
import/export. No agent commands — `bookmark_add` / `bookmark_list` are easy wins for
agent co-presence.

## Priority 4 — History

`<workspace>/.browser-history.json` (`lib/buster_claw/browser_history.ex`) **capped at
50** and **deduped by URL**, so revisits collapse and visit frequency is lost; no
search, day-grouping, visit counts, or clear-range; a failed POST is **silently
dropped**. Weakest data model in the browser. Recommend moving to **SQLite/Ecto**
(DB already present) as `(url, title, visited_at)` rows — unlocks search, grouping,
counts, ranged clearing, and lets the agent query "what did the user look at today."

## Performance

Healthy. Only structural note: **tabs are unbounded** — every open tab is a live
WKWebView held in memory with no eviction. Fine for normal use; if many tabs are
expected, add an LRU that destroys cold tabs and lazily reloads. Not urgent.

## Suggested sequence

1. **`browser_screenshot` + `browser_current`** (~1–1.5 days) — agent becomes
   co-present with the user. *Start here.*
2. **Chrome polish**: favicons + loading indicator + real page-title tabs.
3. **Agent browser-control** (`browser_navigate`, `bookmark_add/list`) — restricted +
   audited.
4. **History → SQLite** (search/grouping/counts; lift the 50-cap).
5. *(Later)* bookmark folders/search; tab eviction if needed.

## Key files

- Rust webviews: `desktop/tauri/src/browser.rs`, `desktop/tauri/src/main.rs`,
  `desktop/tauri/capabilities/*.json`, `desktop/tauri/Cargo.toml`
- Chrome/pages: `lib/buster_claw_web/controllers/browser_chrome_controller.ex`,
  `browser_home_controller.ex`, `browser_workspace_controller.ex`
- LiveView shell: `lib/buster_claw_web/live/browse_live.ex`, `split_live.ex`;
  JS hook `EmbeddedBrowser` in `assets/js/app.js`
- Data: `lib/buster_claw/bookmarks.ex`, `lib/buster_claw/browser_history.ex`,
  history/bookmark controllers
- Agent surface: `lib/buster_claw/commands.ex` (`browser_fetch`, `browser_download`),
  `lib/buster_claw/browser.ex`, `lib/buster_claw/system_browser.ex`
