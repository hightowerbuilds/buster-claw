# 07-20-26 — The homepage grows a tab system

A focused homepage day: the calendar left the dock and became a Home sub-tab, a
Notes surface joined it, and the corner widget was pared back and reordered. The
session opened by reading the whole roadmaps folder and distilling it into one
ordered, costed critical-path document. Everything is on `feat/home-calendar-subtab`.

## 1. The critical path, written down (`CRITICAL_PATH_ROADMAP.md`)
Read the seven active roadmaps (Distribution, GTM, BusterPhone, both review
punch-lists, Home-Chat agent selection, Leftovers) and synthesized the one thing
they all converge on: the software is built; the business around it is not. Three
blockers — **ship it** (Apple signing/notarization/arm64), **sell it** (no
purchase flow; Google/CASA), **focus it** (five surfaces, no front door) — turned
into a staged, costed to-do list. Punchline: ≈$99 + ~2–3 focused weeks gets a
stranger to download → trust → pay for BusterPhone voice, if voice is committed to
as the first paid product (which defers CASA entirely). The doc is a synthesis of
the existing roadmaps, not new strategy.

## 2. Calendar → a Home sub-tab (`bcc68d4`)
The calendar moved off the dock and onto the Home page behind a **Chat | Calendar**
sub-tab toggle; Chat is the default, and switching to Calendar hides the chat.

The mechanism: extract the whole month/week/day calendar out of `CalendarLive`
into an embeddable **`CalendarComponent`** (a LiveComponent that renders inline,
no layout of its own — sidestepping the nested-`live_render` double-layout trap).
`CalendarLive` is now a thin wrapper around it, so the `/calendar` route, the
SplitLive split pane, and deep links keep working from one source of truth. The
component initializes once (guarded by `:loaded`) so the homepage's frequent
re-renders — chat streaming, sky ticks — never reset calendar navigation. Every
binding sets `phx-target={@myself}` (threaded into the view sub-components)
because an ancestor `phx-target` resolves via `closest/1` in the browser but
per-element in `LiveViewTest`; the `CalendarDrag` hook switches to
`pushEventTo(this.el, ...)`. Removed from the dock nav; tab-strip label preserved.

## 3. Notes — a simple Obsidian-style surface (`685f3fc`)
A third sub-tab: **Chat | Calendar | Notes**. Notes are plain `.md` files under
`<workspace>/notes/`, filename-as-title — grep-able, no DB, no frontmatter, the
same "markdown you own" posture as the rest of the workspace. `BusterClaw.Notes`
is the file-backed context, path-guarded so a note name can't contain separators
or `..` and the resolved path is confirmed under `notes/` (a test proves
`../secret` is refused). `BusterClawWeb.NotesComponent` is the embedded
LiveComponent: a note list + new-note field on the left, an editor beside a live
reading view on the right, autosaving on a 500ms debounce. The editor `<textarea>`
lives in a `phx-update="ignore"` wrapper keyed by note name — the client owns the
text (no cursor jumps as the reading view re-renders) and note-switch swaps
content cleanly. Rendering reuses the sanitized `BusterClaw.Markdown`. Boot ensures
the `notes/` directory. Deferred (kept out of "start simple"): note **rename** and
`[[wiki-links]]`.

## 4. The corner widget: calendar out, Time & Place first (`685f3fc`)
The calendar month grid was removed from the top-right corner widget — it now
lives only on the Calendar sub-tab, de-duplicating one of the reviews' "multiple
calendar systems." The remaining widget tabs were reordered to
**Time & Place / Contacts / Notify**, with Time & Place as the default: its analog
clock renders instantly, and a new `mount_weather/1` fills conditions on connect,
deliberately picking a *single* weather source (the sky fetch in weather-bg mode,
else the widget's `load_weather`) so two `:weather` async tasks never race on the
same key. Note: Time & Place as default means the home page now fetches weather on
connect when a location is set (async, TTL-cached) — previously that waited until
the tab was opened.

## 5. Contacts tab → comms hub; PR #10 merged (`bada073`, `fc60e49`)
The corner-widget Contacts tab became a three-column comms hub — **Contacts ·
Recent activity · Trusted senders** — after two mid-flight operator steers
(side-by-side, then the trusted list inline too). Contacts carry a trusted ✓ and
per-person actions: Text/Call (deliberately inert until outbound telephony
exists) and **Email**, which flips to the Chat sub-tab and prefills the composer
with "Please email <name> (<email>) with the following message:" via a new
`bc:chat_prefill` push handled by the AgentChat hook. Recent activity lists the
latest telephony events (name-resolved counterparty, direction mark, snippet,
relative time) and refreshes live off the telephony PubSub topic. The
add-a-trusted-sender input collapsed behind a "+ Add" toggle in the Contacts
header. PR #10 merged all of it plus the morning's work to main; the feature
branch was deleted.

## 6. SVG side rail → per-message modal link (`361a0fc`)
The persistent SVG viewer beside the chat is gone. A reply carrying ```svg
blocks now renders a "View drawing"/"View N drawings" link on its own bubble,
opening the existing full-screen modal (←/→ pages the conversation's drawings).
The subtle bug this fixed in passing: an SVG-only reply used to add NO bubble —
the drawing existed only in the rail — so it now gets a text-less bubble with
the link. Drawing ids thread through both the live stream and history reload.
SvgViewerDock hook deleted. **Workflow note (operator call, recorded in agent
memory): routine work now commits straight to main — no more feature-branch/PR
churn per change.**

## 7. The browser grew a tab sidebar (`4f215aa` + working tree)
The big one: browser tabs moved from the horizontal strip to a **left sidebar**,
Arc-style, while the app-tab system stays on top. The trick that made it one
webview instead of two: the chrome webview now covers the surface's ENTIRE box —
its HTML paints a full-width top block (app tabs → toolbar → bookmark row) and
the vertical tab sidebar; the content webview is created after it (NSView
sibling order = paint order) and permanently covers the chrome's center. Rust's
`content_box()` computes the inset; the CSS mirrors it as
`--sidebar-w: min(220px, 35vw)`, a lockstep invariant commented on both sides
and pinned by a controller test. Tab ergonomics (drag-reorder, middle-click
close, ephemeral/suspended styles, session restore) carried over untouched.

Follow-ups from the operator's first look, same session:
- **App-tab parity** — the chrome's app-tab chips were hazard-orange monospace
  pills; now they replicate the real TabStrip look (rounded-top chips on a
  base-200/80 strip, active chip merging into the toolbar; dark-theme tokens
  hardcoded since the chrome page has no Tailwind). A persisted "/" tab is
  filtered so the synthetic Home chip can't double up.
- **Bumper + ⌘B** (working tree at this update): a 14px full-height strip on the
  sidebar edge collapses/expands it (chevron + vertical "TABS" when closed), and
  ⌘B does the same via a new "Toggle Tab Sidebar" item in the native Tabs menu
  (menu accelerators fire regardless of webview focus). The chrome owns the
  preference (localStorage per surface, shield-toggle pattern); a new
  `browser_set_sidebar` command re-insets the content webviews from the surface
  box now cached in BrowserState — registered at all three ACL points
  (build.rs, capability, invoke_handler), the 07-17 lesson applied.

## Status at this update
- **Tests green throughout:** `1168 tests, 0 failures`; clean
  `compile --warnings-as-errors` + `cargo check`; `credo --strict` clean on all
  new/changed files.
- **Two LiveComponents now share the "embed a page as a sub-tab" pattern**
  (calendar, notes) — inline render + explicit `phx-target` + once-guarded init.
  A third surface would follow the same shape.
- **On main:** calendar sub-tab (`bcc68d4`), notes + widget (`685f3fc`),
  BusterPhone A2P doc reset (`4c5540d`), comms hub (`bada073`, merged via
  `fc60e49`), SVG modal (`361a0fc`), browser sidebar + app-tab parity
  (`4f215aa`), then the bumper/⌘B + this summary.
- **Real-app walk still owed** (operator hands, WKWebView): the browser
  sidebar's z-order + pixel alignment held up on first look; the bumper/⌘B
  toggle and a browser+browser split with the scaled sidebar remain unwalked.
