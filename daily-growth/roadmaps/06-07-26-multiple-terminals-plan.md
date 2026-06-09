# Multiple Terminals Plan

## Goal

Make Buster Claw support multiple live terminal workspaces so a user can:

- open more than one terminal as separate app tabs
- open split panes where either side can be a terminal
- keep each terminal attached to its own PTY session across tab switches
- close a terminal intentionally without killing unrelated sessions
- later let Dispatcher/Mailman-created work attach to a visible terminal session

This plan is for the user-facing terminal workspace. Headless agent execution can
continue through `BusterClaw.AgentRunner`; visible terminals should be an
operator surface, not the only way work runs.

## Current State

- The Tauri backend already supports many PTY sessions in
  `desktop/tauri/src/terminal.rs` through a `HashMap<String, Session>`.
- `terminal_open`, `terminal_attach`, `terminal_input`, `terminal_resize`, and
  `terminal_close` already operate by runtime session id.
- The frontend `TerminalView` hook already supports persistent browser-side
  session keys through `data-session-key`.
- `TerminalLive` currently hardcodes `data-session-key="main"`, so every
  terminal view reattaches to the same shell.
- `SplitLive` can embed `/terminal`, but because `TerminalLive` uses the same
  session key, two terminal panes would point at the same shell.

The core blocker is not PTY support. The blocker is the missing terminal
workspace model: unique terminal keys, labels, routes, split-pane params, and
close semantics.

## Design Principles

- A terminal tab is a view onto one PTY-backed session key.
- Session keys must be stable enough to survive LiveView unmount/remount and tab
  switches.
- Runtime PTY ids remain owned by Tauri; Phoenix/JS should track semantic
  terminal keys like `terminal:mail-triage:2026-06-07T20-12-00Z`.
- Closing a terminal tab should close only that terminal's PTY when the user
  chooses to close the terminal session, not merely when the LiveView unmounts.
- Split panes should embed terminal views using explicit session keys so
  `left=/terminal?...` and `right=/terminal?...` can be independent.
- Visible terminal sessions are local desktop state. Do not require database
  persistence for the first version unless a later feature needs cross-launch
  restoration.

## Proposed UX

### Terminal Tabs

- Add a "New Terminal" action in the tab/dock UI.
- Clicking it creates a unique terminal key, adds a tab labeled `Terminal 2`,
  and navigates to `/terminal?session=<key>`.
- The existing `/terminal` route keeps working and maps to the default
  `main` terminal.
- Tabs should display editable or generated names:
  - `Terminal`
  - `Mail Triage`
  - `Dispatcher`
  - `CI Fix`
- Closing a terminal tab should prompt or clearly choose between:
  - close the tab view only
  - terminate the shell session

For the first pass, use explicit close-session behavior only from inside the
terminal toolbar, while normal tab close only removes the tab view.

### Split Terminals

- A split URL can include terminal session keys:

  ```text
  /split?left=/terminal?session=mail-triage&right=/terminal?session=dispatcher
  ```

- Joining an existing terminal tab into a split should preserve its session key.
- Opening a brand-new terminal in the left or right pane should create a new key
  before rendering the pane.
- Resizing a split pane must resize the PTY independently for that pane.

## Implementation Phases

### Phase 1: Parameterized Terminal Sessions

- Update `TerminalLive` so the session key is not hardcoded.
- Support these sources, in order:
  - route/query param, for standalone `/terminal?session=...`
  - embedded LiveView session value, for split panes
  - fallback `"main"`
- Keep the existing `TerminalView` hook contract:
  - `data-session-key`
  - `data-cwd`
- Sanitize session keys for DOM/localStorage safety.
- Add a small terminal title assign derived from the session key or query label.

Acceptance:

- `/terminal` opens/reattaches the default terminal.
- `/terminal?session=a` and `/terminal?session=b` open independent terminals.
- Switching away and back reattaches to the correct session.

### Phase 2: Terminal Tab Creation

- Extend the tab/dock JS with a `New Terminal` action.
- Generate a stable key client-side, such as:

  ```text
  term-<timestamp>-<short-random>
  ```

- Add a tab path like:

  ```text
  /terminal?session=term-20260607-201512-a7f3
  ```

- Store tab label metadata alongside existing tab state.
- Keep `main` terminal as the default existing terminal tab.

Acceptance:

- User can open multiple terminal tabs.
- Each tab has separate scrollback and shell process.
- Closing one tab does not kill other terminals.

### Phase 3: Split Pane Terminal Params

- Teach `SplitLive` to pass each pane's query params into embedded LiveViews,
  not only the current `url` param used by Browser.
- For terminal panes, pass `terminal_session_key` and optional
  `terminal_label`.
- Ensure split pane child IDs include side plus terminal key where necessary to
  avoid LiveView identity collisions.

Acceptance:

- `/split?left=/terminal?session=a&right=/terminal?session=b` renders two
  independent terminals.
- A split of Terminal + Workspace works.
- A split of Terminal + Terminal works.

### Phase 4: Terminal Toolbar

Add a compact toolbar inside `TerminalLive` for visible terminal sessions:

- terminal label
- session status
- new terminal button
- split left/right actions
- close shell action
- copy session key action for debugging

Do not add explanatory onboarding text inside the app. Use concise labels and
tooltips.

Acceptance:

- Users can manage visible terminal sessions without touching localStorage.
- Shell termination is explicit and scoped to the current session.

### Phase 5: Dispatcher Integration

Once Dispatch and role sessions are wired:

- When Dispatcher claims a Dispatch item, choose a terminal session key from the
  Dispatch item or generated role session:

  ```text
  dispatch-<dispatch_id>-<role_key>
  ```

- Start a shift assignment with `shell` set to a visible terminal label.
- Open or offer a tab path for that terminal:

  ```text
  /terminal?session=dispatch-42-mail-triage&label=Mail%20Triage
  ```

- Do not make visible terminal opening the only execution path. Dispatcher can
  still create headless orchestrator tasks when the desktop UI is not active.

Acceptance:

- A Dispatch item can be associated with a terminal session key.
- The home shift panel can show the shell label.
- The user can open the corresponding visible terminal tab.

## Technical Notes

### Frontend

- `TerminalView` already persists Tauri PTY ids in localStorage using
  `bc:term:<sessionKey>`.
- The key change is to make `sessionKey` dynamic and routeable.
- Multiple xterm instances are already tracked in `liveTerminals`, so theme
  updates should propagate to all visible terminals.
- Keyless terminals currently close on LiveView destroy. Multi-terminal views
  should always use a session key.

### Tauri

- `TerminalState.sessions` already supports multiple sessions.
- First pass does not require new Rust state.
- Later useful additions:
  - `terminal_list`
  - `terminal_kill_all_except`
  - optional label metadata
  - launch command support for agent-specific bootstrap commands

### Phoenix

- `TerminalLive` needs either `handle_params/3` or session-driven assigns so it
  can receive `session` and `label`.
- `SplitLive` should preserve pane query strings and pass them to embedded
  children through `session`.
- Tests should assert rendered `data-session-key` values, not terminal process
  behavior.

## Test Plan

- LiveView/HTML tests:
  - `/terminal` renders `data-session-key="main"`
  - `/terminal?session=alpha&label=Alpha` renders key and label
  - split terminal panes pass distinct session keys
- JS/manual desktop smoke:
  - open two terminal tabs
  - run different commands in each
  - switch tabs and verify scrollback persists
  - split two terminals and verify both resize/input independently
  - close one terminal shell and verify the other remains alive
- Rust smoke:
  - existing terminal commands still compile
  - session close removes only the requested id

## Risks

- Query encoding for nested split URLs can be fragile. Use URI helpers and tests.
- Closing a tab versus closing a shell must be clear or users may kill work by
  accident.
- LocalStorage can point to stale Tauri ids after app restart. Current attach
  flow already handles missing sessions by opening a new one; keep that behavior.
- Two panes showing the same session key will mirror the same shell. That can be
  useful, but the UI should not accidentally create that state when the user
  asked for two terminals.

## Initial Build Slice

The first useful PR should be small:

1. Parameterize `TerminalLive`.
2. Update `SplitLive` to pass terminal params.
3. Add route/render tests.
4. Manually verify `/terminal?session=a`, `/terminal?session=b`, and split
   terminal URLs in the desktop shell.

After that, add tab/dock creation and toolbar controls.
