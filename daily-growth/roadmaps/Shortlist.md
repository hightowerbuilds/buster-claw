# Shortlist

A running list of small, high-priority fixes and features to pick up.

## Items

### 1. Cmd-W should not close the whole app  🔵 IN REVIEW (PR #1) — ⚠️ STILL BROKEN

**Problem:** With a single tab open, pressing **Cmd-W** closes the entire
application. Cmd-W should only ever close a tab.

**Desired behavior:**
- **Cmd-W** closes the current tab only.
- If the last remaining tab is closed, the app should *not* quit — keep the
  window open (e.g. fall back to an empty/home tab) instead of terminating.
- **Cmd-Q** (and the red traffic-light X) are the only ways to close the window.

**Root cause — it's a TWO-layer fix (PR #1's JS-only change is not enough):**
Confirmed still broken on `main`. `desktop/tauri/src/main.rs` defines **no custom
menu and no window-close handling**, so the app gets Tauri's **default macOS
menu**, whose "Close Window" item is bound to **Cmd-W at the native level**. That
native accelerator fires regardless of the TabStrip hook's
`window.addEventListener("keydown", …, true)` + `preventDefault`, so JS can never
fully intercept it.
- **Native (main.rs / Tauri):** remove the Cmd-W accelerator from the default
  menu (build a menu without the standard Window→Close item, or override it) so
  Cmd-W is no longer a native window-close shortcut. Do **not** blanket-prevent
  the window `CloseRequested` event — the red X and Cmd-Q must still close it.
- **JS (`assets/js/hooks/tab_strip.js`):** change `closeCurrentTabOrWindow` to
  **never** call `closeWindow` — always close the active tab, and when it's the
  last tab, open a fresh home tab instead (keep the window alive).

### 2. Right-click on joined tabs to rename  🔵 IN REVIEW (PR #1)

**Problem:** Joined tabs can't be renamed.

**Desired behavior:**
- Right-clicking a joined tab opens a context menu with a **Rename** option.
- Selecting it lets the user edit the tab's label inline.
- Need to figure out the rename logic (where the tab label is stored, how it's
  persisted, and how it propagates to the UI).

### 3. Homepage calendar widget — CRT horizontal day-timeline  ✅ DONE (commit 77f9975)

**Problem:** The homepage calendar widget
(`BusterClawWeb.HomeWidget.daily_calendar_panel/1`, rendered in `StatusLive`)
shows today's events as a plain vertical list. It doesn't convey *when* in the
day things happen or how long they run — there's no sense of the day's shape.

**Desired behavior:**
- Replace the vertical list with an **hourly grid of the day laid out left to
  right** — time flows horizontally across the widget (hour columns / ticks
  along the x-axis).
- Events are **positioned spatially on the hours grid**: an event's horizontal
  offset reflects its `start_time` and its width reflects its duration
  (`start_time` → `end_time`). Overlapping events stack vertically within the
  same time span.
- **CRT aesthetic:** translucent event blocks (transparent coloring over the
  grid so the ruling shows through) plus **scan lines** over the surface for a
  retro-terminal look. Keep it on-brand with Industrial Claw (hazard-orange
  `#FF4D1C` accent, IBM Plex Mono for the hour labels, brutalist 2px borders).

**Notes / scope:**
- Data is already loaded: `StatusLive` assigns `@daily_events` via
  `BusterClaw.Calendar.events_in_range(today, today)`; each `Event` has
  `start_time`, `end_time`, `title`, `notes`, `color`, `frequency` (see
  `BusterClaw.Calendar.Event`). Times can be `nil` (all-day events) — decide
  how those render (e.g. a pinned all-day band above the grid).
- The widget lives in a narrow, scrollable corner card; the timeline likely
  needs horizontal scroll or a condensed hour range (e.g. clamp to the span
  that actually contains events, or a fixed working-hours window) so it stays
  legible in the header.
- Reuse `event_dot_class/1`'s color mapping for the translucent blocks; scan
  lines can be a CSS repeating-linear-gradient overlay (no new assets).

---

> Items 4–9 consolidated from now-retired roadmaps (`06-20-26-browser-review`,
> `06-20-26-ecosystem-roadmap-refined`, both archived to `old-maps/`). Only the
> *remaining* (unshipped) work is carried over — the bulk of both roadmaps is
> already done (see each map's status notes / git history).

### 4. Browser — agent co-presence commands (`browser_current` + drive-the-view)  🔵 IN REVIEW (PR #5)

**Status:** `browser_screenshot` already ships (commit `10119e6`). The pairing
commands that make the agent *co-present* with the user are still missing.

**Desired behavior:**
- **`browser_current`** — expose the active content tab's URL + title (read
  `BrowserState.active` in `desktop/tauri/src/browser.rs`) so the agent knows
  *what* the user is looking at.
- **`browser_navigate` / `browser_open_tab`** — let the agent drive the user's
  live view, not just observe it.
- Both new commands are **`:restricted`** tier and recorded on the Sentinel feed
  (capturing/driving the user's content is sensitive).

**Files:** `desktop/tauri/src/browser.rs` (+ `main.rs` `invoke_handler`),
`lib/buster_claw/commands/web.ex` + `commands/catalog.ex` (where
`browser_screenshot` lives), bridge from the chrome webview (content tabs have no
IPC).

### 5. Browser — chrome polish (loading + real page-title tabs)  🔵 IN REVIEW (PR #3)

**Problem:** The native chrome strip
(`lib/buster_claw_web/controllers/browser_chrome_controller.ex`) still derives tab
labels from the URL, shows no loading feedback, and ignores light mode. Bookmark
favicons shipped, but tabs themselves don't show them.

**Desired behavior (value order):**
- **Loading indicator** during navigation (zero feedback today).
- **Real page-title tabs** — wire `document.title` back through the existing
  `window.__onContentNavigated` callback in `browser.rs` (`on_navigation`).
- Tab favicons, a security/lock affordance, hover states/transitions, and
  light-mode support for the chrome.

**Notes:** most fixes live in that one controller's inline `<script>`/`<style>`
plus the `on_navigation` callback already in `browser.rs`.

### 6. Browser — history → SQLite  🔵 IN REVIEW (PR #2)

**Problem:** `<workspace>/.browser-history.json`
(`lib/buster_claw/browser_history.ex`) is **capped at 50** and **deduped by URL**,
so revisits collapse and visit frequency is lost; no search, day-grouping, visit
counts, or clear-range; a failed POST is **silently dropped**. Weakest data model
in the browser.

**Desired behavior:**
- Move to **SQLite/Ecto** (DB already present) as `(url, title, visited_at)` rows.
- Unlocks search, day-grouping, visit counts, ranged clearing, lifting the 50-cap,
  and lets the agent query "what did the user look at today."
- Fix the silent-drop-on-failure path.

### 7. Browser — bookmark folders + import/export  🔵 IN REVIEW (PR #4)

**Problem:** Bookmarks (`lib/buster_claw/bookmarks.ex`) have tags, search, a
bookmark bar, favicons, and agent commands (`bookmark_add/list/remove`), but are
still a **flat** list.

**Desired behavior:** folders/hierarchy and import/export.

### 8. Browser — tab LRU eviction *(later, not urgent)*

**Problem:** Tabs are **unbounded** — every open tab is a live WKWebView held in
memory with no eviction. Fine for normal use.

**Desired behavior:** if many tabs become common, add an LRU that destroys cold
tabs and lazily reloads them.

### 9. Swarm — one live end-to-end smoke test (no code)

**Status:** Ecosystem Phases 0–4 substrate is fully shipped and unit-tested with
injected runners. The **only** remaining item is one real end-to-end run with a
live `AgentRunner` (Claude Code) — the Phase 4 exit criterion.

**Exit criterion:** one Dispatch item decomposes into **≥3 parallel sub-runs that
aggregate into one result**, all on the Sentinel audit feed, within wallet budgets.

**Runbook** (server running; front door is now `on-duty`, not the old
`shift start`):
```
./buster-claw dispatch add "Research X across 3 angles and write a combined brief" --swarm
./buster-claw dispatch list          # confirm queued, strategy=swarm
./buster-claw on-duty                 # the autonomous loop pumps the swarm item
# Then check the Sentinel feed for per-sub-run provenance + the swarm outcome.
```
Once this passes once, the ecosystem roadmap is fully retired (already archived).

---

### 10. Tab switching by position (Cmd-1 … Cmd-9)

**Problem:** There's no keyboard shortcut to jump to a specific tab by its
position in the tab bar. Cmd-T opens a tab and Cmd-W closes one (TabStrip hook),
but *switching* between open tabs still requires a click.

**Desired behavior:**
- **Cmd-1** activates the 1st tab, **Cmd-2** the 2nd, … **Cmd-8** the 8th, and
  (matching the browser convention) **Cmd-9** jumps to the *last* tab regardless
  of count.
- Position follows the visible left-to-right order in the tab strip (the
  persisted tab order), so it tracks drag-reorders.
- No-op if there's no tab at that index.

**Notes / scope:**
- Lives in the **TabStrip** hook (`assets/js/hooks/tab_strip.js`): extend
  `handleShortcut/1` (already handling Cmd-T / Cmd-W) to catch Cmd-1…9. Read the
  ordered list via `this.load()`, pick the Nth tab, and navigate with
  `window.location.href = tab.path` (the same path TabStrip already uses).
- Capture-phase keydown is already wired (`window.addEventListener("keydown",
  this.onKeydown, true)`), so it beats xterm's own key handling when a terminal
  is focused.
- The handler already gates on `metaKey || ctrlKey`, so Ctrl-1…9 comes along for
  free on non-mac.
- Numbering counts **top-level** tabs only — Settings sub-routes that collapse
  into one tab share a single key, which `this.load()` already reflects.

### 11. Confirm before closing a busy terminal

**Problem:** A terminal tab can be closed with a single Cmd-W / × click while a
process is still running in it (a build, a long command, or — worst — a live
Claude Code / Codex agent session). There's no guard, so it's easy to
**accidentally kill a running terminal** and lose the work in flight.

**Desired behavior:**
- When closing a terminal tab whose PTY has a **running foreground process**
  (anything beyond an idle shell prompt), show a **confirmation modal** —
  "This terminal is running something. Close it anyway?" — before the tab/PTY is
  destroyed.
- An **idle** terminal (shell at the prompt) closes with no prompt, as today.
- Goal: eliminate *accidental* closes; deliberate ones still go through with one
  confirm.

**Notes / scope:**
- Closing a terminal tab flows through `TabStrip.closeTab` (`tab_strip.js`) →
  navigation → `TerminalView.destroyed` (`terminal.js`), which invokes
  `terminal_close` for keyless PTYs. The confirm has to gate **both** the × click
  and the **Cmd-W** path (and any future Cmd-9-style close).
- **The hard part is the "is it busy?" signal** — the PTY lives in Rust
  (`desktop/tauri/src/terminal.rs`), not JS. Most reliable: on the native side,
  compare the PTY master's **foreground process group** (`tcgetpgrp` on the pty
  fd) against the shell's own pid — if they differ, a child is running. Expose it
  as a `terminal_busy(id)` Tauri command (or fold a `busy` flag into the existing
  tab metadata) that the close path queries before destroying.
- Heuristic fallback if the fg-pgrp read is awkward: treat a terminal as busy if
  it was opened with a `startup_command` / agent `role_key` (the
  Claude-Code/Codex tabs we most want to protect) — coarser but cheap.
- Reuse the app's existing confirm UX where possible; the simple `data-confirm`
  attribute won't work here because the decision is **async/native**, so this
  likely needs a small custom modal triggered after the busy query resolves.

---

## Manual testing checklist (PRs #1–#5)

Items 1, 2, 4, 5, 6, 7 shipped as five parallel PRs. Each passed
compile + `mix test` (and `cargo check` where relevant), but the verification bar
was **compile + tests only** — interactive desktop click-through is on me. Run the
desktop app and walk these before merging.

**Before testing the JS PRs (#1, #5):** the `assets/js/hooks/` + `assets/js/lib/`
split (the app.js refactor) is still **uncommitted/untracked on `main`**. Commit
that on `main` first, or rebase #1/#5 onto it — otherwise their JS bases won't
line up cleanly.

- [ ] **PR #1 — Tab UX (items 1 & 2)**
  - With a **single tab** open, press **Cmd-W** → the tab closes but the **app
    stays open** on a fresh home tab (does NOT quit).
  - Press **Cmd-Q** → the app still quits normally.
  - **Right-click a joined/split tab** → the flyout shows **Rename** → click it,
    edit inline, confirm the new label persists across a reload.

- [ ] **PR #2 — History → SQLite (item 6)**
  - Browse several sites, then **revisit** one. The homepage "Recent" list shows
    each site once (deduped for display), newest-first.
  - Confirm **visit counts** reflect revisits and **search** returns matches.
  - (Optional) confirm clearing a date range works.

- [ ] **PR #3 — Chrome polish (item 5)**
  - Navigate the in-app browser → a **loading indicator** (hazard-orange spinner +
    top progress bar) appears during load and clears on finish.
  - Tab labels show the **real page title** (not just the hostname).
  - Tab **favicons** render; a broken icon falls back gracefully.
  - Trigger a slow/blocked navigation and confirm the spinner clears within ~20s
    (the safety timeout) rather than sticking.

- [ ] **PR #4 — Bookmark folders + import/export (item 7)**
  - Add bookmarks into a **folder** → they render **grouped** by folder on the
    homepage; root bookmarks still show.
  - Run **export** then **import** → no duplicates, folders + tags preserved.
  - Confirm an old **flat (folderless)** bookmark file still loads at root.

- [ ] **PR #5 — Agent co-presence commands (item 4)**
  - With a browser tab open, have the agent call **`browser_current`** → returns
    the active tab's URL + title.
  - **`browser_navigate`** drives the active tab; **`browser_open_tab`** opens a
    new tab (tab strip stays in sync).
  - All three are **`:restricted`** → as an untrusted/agent caller they require
    confirmation and land on the **Sentinel audit feed**.

**Repo-health note (separate from these PRs):** `mix precommit` halts at
`credo --strict` on ~50 pre-existing findings in unrelated files (fails on `main`
too), so workers verified via `mix test` directly. Worth a dedicated cleanup pass.
