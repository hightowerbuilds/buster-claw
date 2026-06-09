# 06-08-2026 Summary

## Today

### Terminal background transparency

- Investigated why the user-selected terminal background image was hidden when
  running full-screen TUIs such as Codex and Claude.
- Confirmed the terminal view already passed a transparent xterm theme when a
  background image was active, but that was not enough for TUI apps.
- Added a terminal output normalization step in `assets/js/app.js` for
  image-backed terminals:
  - strips ANSI black background paint from PTY output before xterm renders it
  - handles common black background forms like `40`, `48;5;0`, `48;5;16`, and
    truecolor black
  - preserves foreground colors and non-black background panels
  - keeps the filter streaming-safe for escape sequences split across PTY chunks
- Updated xterm initialization so `allowTransparency` is enabled before
  `Terminal.open()`, which xterm requires for transparent rendering support.

### xterm emulator black viewport fix

- Traced the remaining all-black terminal surface to xterm's own CSS:
  `.xterm .xterm-viewport { background-color: #000; }`.
- Added a `bc-terminal-bg-active` class toggle in the terminal LiveView hook so
  only image-backed terminal sessions get the transparency override.
- Added CSS overrides in `assets/css/app.css` for xterm's internal emulator
  layers:
  - `.xterm`
  - `.xterm-viewport`
  - `.xterm-screen`
  - `.xterm-screen canvas`
- Verified this applies both to standalone terminals and embedded split-pane
  terminals, where the shared split container paints the continuous background.

### Terminal Commands menu

- Planned and built a terminal-only Commands menu for role-specific CLI
  workflows.
- Started with a footer placement, then moved the control into the terminal
  toolbar beside the pane controls so it is tied directly to terminal usage.
- Added a dropdown menu for CLI-backed job roles, starting with Mailman.
- Added copyable Mailman commands for Gmail polling:
  - `./buster-claw mailman poll`
  - `./buster-claw mailman poll --once`
  - `./buster-claw mailman poll --interval 60`
- Added LiveView tests to verify the toolbar button, dropdown visibility,
  Mailman command content, copy controls, and close behavior.

### DataZone CLI launcher

- Fixed the issue where `./buster-claw mailman poll` failed from
  `/Users/lukehightower/Desktop/BusterClaw-DataZone` because the executable
  only existed in the app repo.
- Added `BusterClaw.WorkspaceCLI`, which installs a generated executable
  `buster-claw` launcher directly into the active DataZone.
- Wired the launcher install into app startup and workspace changes so installed
  users can run terminal commands from their own DataZone folder.
- Preserved the intended command UX: terminal commands remain relative
  (`./buster-claw ...`) while the launcher delegates to the real app CLI.
- Added safeguards so the app updates its own generated launcher but does not
  overwrite a user-owned `buster-claw` file.
- Added release support so packaged app installs can delegate through the
  bundled release binary.
- Created and verified the live DataZone launcher at
  `/Users/lukehightower/Desktop/BusterClaw-DataZone/buster-claw`.

### Mailman poller timeout fix

- Investigated a live Mailman poller run that reached Buster Claw but failed
  with `%Req.TransportError{reason: :timeout}`.
- Traced the failure to the CLI's hard-coded 5 second HTTP receive timeout,
  which was too short for Gmail sync work.
- Added a longer Mailman poll default timeout of 300 seconds while preserving
  the faster 5 second default for ordinary command calls.
- Added a `--timeout <seconds>` CLI option so long-running command calls can be
  tuned from the terminal.
- Rebuilt the `buster-claw` escript so the DataZone launcher uses the fixed CLI.

### Mailman poller readable output

- Replaced the default full JSON dump for `./buster-claw mailman poll` with a
  compact terminal summary.
- The poller now shows the synced count, account, query, mailbox match count,
  last sync timestamp, and saved Library document paths.
- Added `--verbose` as an escape hatch for the full JSON response when debugging
  is needed.
- Rebuilt the `buster-claw` escript so the DataZone launcher uses the readable
  output immediately.

## Verification

- `mix assets.build` passed after the JavaScript and CSS changes.
- Focused tests passed for terminal commands, workspace CLI launcher, terminal
  LiveView behavior, and workspace LiveView behavior.
- `./buster-claw help` works from
  `/Users/lukehightower/Desktop/BusterClaw-DataZone`.
- Production release CLI eval path was verified for packaged-app launcher
  support.
- `mix precommit` passed after the terminal command and DataZone launcher work
  with 351 tests and 0 failures.
- CLI-focused tests passed after the timeout change.
- `mix precommit` passed after the Mailman timeout fix with 354 tests and 0
  failures.
- `./buster-claw mailman poll --once --limit 1` succeeded from the DataZone and
  synced one Gmail document.
- CLI formatter tests passed after the readable output change.
- `./buster-claw mailman poll --once --limit 1` produced compact terminal
  output from the DataZone.
- `mix precommit` passed after the readable output change with 356 tests and 0
  failures.

## Notes

- The fix intentionally activates only when a terminal background image is set.
  Normal terminals keep their configured opaque xterm theme backgrounds.
- The final tracked files touched for this work were:
  - `assets/js/app.js`
  - `assets/css/app.css`
  - `config/runtime.exs`
  - `lib/buster_claw/application.ex`
  - `lib/buster_claw/cli.ex`
  - `lib/buster_claw/terminal_commands.ex`
  - `lib/buster_claw/workspace_cli.ex`
  - `lib/buster_claw_web/live/terminal_live.ex`
  - `lib/buster_claw_web/live/workspace_live.ex`
  - `test/buster_claw/cli_test.exs`
  - `test/buster_claw/terminal_commands_test.exs`
  - `test/buster_claw/workspace_cli_test.exs`
  - `test/buster_claw_web/live/terminal_live_test.exs`
