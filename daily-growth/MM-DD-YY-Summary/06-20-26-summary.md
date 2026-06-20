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

## Headless-Claude chat — a chat-like surface on the homepage

The afternoon thread: a real-time **chat column on the homepage** driven by the
same headless-Claude stream that powers the Autopilot TUI — so you can talk to the
agent (and have it drive `./buster-claw`) without opening the terminal. The TUI
proved the streaming spike; this redirects that stream from ANSI into Phoenix
PubSub → a LiveView. Plan lives in `roadmaps/06-20-26-headless-claude-chat-roadmap.md`;
built end-to-end across five phases.

- **Shared parser** (`agent/stream_event.ex`). Extracted the stream-json
  parsing/classification out of `tui.ex` into one tested module
  (`split_lines`/`decode`/`parse`/`normalize` + the `activity_state`/`activity_label`
  the starfield uses). `tui.ex` now delegates to it — one parser, no divergence;
  the existing TUI tests still pass unchanged.

- **Chat GenServer** (`agent/chat.ex`). Runs *inside the BEAM* (the escript can't
  broadcast into PubSub). **One short-lived `claude -p --output-format stream-json`
  run per message, threaded with `--resume`** (captures `session_id` from the
  stream → real conversation memory, no long-lived process). Serialized
  (`{:error, :busy}` while running), wall-clock timeout with kill, crash-safe.
  Added `AgentRunner.open/2` — a streaming-Port variant of the blocking `run/2`,
  so the chat reuses the login-shell/auth discipline (matters in the packaged
  `.app`). Injectable `:spawner` keeps the suite from launching a real `claude`.

- **Persistence** (`agent/message.ex`, `agent/transcript.ex`, migration). New
  `agent_chat_messages` table. Chat broadcasts **display-ready** `{:message, …}`
  entries (formatting — the `N turns · $cost` meta line, error copy — lives in one
  place) and persists them best-effort; `StatusLive` seeds the last 50 on mount,
  so a reload/restart reproduces the transcript.

- **Homepage column** (`status_live.ex`, `app.js`). Chat **replaces the calendar
  column** (calendar moved into the left panel stack); new `AgentChat` JS hook
  does autoscroll + Enter-to-send (Shift+Enter newline). Bubbles per role:
  user/assistant, monospace tool lines, faint meta footer, inline errors.

- Config flags `agent_chat_enabled` / `agent_chat_timeout_ms` / `agent_chat_persist`
  (all off/false in test).

## Homepage → chat-first, with a real Activity dashboard

The afternoon: reshape the homepage around the chat pathway and harden the one
number that was lying.

- **Chat-first homepage.** Get Started rewritten for the chat pathway (install
  Claude Code → chat), and the **Unattended Shift** panel + its StatusLive wiring
  removed (the Orchestration/Dispatcher backend stays — autopilot/queue still use
  it). Chat backend now **self-starts on demand** (`Chat.ensure_started/0` via
  `Supervisor.start_child`), so a dev refresh is enough — no server restart. Send
  path is crash-proof (catches a down backend → inline message, not a LiveView
  crash). New "Dev Server" terminal-command group (runs in the user's own
  terminal, `cd ~/Developer/buster-claw && …`).

- **Left column is now a tab strip** — Calendar · Pages · Contacts · Activity ·
  Get Started. All panels stay in the DOM (toggled `hidden`) so switching is
  instant and tests still see every panel. Chat sits alone in the right column.

- **Pages → Bookmarks.** The in-app browser's bookmarks render under Featured
  Pages; each opens the page in the Browser (`/browse?url=…`), with remove. Re-read
  on tab-open (added outside the LiveView).

- **Quick chat prompts** in Get Started — one-click buttons that fire a prompt
  into the chat (`quick_chat` → same path as typing): an intro/workspace
  walkthrough and a **Sentinel security layer** explain-and-exemplify prompt
  (explains tiers/gate, then runs commands that land on the audit feed).

- **Activity dashboard — anchored to the audit trail.** The old "This Week" panel
  showed a `Runs` number that only counted unattended Dispatcher runs → it read 0
  the moment we moved to chat. Fixed:
  - **Chat runs are now audited** — `Agent.Chat` records a `command_invoke`
    Sentinel event per run (completed/failed, with turns/cost/duration). Closes a
    real gap (chat spawns headless Claude with `bypassPermissions` and was
    previously invisible to Sentinel) and feeds an honest metric.
  - **New metrics** straight from the durable log: **Runs** (all headless runs,
    chat + unattended), **Commands** (audited command invocations), **Handled** /
    **Open** (dispatch queue). No snapshot table — aggregated on read so it can't
    drift.
  - **Daily / Weekly / Monthly** granularity toggle + a server-rendered **SVG bar
    chart** (CSP-safe, no JS lib): grouped Runs/Commands bars per bucket, zero-fill,
    period labels. `ActivityReport.timeline/2` groups by day in SQL and folds into
    the chosen grain in Elixir.
  - **Real-time across both pathways** — the panel subscribes to the Sentinel
    `security_alerts` feed *and* the Dispatch queue, so runs/commands/queue changes
    push a live refresh.
  - Config flag `agent_chat_audit` (off in test).

## Verification

- `mix test` — **481 tests, 0 failures**. New since the morning (446): the chat
  build — `stream_event_test` (26 incl. the migrated TUI cases), `chat_test` (5),
  `transcript_test` (3), `chat_persistence_test` (2), StatusLive chat/tabs/
  bookmarks/quick-chat cases; plus `ActivityReport.timeline` + commands-metric
  cases and the Dev Server terminal-command case.
- Clean compile under `--warnings-as-errors`; `mix assets.build` clean.
- **Chat round-trip now confirmed live** (real `claude -p`, in the running dev
  app) — the intro quick-chat prompt streams a real explanation end to end.
- Rust compiles clean (`cargo build` of the desktop crate).
- TUI scenes previewed via `mix run --no-start` (`Tui.frame/2`) to confirm the
  starfield + beam/streak motion render and align.
- **Still unverified by me:** the real `claude -p` chat round-trip (tests use an
  injected spawner). Needs a server restart (the new `Agent.Chat` supervised child
  isn't picked up by live-reload) + a manual message; ideally the packaged `.app`
  too, to exercise the login-shell auth path.

## Notes

- **8 commits unpushed** (`c3eeaf7` → `f9a0002`, plus this summary). Holding the
  push until the packaged app is confirmed working — no point pushing
  GUI-dependent fixes we haven't validated in the real `.app`.
- The Autopilot TUI ships in the **dev escript**; a DMG rebuild puts it in the
  packaged app.
- Test-the-packaged-app first step: `./buster-claw commands` in the in-app
  terminal. If it returns the catalog, the whole CLI path is wired; then try
  `./buster-claw autopilot`.
