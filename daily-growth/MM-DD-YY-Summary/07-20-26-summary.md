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

## Status at this update
- **Tests green throughout:** `1163 tests, 0 failures`; clean
  `compile --warnings-as-errors`; `credo --strict` clean on all new/changed files.
- **Two LiveComponents now share the "embed a page as a sub-tab" pattern**
  (calendar, notes) — inline render + explicit `phx-target` + once-guarded init.
  A third surface would follow the same shape.
- **Branch:** `feat/home-calendar-subtab` — calendar (`bcc68d4`), notes + widget
  (`685f3fc`), plus the BusterPhone A2P doc reset (`4c5540d`) and these docs.
- Unrelated to today but carried along: the operator's 07-18 A2P Direct
  Sole-Proprietor decision was committed as docs so nothing sat uncommitted.
