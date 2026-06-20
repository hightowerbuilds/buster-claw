# 06-20-2026 Summary

Two threads: **hardening the packaged app** (running the real `.app` exposed a
chain of packaged-environment bugs that were invisible in dev) and a new
**Autopilot TUI** — a space-themed ASCII starfield that animates what the headless
agent is doing. Seven commits on top of the always-on build; suite green at 446.

## Packaged-app hardening (the `.app` finally talks to itself)

Building and running the DMG surfaced that the **terminal → CLI → server path was
never wired end to end** in a packaged install. Dev hides all of it (`:4000`
matches, token's in `.env`, the launcher is a plain escript), so none of it
showed until the real bundle ran. Fixed, in order found:

- **Headless runs reach the app** (`dispatcher.ex`, `agent_runner.ex`,
  commit `c3eeaf7`). The release serves Phoenix on a random private port, but a
  spawned run's `./buster-claw` defaulted to `:4000`, and `/bin/sh -c` gave it a
  bare GUI env. The Dispatcher now sets `BUSTER_CLAW_URL` (the real port, read
  from config) in the run env, and `AgentRunner` gained `:shell`/`:login` so the
  Dispatcher runs through the user's login shell (`$SHELL -lc`) for PATH/auth —
  the same trick `terminal.rs` uses. Defaults stay `/bin/sh -c` so tests are
  hermetic.
- **`dev.sh` clears `resources/release/`** (`97328e4`). After `build_desktop.sh`
  stages the full ERTS release there, `cargo tauri dev` dies with
  `failed to run tauri-build: Permission denied` while `tauri-build` scans the
  tree. Dev never uses the bundle, so `dev.sh` now clears it back to `.gitkeep`
  first (documented in BUILD.md).
- **Release launcher syntax bug** (`workspace_cli.ex`, `91bd5c8`). The packaged
  `./buster-claw` evals `case System.argv() do … end`, but generated it by
  collapsing the multi-line `case` to spaces — invalid Elixir, so **every**
  packaged CLI call died with a `SyntaxError`. `@release_eval` is now a single
  valid line (`;` between clauses) and the launcher no longer collapses newlines.
  Regression test forces the release target and asserts the embedded eval parses.
- **Terminal wiring** (`main.rs`, `terminal.rs`, `a1f6054`). The in-app terminal
  set `TERM`/`LANG` but never `BUSTER_CLAW_URL`/`BUSTER_CLAW_API_TOKEN`, so its
  `./buster-claw` was blind: wrong port, and the token lives in the Keychain
  (which the CLI can't read). `main.rs` now exports both into the process env and
  `terminal.rs` forwards them into the PTY. Dev unaffected (those come from `.env`).

Three DMG rebuilds over the session; the current bundle carries the whole chain.
**Caveat (still unverified by me — needs the running GUI):** these are packaged
fixes I can compile and test in Elixir/Rust but can't drive in the actual app.

## Autopilot — one command, in the terminal, visible

- **Autopilot command category** (`terminal_commands.ex`, `66a60b0`). A new
  "Autopilot" group in the terminal Commands menu: a single command that polls
  trusted mail and runs headless Claude on the queue, in the terminal where you
  can watch it (not the invisible Dispatcher-button path). The user steered us
  here — the unattended-shift button felt like "just a button," and the honest
  model for how they work is one visible terminal command.

- **Autopilot TUI** (`autopilot/tui.ex` + `cli.ex` verb, `5c522ff` → `f9a0002`).
  `./buster-claw autopilot` wraps a headless Claude pass and renders a small
  **space-themed ASCII animation** of what the agent is doing, by parsing
  Claude's `--output-format stream-json` events into states:

  | event | state | the sky |
  |---|---|---|
  | `system/init` | booting | fast sparkle |
  | assistant text / `user` tool_result | waiting | gentle twinkle |
  | `Read`/`Grep`/`Glob` | reading | a bright column sweeps across (scan beam) |
  | Bash `gmail`/`mailman`/`dispatch list` | email | star-streaks drift **left** |
  | `Write`/`Edit`/`gmail_send`/`dispatch done` | writing | streaks drift **right** |
  | `result` | done | steady dense field |

  First cut used ASCII objects (rocket, inbox, transmitter); per feedback it's now
  **pure stars** — procedural per-cell from stable position-noise + frame, so each
  state is readable from the starfield alone. `classify/2` (event → state) is pure
  and unit-tested; the scenes are plain data (`cell/4`) — easy to tune.

## Verification

- `mix test` — **446 tests, 0 failures**. New: AgentRunner login-shell + run-env
  (`BUSTER_CLAW_URL`, login), WorkspaceCLI release-eval regression, Autopilot
  Commands category, Autopilot TUI `classify/2` (11).
- Rust compiles clean (`cargo build` of the desktop crate).
- TUI scenes previewed via `mix run --no-start` (`Tui.frame/2`) to confirm the
  starfield + beam/streak motion render and align.

## Notes

- **8 commits unpushed** (`c3eeaf7` → `f9a0002`, plus this summary). Holding the
  push until the packaged app is confirmed working — no point pushing
  GUI-dependent fixes we haven't validated in the real `.app`.
- The Autopilot TUI ships in the **dev escript**; a DMG rebuild puts it in the
  packaged app.
- Test-the-packaged-app first step: `./buster-claw commands` in the in-app
  terminal. If it returns the catalog, the whole CLI path is wired; then try
  `./buster-claw autopilot`.
