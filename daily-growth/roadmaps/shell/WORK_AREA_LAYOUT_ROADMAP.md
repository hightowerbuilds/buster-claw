# Work Area grid and overlap roadmap

**Implemented 2026-10-17. Native desktop acceptance walk remains open.**

Add a visible **Grid / Overlap** toggle to the layout controls. Grid keeps the
current panel arrangements. Overlap lets users drag panels by their headers and
leave them overlapping at arbitrary positions. Each Work Area holds at most
four open panels. Opening a fifth creates and selects a new top-level tab named
exactly **Work Area 2**; further full areas produce **Work Area 3**, and so on.

This extends the shipped [terminal panel work](TERMINAL_PANELS_ROADMAP.md).
Its arrangements for five or more panels and fixed pool of four terminal
slots are replaced by four-panel areas and independently numbered terminals.

## Implementation status

Phases 1–4 are implemented. `WorkAreas` owns allocation, membership and naming;
`WorkAreasRestore` validates v2 storage and migrates v1 layouts. The existing
`WorkbenchState` remains the grid engine. Ordered area records and stable panel
keys provide identity without a separate panel registry. Terminal keys retain
the existing `workbench` / `workbench-N` session contract. The collection is
bounded at 64 areas, with a visible notice when it is full.

Browser checks cover fifth/ninth-panel overflow, retained Chat drafts and DOM
hosts, actual pointer dragging, keyboard move/commit/cancel, mode round trips,
narrow/wide presentation, reload, background-area close, and Settings return.
Model, LiveView and JavaScript tests cover migration, stable child processes,
area identity, native chip projection and stale gesture updates.
`mix precommit` and `mix assets.build` pass, including the complete Elixir and
JavaScript suites, cycle and file-size gates, and Rust checks. The final browser
acceptance run reported no runtime errors.

Still required in the native desktop app: verify real PTY continuity, busy
terminal cancellation/close from both tab surfaces, native shortcuts, terminal
focus/refitting and native browser navigation. Browser checks cannot establish
those behaviors. Free edge resizing and moving panels between areas remain
outside this release.

## User behavior

| Action | Result |
|---|---|
| Start with a fresh layout | The first tab is **Work Area**, with Chat open and Grid selected. |
| Select Overlap | The same panels become movable windows on the current canvas. |
| Drag any panel header | That panel follows the pointer and stays where it is dropped. Other panels keep their positions. |
| Click a partially covered panel | It becomes active and moves to the front. |
| Switch back to Grid | The previous grid arrangement returns, with the current set of panels. |
| Return to Overlap | The saved positions and stacking order return. |
| Open a new panel when the current area has three panels | It becomes that area's fourth panel. |
| Open a fifth panel in the first area | Create **Work Area 2**, open the requested panel there, select the new tab, and focus the panel. The original four stay together. |
| Continue opening new panels in Work Area 2 | Fill its remaining three places; the next new panel creates **Work Area 3**. |

### Implemented defaults

These resolve details beyond the requested toggle and overflow behavior:

- The four-panel limit applies in **both modes** and counts open panels,
  including panels hidden by maximize or covered by another panel. A hidden,
  closed panel that remains mounted for continuity does not count.
- Mode belongs to each area. A newly created area inherits the originating
  area's mode. The first area defaults to Grid.
- Non-terminal panels remain singletons across the work areas. Opening an
  already open Notes, Chat, or other singleton selects its owning area and
  focuses it, without creating another tab. A hidden singleton reopens in the
  current area, subject to capacity.
- Terminal creation always creates a new terminal instance. Four becomes the
  **total panel capacity per area**, replacing the old four-terminal pool for
  the whole workbench. A fifth terminal therefore opens in a new area when the
  current one is full. Every instance has its own persistent session key.
- Check the **current area's** capacity. Do not move users to an older area's
  spare slot. Closing a panel leaves space in its area; areas do not compact or
  renumber automatically.
- Keep the first tab named **Work Area**. Allocate subsequent default names
  from a persisted, increasing number. Labels and user renames never identify
  an area; closing or renaming Work Area 2 must not rename Work Area 3.
- Keep grid presets inside Grid mode. The existing `preset: "grid"` means
  Balanced split; the new `mode: "grid"` describes the whole tiled mode.
- Initial Overlap includes movement, stacking, maximize, and restore. Free
  edge resizing and dragging panels between areas can follow separately.

## Starting implementation and change points

This records the baseline inspected before implementation. Paths below are
relative to the repository root.

| Code | Current behavior and implication |
|---|---|
| `lib/buster_claw_web/workbench_state.ex` | One state with `tree`, `active`, `zoom`, and `preset`. All open panel keys live in a split tree. `open/2` has no total-panel cap; `open_terminal/1` allocates one of four fixed slots. Add an area collection and enforce capacity centrally. |
| `lib/buster_claw_web/workbench_hook.ex` | Owns restore, open, focus, close, layout, reorder, and resize events. `workbench_mounted` retains opened content. Extend this owner to area selection and allocation. |
| `lib/buster_claw_web/live/status_live.ex` | Hosts the panel contents, including four terminal children. Render terminal instances dynamically while preserving existing singleton hosts and the Notes update relay. |
| `lib/buster_claw_web/components/workbench.ex` | Provides stable pane frames, header controls, and `layout_picker/1`. Add the mode toggle here and retain stable DOM identities. |
| `assets/js/lib/workbench.js` | Computes grid geometry and persists one layout under `bc:workbench:v1`. Add separate overlap geometry and a versioned migration. |
| `assets/js/hooks/workbench.js` | Header drag currently relabels tree leaves to reorder slots. Add a distinct overlap interaction; preserve grid reordering. |
| `assets/css/workbench.css` | Panes already use absolute rectangles through `--pane-*` variables. Extend positioning with stacking and mode styling. Below 560 canvas pixels, the hook selects a stacked layout. |
| `assets/js/hooks/tab_strip.js`, `assets/js/lib/tabs.js` | Tabs are saved under `bc:tabs`. `currentKey()` collapses every root URL into `/`; area query parameters alone will not create distinct tabs. |
| `assets/js/lib/chrome_app_tabs.js`, `chromeChips()` in `tabs.js` | The native browser has a separate app-tab row. Its current filter removes every root-path tab before inserting one Work area chip. It must retain additional areas. |
| `assets/js/hooks/terminal.js` | Keyed PTYs survive unmounts; explicit `closeSession()` ends them. Area switching must preserve sessions, and area closing must target only its own terminals. |

Two existing constraints shape the implementation. First, a prior LiveView
patch stripped panel geometry and caused one panel to cover everything. Keep
the pane `JS.ignore_attributes(["style", "class"])` protection, protect any new
hook-owned presentation attributes, and keep the ignored controller/divider
nodes separate from server-rendered panel content.

Second, `StatusLive` is also a child of `SplitLive` and deliberately has no
`handle_params/3` callback. Area switching needs live URL patches without
breaking that embedded host. Attach a parameter hook **only on router-mounted
instances**, using the existing `WorkbenchHook` boundary. The installed
LiveView lifecycle supports parameter hooks without an exported callback;
embedded instances must never receive that hook.

## State and persistence design

Introduce an area collection around the existing layout state. Keep the model
pure and validated in Elixir; extract collection/allocation logic into a small
module if keeping it in `WorkbenchState` obscures the grid operations.

| Record | Fields and invariant |
|---|---|
| Workbench | `version`, `active_area_id`, `area_order`, `areas`, `panels`, `next_area_number`. Area IDs are stable and independent of tab order. |
| Area | `id`, default number/custom label, `mode`, ordered panel IDs, `active`, `zoom`, grid tree/preset, overlap frames, and back-to-front panel order. At most four open panels. |
| Panel | Stable ID and kind; terminal instances additionally carry their label and session key. A panel belongs to at most one open area. |
| Overlap frame | Finite, normalized `x`, `y`, `width`, and `height`, relative to the canvas. Validate and clamp on the server and again when projecting into viewport pixels. |

Grid tree leaves and overlap stacking entries must match area membership.
Opening or closing a panel updates both representations. Moving a panel in
Overlap must not rewrite the saved grid tree. Keep stacking as an ordered list
of panel IDs, deriving bounded z-index values when drawing.

On first entering Overlap, seed readable, slightly staggered frames with
reachable headers. Store later positions independently. Clamp frames on resize
so windows cannot be lost outside the canvas. At narrow widths, use the existing
stacked presentation in either mode, disable free dragging with a visible
explanation, and retain the chosen mode and overlap coordinates for widening.

Use `bc:workbench:v2` as the durable layout record. The area model owns area
identity, membership, and layout; `bc:tabs` remains the tab-strip projection.
Write the validated layout before publishing a new tab. Restore/reconcile the
tab projection from area state so an interrupted write cannot leave an empty
or duplicate Work Area tab. Preserve unrelated tabs and user tab ordering.
If storage is unavailable, keep the session usable in memory and surface that
the arrangement cannot be saved.

Migration must be repeatable and preserve the original v1 record. Validate and
prune retired keys using today's rules, then partition existing tree leaves
in order into groups of four. Preserve exact divider ratios for layouts that
already fit. For larger layouts, regenerate each group's grid arrangement and
keep focus on the area containing the previously active panel. Preserve a
valid maximized panel in its owning area. Carry existing terminal session keys
(`workbench`, `workbench-2`, etc.) unchanged so migration reattaches to the same
shells. New terminals get unique keys that do not depend on the area's number
or the terminal's position.

Validate restore payload sizes, area count, membership, IDs, modes, frames,
and terminal keys. Reject forged references and normalize stale focus/zoom.
Choose an explicit resource bound during implementation and show a clear limit
message if reached; do not silently discard saved panels.

## Implementation phases

### Phase 1 Model areas and enforce four panels

- [x] Add area allocation, selection, membership, naming, and per-area layout
  state. Route every open path through one allocator: sidebar, empty-state
  action, deep link, Chat handoff, terminal button, and Command-T.
- [x] Detect an already open singleton before checking capacity. For a new
  panel, create the area and panel in one validated state transition. Never
  seed a new overflow area with an extra Chat panel.
- [x] Replace fixed terminal allocation with instances and stable session keys.
  Keep the existing standalone/CLI terminal route contract separate.
- [x] Implement v1 migration and v2 validation, including layouts with more
  than four panels. Replace tests that currently expect five panes in one grid.

**Done when:** panels 1–4 share the first area, panel 5 creates Work Area 2,
panels 6–8 fill it, and panel 9 creates Work Area 3, including when every panel
is a terminal. Repeated singleton opens never consume another place.

### Phase 2 Integrate real Work Area tabs

- [x] Introduce a canonical area URL such as `/?area=<stable-id>`; preserve `/`
  as the first-area alias. Exclude transient `panel` and `ask` parameters from
  tab identity, while retaining their existing actions.
- [x] Share area-aware identity/destination helpers between `currentKey()`,
  tab sync, labeling, renaming, native browser chips, and app-tab snapshots.
  Reconcile all restored areas into both tab rows.
- [x] Use LiveView patches for switches between areas in the mounted workbench.
  Add the root-only parameter hook and defer area selection until restore has
  supplied the saved collection. Full navigation from Settings or Browser
  restores the requested area; unknown area IDs fall back without creating
  empty areas. Verify Back/Forward and reload.
- [x] Keep one stable set of panel hosts across the area's lifetime. Switching
  areas changes visibility and focus; it does not recreate editors, chat
  streams, or terminals. Dynamic terminal hosts need stable IDs and stream
  handling consistent with the project's LiveView collection rules.
- [x] Make Command-T from another app destination target the last active area
  through the existing one-shot request, after restore completes. Preserve its
  duplicate-event guard. Keep Command-1/2/3 as Work Area / Settings / Browser;
  Command-1 returns to the last active area, and Browser Command-T stays local.
- [x] Define area-tab close consistently in both tab rows. Proposed behavior:
  pin the first area; closing a secondary area hides its singleton panels and
  explicitly closes its terminals after the existing busy confirmation. Cancel
  leaves everything intact. Do not auto-delete an area when its last panel
  closes. Never renumber remaining areas.
- [x] Make close checks area-specific. The current mounted-terminal registry
  assumes only the active route owns terminals, which stops being true with
  retained inactive areas. Closing from Settings or native Browser must also
  resolve that area's saved session IDs through the main app's close handler.
- [x] Audit join/separate and existing saved `/split` routes. Preserve existing
  embedded Work Area support and pass its area identity through the child
  session. Block joining two Work Areas in the first release unless their
  controllers, storage ownership, and DOM IDs have been isolated and tested.

**Done when:** Work Area 2 is a distinct, selectable tab in both surfaces;
switching areas preserves child identities and shell sessions; a close affects
only the chosen area. Tab storage and layout storage agree after reload.

### Phase 3 Add Grid and Overlap controls

- [x] Add labeled Grid and Overlap buttons beside the existing layout picker,
  with stable IDs, keyboard focus, `aria-pressed`, and the house `ic-` styling.
  Disable the controls outside a Work Area. Show grid presets only in Grid.
- [x] Add a validated mode-change event and overlap geometry helpers. Project
  the same pane hosts into rectangles; remove grid dividers in Overlap.
- [x] Preserve each mode's layout on toggles and each area's selected mode.
  Maximize/restore must preserve the underlying frame and stacking order.
- [x] Add reduced-motion behavior and the narrow-canvas fallback without
  overwriting saved positions.

**Done when:** toggling either direction preserves panel content and restores
the corresponding arrangement, including after switching tabs and reloading.

### Phase 4 Implement free movement and stacking

- [x] Dispatch header gestures by mode. Keep today's reorder behavior in Grid;
  in Overlap move only the dragged panel and bring it to the front. Allow a
  single panel to move too. Buttons and panel content must not start drags.
- [x] Use pointer capture and a small movement threshold. Draw locally during
  the gesture, committing the final frame once on release. Escape,
  `pointercancel`, or lost capture restores the starting frame.
- [x] Include area ID, panel ID, and a state revision in commits. The current
  hook drops sync events during drag; retain/reconcile newer updates so a mode
  switch, panel close, area switch, or reconnect cannot revive stale geometry.
- [x] Bring panels forward on pointer and keyboard focus. Provide a keyboard
  move action with arrow-key movement and Escape to cancel, plus a way to
  reset an area's positions. Keep all panel headers recoverable.
- [x] Fit terminals when their visible size changes and when an inactive area
  becomes visible. Avoid hidden terminal mounts stealing focus.

**Done when:** panels can overlap and stay put, focus follows the chosen panel,
and chat updates, terminal output, reconnects, and resize do not reset geometry.

### Phase 5 Validate and document the new behavior

- [x] Extend `test/buster_claw_web/workbench_state_test.exs` for allocation,
  migration, independent modes, validation, close/reopen, and stable numbering.
- [x] Extend `test/buster_claw_web/live/workbench_live_test.exs` and the Notes /
  Calendar tests for overflow, mode controls, and stable child PIDs. Add focused
  area tests rather than growing one file indefinitely.
- [x] Extend `assets/js/lib/workbench.test.js` and `tabs.test.js` for geometry,
  migration, tab identity, labels, and native browser chips. Add interaction
  coverage for drag cancellation, stale updates, and area-specific closing.
- [x] Exercise `SplitLive`, app-tab join/separate tests, browser-page Ask in
  Chat, and standalone terminal commands to protect the existing entry points.
- [ ] Walk the actual desktop app for native tab chips, busy terminal close,
  Command-T, pointer capture, and terminal focus/refitting. Browser-only tests
  cannot establish PTY behavior.
- [x] Update the user guide and affected onboarding/explained text after the
  feature ships. Run `mix precommit` and fix failures. Respect the current file
  size gates by extracting helpers where needed.

## Acceptance walk

1. Start with Chat; open Workspace, Notes, and Calendar. Confirm four panels
   and one tab. Open Terminal: confirm **Work Area 2**, one terminal there,
   and the original four still in Work Area.
2. Open three more terminals in Work Area 2. Open another: confirm **Work Area
   3** and a fifth independent shell across the areas.
3. Select Notes from Work Area 3. Confirm the first area is selected and the
   same note remains open, without another panel or tab.
4. In an area with several panels, select Overlap, cover part of one panel,
   click it to bring it forward, and drag a different panel. Confirm the other
   positions stay fixed. Test keyboard movement and cancelled drags.
5. Toggle Grid, then Overlap. Switch areas, visit Settings and Browser, return,
   and reload. Confirm membership, mode, positions, stacking, and tab names.
6. Stream a Chat reply and run a terminal command during movement and area
   switching. Confirm content stays live, panel geometry stays intact, and
   terminals do not steal keyboard focus.
7. Resize narrow and wide; maximize and restore. Confirm no panel is lost and
   the saved overlap arrangement returns.
8. Close a secondary area with a busy terminal from each tab surface. Cancel
   first, then confirm. Verify only its sessions close, other areas keep their
   names, and the next area uses the next number.
9. Restore a v1 layout containing more than four panels and live keyed
   terminals. Confirm ordered groups of four and unchanged session keys.
   Repeat restore to confirm it creates no duplicates.
