# 06-27-2026 Summary

Paused the voice STT roadmap and moved to the **Shortlist**. Added a new item
and built it: the homepage calendar widget is now a **Pro Tools–style CRT day
timeline** instead of a vertical agenda list.

## Shortlist

- Added **item #3 — "Homepage calendar widget — CRT horizontal day-timeline"**
  to `daily-growth/roadmaps/Shortlist.md`, capturing the goal, the data already
  available (`StatusLive` assigns `@daily_events`), and scope notes. Then
  implemented it the same session (below). Items #1 (Cmd-W closes tab not app)
  and #2 (rename joined tabs) remain open.

## Homepage calendar widget — CRT day-timeline

Replaced the vertical event list in
`BusterClawWeb.HomeWidget.daily_calendar_panel/1` (rendered by `StatusLive`,
embedded in `SplitLive`) with a horizontal, hour-gridded timeline.

- **Hour ruler** (`.ic-daygrid-ruler` + `.ic-ruler-cell`) — a flex row of
  equal-width hour cells, each drawing an hour tick (left border) and a
  half-hour tick (`::after`), with mono hour labels (`8a`, `9a`…) on top. Like a
  Pro Tools time ruler.
- **Hour sections + tracks** (`.ic-daygrid`) — alternating shaded hour columns,
  1px vertical hour rules on the seams, and horizontal track separators between
  stacked lanes. All three are layered background gradients.
- **Event regions** (`.ic-daygrid-block`) — translucent colored blocks
  positioned by `start_time` and sized by duration; overlapping events are
  assigned to separate tracks via greedy interval partition (`assign_lanes/1`).
  Each carries a Pro Tools clip-style title bar in the track color.
- **CRT look** — scanline overlay (`.ic-daygrid::after`) + translucent fills so
  the section ruling shows through. Reuses the existing `.ic-scanlines` CRT
  vocabulary. `prefers-contrast: more` drops the scanlines.

### Fluid fill

After the first pass (fixed 64px columns, height per lane, horizontal scroll),
reworked the geometry to **fill the card both axes**. `build_timeline/1` now
emits geometry as **percentages**: regions' `left`/`width` track their span, and
`block_style/2` splits the height evenly across tracks (`100% / track-count`).
The CSS ruling is driven by inline `--hour-w` / `--lane-h` custom properties, so
hour columns split the full width and tracks split the full height. The panel is
`h-full flex flex-col` (header fixed, timeline `flex-1`). Regions keep a
`min-width` floor so short events stay legible.

### Hover-to-reveal + all-day bars

- Region labels (name bar + time) start at `opacity: 0` and **fade in only on
  hover** — the timeline reads as clean colored blocks until pointed at. Text
  stays in the DOM (tooltips + screen readers + tests unaffected).
- **All-day events** (e.g. "Kyle's wedding") are now **full-width rectangle
  bars** above the grid (`.ic-daygrid-bar`) instead of pills, matching the
  region look and the same hover-to-reveal behavior. Dropped the now-unused
  `event_dot_class/1`.

## Verification

- `mix compile --warnings-as-errors` clean.
- `mix assets.build` (Tailwind/daisyUI) clean.
- StatusLive (13) + SplitLive (16) suites green — 29/29, including the test that
  asserts an event title + `09:30` render in the widget.
- `mix format` applied.

## Notes

- Two layout constants are pinned to the CSS with comments so the geometry can't
  silently drift; the rest is fully fluid (percentage-driven).
- The voice STT roadmap (`daily-growth/roadmaps/06-27-26-voice-stt-quality-
  roadmap.md`) and the in-progress `desktop/tauri/src/voice.rs` device-picker
  work are **paused**, left uncommitted, to be resumed later.
