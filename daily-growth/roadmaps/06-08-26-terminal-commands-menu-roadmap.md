# Terminal Commands Menu Roadmap

## Goal

Add a terminal-only **Commands** control to the footer dock so users can browse
approved role-specific CLI commands from inside a terminal tab.

The first target role is Mailman / Mail Triage. The menu should make the
existing Gmail polling workflow visible and reusable without turning the UI into
an arbitrary shell command launcher.

## Current State

- `TerminalLive` renders the terminal view and passes a startup command to the
  `TerminalView` hook.
- The only startup profile today is `mailman`.
- `mailman`, `mail-triage`, and `gmail-poller` role keys map to the `mailman`
  startup profile in `BusterClaw.TerminalWorkspace`.
- `TerminalLive` currently hardcodes the Mailman startup command:

  ```text
  ./buster-claw mailman poll
  ```

- The footer dock is owned by `BusterClawWeb.Layouts.app`.
- Embedded terminal panes in `/split` suppress their own app chrome, so the
  first version should target standalone `/terminal` tabs.

## Design Principles

- The Commands menu must be scoped to terminal surfaces.
- The footer button should not appear on Home, Workspace, Calendar, Settings, or
  other non-terminal routes.
- Commands shown in the menu must come from a whitelist, not user-provided text.
- Role commands should be centralized so startup profiles and the menu use the
  same source of truth.
- The first version should prefer insert/copy behavior over silent execution.
- Any future "run command" behavior must stay tied to an active terminal session
  and approved role command entry.

## Proposed UX

### Footer Dock

When the user is on a standalone terminal tab:

- Show a `Commands` button in the footer dock.
- Place it near the right side of the dock, before or near the theme toggle.
- Keep the control compact so it does not crowd the existing nav items.

When the user is not on a terminal route:

- Do not render the `Commands` button.

### Pop-Up Menu

Clicking `Commands` opens a pop-up menu with two levels:

1. Role list
   - Mailman / Mail Triage
   - Future roles only when they have approved CLI commands.
2. Command list for the selected role
   - Gmail polling loop
   - Gmail poll once
   - Any other explicit Mailman commands added later.

Each command row should show:

- short label
- concise purpose
- literal CLI command text
- a clear action button, initially `Copy` or `Insert`

Do not add instructional paragraphs inside the app. Use concise labels and
tooltips where needed.

## Command Catalog

Add a small centralized catalog, likely `BusterClaw.TerminalCommands`, with
shape similar to:

```elixir
%{
  role_key: "mailman",
  label: "Mailman",
  aliases: ["mail-triage", "gmail-poller"],
  commands: [
    %{
      key: "poll",
      label: "Poll Gmail",
      description: "Continuously sync Gmail through the local command API.",
      command: "./buster-claw mailman poll",
      default?: true
    },
    %{
      key: "poll-once",
      label: "Poll Once",
      description: "Run one Gmail sync and return.",
      command: "./buster-claw mailman poll --once"
    }
  ]
}
```

This catalog should be the only source used by:

- terminal startup profile resolution
- footer Commands menu rendering
- tests for role command availability

## Implementation Phases

### Phase 1: Centralize Terminal Role Commands

- Add `BusterClaw.TerminalCommands`.
- Model roles, aliases, command entries, and the default startup command.
- Move the Mailman startup command lookup out of `TerminalLive`.
- Keep the existing behavior unchanged:

  ```text
  startup_profile=mailman -> ./buster-claw mailman poll
  ```

Acceptance:

- Existing Mailman terminal startup still runs `./buster-claw mailman poll`.
- Unknown profiles return no startup command.
- Tests can assert Mailman role commands through one module.

### Phase 2: Terminal-Only Footer Button

- Add a boolean attr to `Layouts.app`, defaulting false, such as
  `terminal_commands`.
- Pass `terminal_commands` from standalone `TerminalLive`.
- Render a `Commands` button in the footer only when the attr is true.
- Do not render the button for embedded terminal panes.

Acceptance:

- `/terminal` renders the `Commands` button.
- `/`, `/workspace`, `/calendar`, and other non-terminal views do not.
- Existing footer nav behavior remains unchanged.

### Phase 3: Role and Command Pop-Up

- Render the role/command menu from `BusterClaw.TerminalCommands`.
- Start with Mailman / Mail Triage only.
- Use LiveView/HEEx and `Phoenix.LiveView.JS` or accessible popover/details
  markup.
- Avoid inline scripts.

Acceptance:

- Clicking `Commands` opens the pop-up.
- The Mailman role is visible.
- Mailman commands are visible with labels and literal command text.
- The menu can be closed without navigation.

### Phase 4: Command Action

Start with one of these actions:

- `Copy`: copies the CLI command to the clipboard.
- `Insert`: writes the command into the active terminal input without pressing
  Enter.

Recommended first pass: `Copy`, because it is simple and cannot accidentally run
work. `Insert` can follow once the active terminal session bridge is explicit.

Acceptance:

- User can copy a whitelisted Mailman command.
- No arbitrary command text is accepted from the DOM or URL.
- No command auto-runs in the first pass.

### Phase 5: Optional Terminal Insert / Run

If the UX needs more speed after the safe first pass:

- Add a focused `TerminalCommands` browser hook or event bridge.
- Route a selected whitelisted command to the mounted `TerminalView`.
- Support insert-only first.
- Consider explicit run behavior only with a clear action label.

Acceptance:

- Inserted commands go only to the active terminal view.
- Commands still come from the server-side catalog.
- There is no free-form shell execution pathway through the footer menu.

## Test Plan

- Unit test `BusterClaw.TerminalCommands`:
  - lists Mailman role
  - resolves aliases `mail-triage` and `gmail-poller`
  - returns the default Mailman startup command
  - returns nil/error for unknown role/profile

- LiveView tests:
  - `/terminal` renders the `Commands` footer button
  - non-terminal routes do not render the button
  - menu contains Mailman role and Gmail polling command

- Existing regression tests:
  - `TerminalLive` still exposes `data-startup-command="./buster-claw mailman poll"`
  - `terminal_tab_open` still maps `mail-triage` to `startup_profile=mailman`

## Open Questions

- Should the first click action be `Copy` or `Insert`?
- Should `/split` show a top-level Commands button when either pane contains a
  terminal, or should that wait until split-pane active terminal focus is
  explicit?
- Should roles be named by operator role (`Mail Triage`) or startup profile
  (`Mailman`) in the user-facing menu?
- Should command entries support arguments later, or should variants stay as
  separate explicit whitelist entries?

## First-Pass Recommendation

Build the first version as:

- standalone terminal only
- server-side whitelisted command catalog
- Mailman role with `poll` and `poll --once`
- footer `Commands` button
- pop-up menu
- copy action only

That gives users the visible command surface immediately while keeping terminal
execution boundaries conservative.
