# Notes That Float UI Adoption Notes

This document summarizes how `websites/hightowerbuilds/notes-that-float` can inform Buster Claw's UI direction, with emphasis on the calendar and adjacent workspace layout patterns.

## Source App Summary

`notes-that-float` is a React 19 + TypeScript + Vite app. It uses TanStack Router, React Query, Zustand stores, Supabase data access, Three.js/react-three-fiber scenes, route-level CSS files, and component-scoped CSS files.

Buster Claw is a SolidJS + TypeScript + Vite frontend inside a Wails app. Direct component reuse is not practical because the source app is React. The reusable value is mostly in layout, state boundaries, CSS treatments, helper algorithms, and interaction models.

Key source files reviewed:

- `src/routes/calendar/index.tsx`
- `src/routes/calendar/hooks/-useCalendarPageController.ts`
- `src/features/calendar/hooks/useCalendarUI.ts`
- `src/features/calendar/hooks/useCalendarNav.ts`
- `src/stores/calendarUIStore.ts`
- `src/stores/calendarNavStore.ts`
- `src/stores/calendarControlsStore.ts`
- `src/features/calendar/components/CalendarControls.tsx`
- `src/features/calendar/components/CalendarControls.css`
- `src/routes/calendar/components/CalendarDesktopContent/-CalendarDesktopContent.tsx`
- `src/routes/calendar/components/CalendarSceneHost/-CalendarSceneHost.tsx`
- `src/components/CalendarViews/FlatCalendar/FlatCalendarView.tsx`
- `src/components/CalendarViews/FlatCalendar/FlatCalendarView.css`
- `src/routes/home/components/-HomeBottomNav.tsx`
- `src/routes/home/components/HomeBottomNav.css`
- `src/styles/variables.css`
- `src/styles/breakpoints.css`

## What Notes That Float Does Well

### 1. Page Architecture

The calendar page is not one large component. It has a thin route component, a controller hook, desktop/mobile content components, overlay components, controls, scene host, and view-specific calendar implementations.

For Buster Claw, this suggests moving the current calendar UI away from one large view file and toward:

- `features/calendar/CalendarView.tsx` as a route/view shell.
- `features/calendar/useCalendarController.ts` for derived state and actions.
- `features/calendar/CalendarMonthGrid.tsx` for the month surface.
- `features/calendar/CalendarInspector.tsx` for selected-day details and edit form.
- `features/calendar/CalendarSchedulerPanel.tsx` for cron jobs.
- `features/calendar/CalendarControls.tsx` for month navigation, shade, and view toggles.

### 2. Persistent UI State

`notes-that-float` stores calendar UI preferences separately from calendar navigation. It distinguishes:

- UI mode and toggles: view mode, shade, panel visibility, note font size.
- Navigation state: selected day, selected month, selected year.
- Menu state: which control menu is open.

Buster Claw can mirror this in Solid with local stores rather than Zustand:

- `frontend/src/features/calendar/calendarUiStore.ts`
- `frontend/src/features/calendar/calendarNavStore.ts`
- `frontend/src/features/calendar/calendarControlsStore.ts`

This would reduce pressure on `useAppController.ts`, which currently owns calendar form state alongside unrelated providers, hooks, memory, delivery, chat, and sources state.

### 3. Control Bar Pattern

The `notes-that-float` calendar uses a floating control bar with compact buttons and mode menus. The strongest reusable pattern is not the exact neon styling, but the interaction model:

- Fixed control rail near the viewport edge.
- Month/year picker separated from the main content.
- View mode group.
- Single active popover menu at a time.
- Outside-click and Escape handling for menus.

Buster Claw could adapt this to a quieter desktop-tool style:

- Top-left compact month/year selector.
- Top-right actions: `Today`, `Previous`, `Next`, `Shade`, maybe `Week`.
- Bottom-right or header-level actions for `Add Event`, `Run Job`, `Import`.
- One active menu at a time for calendar controls.

### 4. Flat Calendar Grid

The source `FlatCalendarView` is the most directly relevant piece. It uses:

- Generated empty cells before the first day of month.
- Seven-column grid.
- Separate weekday header.
- Day cells with `today`, `selected`, and `has-notes` states.
- Small markers/chips inside cells.
- Optional shade mode.
- Responsive mobile behavior that changes cell aspect ratio.

Buster Claw already has a month grid, but it can adopt this structure:

- Replace the current plain `month-day` button grid with a dedicated `CalendarDayCell`.
- Use event/job chips centered or stacked within the cell.
- Use marker dots when there are more items than can fit.
- Add a shade mode for readability over richer backgrounds.
- Keep a month bar independent from the right-side editor.

### 5. Overlay and Inspector Pattern

The source app uses full-surface overlays for notes, b-roll queue, icons, and timelines. The calendar notes panel uses a resizable two-column layout: sidebar directory, resize handle, main editor.

Buster Claw can reuse this concept for:

- Calendar selected-day inspector.
- Future Appearance page sections.
- Documents/report preview layout.
- A future two-column settings-and-preview workspace.

For the Appearance page idea, the same pattern maps cleanly:

- Left column: settings sections for `Terminal`, `Code Editor`, `Sketch`.
- Right column: live preview for the selected surface.
- Top control strip: page selectors.
- Persisted appearance state separate from the preview component.

### 6. CSS Organization

`notes-that-float` has global variables plus route/component CSS files. Buster Claw still has a large global `frontend/src/styles.css`.

Useful adaptation:

- Keep global tokens in `frontend/src/styles.css` or split to `frontend/src/styles/tokens.css`.
- Move calendar CSS to `frontend/src/features/calendar/CalendarView.css`.
- Move shared button/control primitives to `frontend/src/styles/controls.css`.
- Keep component-specific styles near their components.

## What Not To Copy

Do not directly copy these source app choices into Buster Claw without a product reason:

- React components or hooks as-is. They must be ported to Solid.
- Zustand stores. Solid stores/signals are enough for Buster Claw.
- Supabase data hooks. Buster Claw's calendar data lives behind Wails and Go.
- Three.js calendar scenes. Buster Claw is an operational research app; the calendar should become denser and more usable before adding 3D.
- Heavy neon styling everywhere. The source app leans expressive and atmospheric; Buster Claw should remain tool-like, calm, and scannable.
- Full-screen mobile dashboard behavior unless Buster Claw's mobile target becomes explicit. Wails desktop is the primary context.

## Buster Claw Current Calendar Gaps

Current Buster Claw calendar strengths:

- Calendar events are persisted locally through Go.
- Scheduled jobs already appear on the calendar.
- Event add/edit/delete works.
- The Home page already shows a weekly plan.

Current limitations:

- Calendar state is mixed into `useAppController.ts`.
- The calendar view combines month grid, event editor, selected-day detail, and scheduler table.
- The month grid is functional but visually flat.
- Event/job density is limited by simple text pills.
- Scheduler controls are visually separate from the calendar model.
- CSS is global and hard to reason about.

## Proposed Buster Claw Changes

### Phase 1: Calendar Structure Extraction

Goal: preserve behavior while creating clearer ownership.

Create:

- `frontend/src/features/calendar/useCalendarController.ts`
- `frontend/src/features/calendar/CalendarMonthGrid.tsx`
- `frontend/src/features/calendar/CalendarDayCell.tsx`
- `frontend/src/features/calendar/CalendarInspector.tsx`
- `frontend/src/features/calendar/CalendarSchedulerPanel.tsx`
- `frontend/src/features/calendar/CalendarControls.tsx`
- `frontend/src/features/calendar/CalendarView.css`

Move most calendar signals out of `useAppController.ts` into the calendar feature.

### Phase 2: Adopt Flat Calendar Interaction Model

Port the useful logic from `FlatCalendarView` into Solid:

- Generate month cells with leading empty cells.
- Compute `eventsByDate` and `jobsByDate` maps.
- Derive today and selected state.
- Represent dense content as chips and marker dots.
- Add `Shade` toggle.
- Add compact month/year controls.

Candidate logic to port:

- `generateCalendarDays`
- `CalendarDayCell` class state composition.
- Month/year menu behavior.
- `getMobileFlatCalendarChipLabel` concept, adapted as compact labels for job/event chips if needed.

### Phase 3: Workspace-Style Calendar Layout

Replace the current two-column month/editor layout with a more deliberate workspace:

- Header/control strip: month/year, today, previous, next, shade.
- Main surface: large month grid.
- Right inspector: selected date, events, jobs, add/edit event form.
- Lower section or collapsible panel: scheduler job table.

This keeps Buster Claw practical while borrowing the stronger spatial model from `notes-that-float`.

### Phase 4: Appearance Page Pattern

When building the Appearance page, use the same architectural pattern:

- Page selector buttons: `Terminal`, `Code Editor`, `Sketch`.
- Left settings panel.
- Right live preview.
- State object per surface.
- Preview components that do not mutate state directly.

Potential files:

- `frontend/src/features/appearance/AppearanceView.tsx`
- `frontend/src/features/appearance/useAppearanceController.ts`
- `frontend/src/features/appearance/AppearanceSurfacePicker.tsx`
- `frontend/src/features/appearance/AppearanceSettingsPanel.tsx`
- `frontend/src/features/appearance/previews/TerminalPreview.tsx`
- `frontend/src/features/appearance/previews/CodeEditorPreview.tsx`
- `frontend/src/features/appearance/previews/SketchPreview.tsx`
- `frontend/src/features/appearance/AppearanceView.css`

## CSS Direction For Buster Claw

Recommended token additions inspired by `notes-that-float`, adjusted for Buster Claw:

```css
:root {
  --surface-glass: rgba(0, 0, 0, 0.28);
  --surface-glass-strong: rgba(0, 0, 0, 0.46);
  --line-soft: rgba(255, 255, 255, 0.12);
  --line-active: rgba(120, 255, 160, 0.58);
  --text-glow: rgba(201, 255, 216, 0.88);
  --calendar-event: #4caf50;
  --calendar-job: #1e90ff;
  --calendar-today: #ff8c42;
}
```

Use these sparingly. Buster Claw should not become the same visual product. The best fit is a restrained terminal/workstation interpretation: sharper borders, darker translucent panels, compact typography, and clearer state colors.

## Suggested Reusable Code Concepts

Reusable after Solid port:

- Calendar day generation with leading blanks.
- Calendar cell state composition.
- Single active menu state.
- Outside-click/Escape menu dismissal.
- Month/year picker interaction.
- Two-column inspector/preview layout.
- Bottom or edge-aligned compact control bars.
- Dedicated mobile/desktop split if Buster Claw ever targets smaller screens.

Not directly reusable:

- React hooks/components.
- Supabase query hooks.
- Three scene components.
- Auth gates.
- Billing and b-roll flows.

## Implementation Order

1. Add a feature-local calendar CSS file and import it from `CalendarView.tsx`.
2. Extract `CalendarDayCell` from the existing month grid without behavior changes.
3. Extract `CalendarMonthGrid`.
4. Extract `CalendarInspector`.
5. Extract `CalendarSchedulerPanel`.
6. Add a compact `CalendarControls` strip.
7. Add shade and denser chip/marker rendering.
8. Move calendar-specific signals out of `useAppController.ts`.
9. Apply the same settings/preview architecture to the Appearance page.

## Risks

- The source app is React, so copy-paste reuse will produce the wrong abstractions in Solid.
- The source visual language is more atmospheric than Buster Claw's current operational UI.
- Moving state out of `useAppController.ts` should be staged to avoid breaking query invalidation.
- Calendar and scheduler data currently come from separate Wails APIs; the UI should preserve that separation unless the Go API is intentionally redesigned.
- Generated Wails bindings should not be manually edited during UI-only work.

## Recommendation

Use `notes-that-float` as a design and architecture reference, not as a dependency source. The highest-value first move is a Buster Claw calendar refactor that ports the flat grid layout, compact controls, and inspector panel pattern into Solid. After that, reuse the same left-settings/right-preview pattern for the Appearance page.
