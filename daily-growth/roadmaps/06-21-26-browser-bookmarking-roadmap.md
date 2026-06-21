# Browser Bookmarking Improvement Roadmap (2026-06-21)

**Date:** 2026-06-21 · **App version:** 0.1.0 · **Source:** `06-20-26-browser-review-roadmap.md`

## Why this exists

The browser review identified bookmarks as the weakest surface in the browser (Grade C−). They work, but the homepage is a dense text list with no visual hierarchy, no categorization, no favicons, and no agent commands. This roadmap brings them up to parity with the rest of the app in four focused stages.

> **Status (2026-06-21):** Stages 1–3 shipped. Stage 4 (chrome bookmark bar) deferred — explicitly the lowest priority.
> - Stage 1 — Tags + agent commands — ✅ `88691c2`
> - Stage 2 — Favicons + card-grid homepage — ✅ `c35beb9`
> - Stage 3 — Homepage search + tag filter — ✅ (this session)
> - Stage 4 — Chrome bookmark bar — ⬜ deferred

## What we are NOT doing

- **Folders** — tags are more flexible and less UI work. Revisit only if tags prove insufficient.
- **SQLite migration** — the JSON file is fine until the list grows past a few hundred. Tags + search can filter in-memory.
- **Import/export** — niche; defer until someone asks.
- **Bookmark bar in chrome toolbar** — listed as Stage 4 but is lower priority than the homepage experience.

---

## Stage 1 — Tags + Agent Commands (~half day)

Extend the bookmark data model and command surface before touching UI.

### 1A. Tags in the data model

- `Bookmarks.add(url, label, tags \\ [])` — `tags` is a list of strings, normalized (downcased, trimmed, deduped).
- Each entry gains a `"tags"` field: `["news", "work"]`.
- Update `BrowserBookmarkController.create/2` to accept `tags` param (comma-separated or repeated).
- Update `browser_home_controller.ex` to render tags (if present) on each bookmark row.

### 1B. Agent commands

Three new `:safe` commands in `commands.ex`:

| Command | Tier | Args | Description |
|---|---|---|---|
| `bookmark_add` | `:restricted` | `url`, `label`, `tags` | Save a bookmark. |
| `bookmark_list` | `:safe` | `tag` (optional) | List bookmarks, optionally filtered by tag. |
| `bookmark_remove` | `:restricted` | `url` | Remove a bookmark by URL. |

- All recorded via `Sentinel`.
- `bookmark_add` mirrors the chrome "+ Bookmark" button; agents can save findings directly.

### Exit criteria
- `bookmark_list` returns tagged entries; `bookmark_add` with tags round-trips correctly; tests green.

---

## Stage 2 — Favicons + Visual Homepage Redesign (~half day)

Make `/browser/home` look like a real bookmark page.

### 2A. Favicon fetching

- On `Bookmarks.add`, kick off a best-effort favicon fetch: `https://<host>/favicon.ico`, fallback to Google's public favicon service (`https://www.google.com/s2/favicons?domain=...`).
- Store favicon URL (not bytes) in the bookmark entry: `"favicon_url"`.
- If fetch fails, entry still saves; favicon is optional.

### 2B. Homepage visual redesign

Replace the dense text list with a card/grid layout:

- **Bookmark cards**: favicon (16×16 or 32×32) + label + hostname + tags as chips.
- **Grid**: 2–3 columns on desktop, 1 column on narrow viewports.
- **"Recent" section**: keep as a compact list below bookmarks (it's secondary).
- **Empty state**: friendlier copy + a CTA to open a page and bookmark it.
- Reuse the existing dark theme (`#121212`, `#F4F1EA`, `#FF4D1C`) but add subtle hover states and transitions.

### Exit criteria
- Homepage renders cards with favicons and tags; looks intentional rather than accidental.

---

## Stage 3 — Homepage Search + Tag Filter (~2h)

Add a search input and tag chips to the homepage so users can find bookmarks quickly.

- **Search**: real-time filter on label, URL, and tags. Pure client-side JS in the homepage (no server round-trip).
- **Tag chips**: render unique tags as clickable filters; clicking a tag narrows the list.
- **Clear**: a "Clear" link resets the filter.

### Exit criteria
- Typing in the search box filters the list; clicking a tag filters by that tag.

---

## Stage 4 — Bookmark Bar in Chrome Toolbar (later / half day)

A persistent quick-access strip in the chrome toolbar (`browser_chrome_controller.ex`), not just the homepage.

- Render the top N bookmarks (or all, if few) as small favicon+label buttons between the address bar and the "+ Bookmark" button.
- Clicking a bar item navigates the active tab to that URL.
- Optional: a small dropdown overflow if the bar gets crowded.

### Exit criteria
- Bookmarks are reachable without opening the homepage.

---

## Key files

- Data: `lib/buster_claw/bookmarks.ex`
- Chrome: `lib/buster_claw_web/controllers/browser_chrome_controller.ex`
- Homepage: `lib/buster_claw_web/controllers/browser_home_controller.ex`
- API: `lib/buster_claw_web/controllers/browser_bookmark_controller.ex`
- Commands: `lib/buster_claw/commands.ex`
- Tests: `test/buster_claw/bookmarks_test.exs`, `test/buster_claw_web/controllers/browser_bookmark_controller_test.exs` (new)

## Suggested first action

Start with Stage 1A (tags in the data model) — it's pure Elixir, well-tested, and unlocks everything downstream.
