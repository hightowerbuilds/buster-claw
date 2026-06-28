# Shortlist

A running list of small, high-priority fixes and features to pick up.

## Items

### 1. Cmd-W should not close the whole app

**Problem:** With a single tab open, pressing **Cmd-W** closes the entire
application. Cmd-W should only ever close a tab.

**Desired behavior:**
- **Cmd-W** closes the current tab only.
- If the last remaining tab is closed, the app should *not* quit — keep the
  window open (e.g. fall back to an empty/home tab) instead of terminating.
- **Cmd-Q** is the only shortcut that closes the app.

### 2. Right-click on joined tabs to rename

**Problem:** Joined tabs can't be renamed.

**Desired behavior:**
- Right-clicking a joined tab opens a context menu with a **Rename** option.
- Selecting it lets the user edit the tab's label inline.
- Need to figure out the rename logic (where the tab label is stored, how it's
  persisted, and how it propagates to the UI).

### 3. Homepage calendar widget — CRT horizontal day-timeline

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
