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

## Gmail attachments → then full Google Workspace control

The evening thread, in two steps. First, **`gmail_send`/`gmail_draft_create` learned
to attach files** (`google/gmail.ex`, `commands.ex`): a `multipart/mixed` MIME
builder (RFC 2045 base64 line-wrapping, random boundary, extension→content-type
guessing) with a backward-compatible plain-text path for the no-attachment case.
Attachments are paths (workspace-relative via `Artifact.workspace_root()`, or
absolute) or `{path, filename, content_type}` objects; an unreadable file fails
**before** Google is called. Both send and draft flow through the same builder.

Then the big one: **the agent can now drive the entire Google Workspace.** The
catalog went **53 → 93 commands** (40 new), giving full read/write/delete across
Gmail, Calendar, Drive, Docs, Sheets, Slides, Contacts, and Tasks — all behind the
existing tier + gate guardrails. The architecture made this mostly pattern-repeat:
`Client` already took a per-call `base_url`, so each service is a thin wrapper.

- **Client extension** (`google/client.ex`). Factored token-refresh/401-retry into
  a shared closure, then added `patch_json`/`put_json`/`delete` (tolerates 204), a
  `decode: false` raw path (for Drive `alt=media` downloads + exports), and
  `upload/4` — a `multipart/related` media upload to `/upload/drive/v3` that
  bypasses JSON encoding while keeping the refresh path. The upload framing was the
  one genuinely new mechanism (and the most-tested).

- **Scopes** (`google/oauth.ex`). Swapped the 3 read-only scopes for the full
  8-scope Workspace set. Three are Google **restricted** scopes (`mail.google.com`,
  `drive`, `contacts`) → OAuth verification + the annual **CASA** assessment is now
  the distribution gate (accepted; doesn't block dev or the owner's account).

- **Service wrappers.** Extended `gmail.ex` (modify/trash/delete) and `calendar.ex`
  (create/update/delete events); new `drive.ex`, `docs.ex`, `sheets.ex`,
  `slides.ex`, `people.ex`, `tasks.ex`. Each returns `{:ok, summary_map}`; mind the
  per-endpoint method (Docs/Sheets/Slides mutate via POST `:batchUpdate`,
  Calendar/Tasks/People/Drive-metadata via PATCH).

- **Command surface** (`commands.ex`). 40 catalog entries + handlers. Reads `:safe`,
  writes `:restricted`, the **5 irreversible deletes** (`gmail_delete`,
  `gcal_event_delete`, `drive_delete`, `contacts_delete`, `tasks_delete`) are
  **gated**, and `drive_share` needs `confirm_share`. Drive download/export write
  into the workspace; upload reads from it. The generic catalog tests (handler
  exists per command, every gated command refused for `:agent_untrusted`)
  auto-cover the new surface.

- **Onboarding + reconnect UX** (`setup_live.ex`, `gws_live.ex`). Setup step 4 copy
  now names all 8 services and sets consent-screen expectations. The GWS page shows
  a **"Reconnect required — new permissions available"** badge (`missing_scopes?/1`
  compares granted vs. current defaults) so existing accounts re-grant — without it,
  writes silently 403 on stale read-only tokens.

- **New "quick chat" prompt** (`status_live.ex`). A one-click Get Started prompt
  that asks the agent to run `./buster-claw commands` and summarize the Google
  capabilities by service, flagging read-only vs. confirmation-gated actions — so
  the overview tracks the live catalog instead of hardcoding a list.

## Homepage polish — collapsible sections + a resizable chat

Small UX pass on the home panel (`status_live.ex`, `app.css`, `app.js`):

- **Collapsible Get Started + Quick chat.** The two blocks are now independent
  native `<details>`/`<summary>` collapsibles (own header button + a chevron that
  rotates open), `phx-update="ignore"` so LiveView never clobbers the open/closed
  state on re-render — no new server state, no JS, CSP-safe. New `.ic-collapse-summary`
  utility hides the default disclosure triangle and lays out label vs. chevron.

- **Container sizes to content.** The Get Started panel dropped `flex-1` for
  `flex flex-col max-h-full`, so it shrinks to just the two summary bars when both
  sections are collapsed (instead of force-filling the column), and caps + scrolls
  when expanded.

- **Drag-to-resize chat.** A grab handle on the chat panel's bottom border; the
  `AgentChat` hook drives a pointer-drag that sets the panel height live, clamped to
  [240px, 90vh] and persisted in `localStorage` (`bc:chat-height`). Re-applied in
  `updated()` (LiveView would otherwise drop the inline height on the next render)
  with a `dragging` guard so an incoming message can't snap the height mid-drag.

- **Bigger chat font.** Bumped the message bubbles, empty state, and input from
  `text-sm` (14px) to `text-[17px]` (+3px) for readability; left the mono tool-lines
  and meta footer at their caption sizes.

## GWS went live

The full Workspace surface is now serving from a freshly restarted dev server
(catalog 53 → 75). The connected account reconnected through the broader consent
screen — all **8 scopes granted** (`mail.google.com`, calendar, drive, documents,
spreadsheets, presentations, contacts, tasks), confirmed via `google_account_list`.
A live `gmail_search` works; `drive_list`/`tasks_list` still **403** because those
service **APIs aren't enabled in the Cloud project yet** (auth + scope are fine —
isolated by the passing Gmail control). Enabling Drive/Docs/Sheets/Slides/People/Tasks
in the console is the last operational step before the surface is fully usable.

## Web → Drive pipeline — binary-safe download

Closing the "go to a website, download a file, store it in Drive" chain. The Drive
half (`drive_upload`) already landed above; the missing piece was capturing **binary**
bytes — `browser_fetch` is a markdown extractor that discards the original file.

- **`Browser.download/2`** (`browser.ex`). An SSRF-guarded GET (reuses `URLGuard`)
  with `decode_body: false` so the bytes are preserved exactly as served (no
  markdown, no JSON/gzip decoding); never uses the Playwright sidecar (that renders
  pages); 100 MB cap; records an `:untrusted_ingest` Sentinel event. Derives the
  filename from `Content-Disposition`, falling back to the URL path.

- **`browser_download` command** (`commands.ex`, restricted/mutate). Writes the
  fetched bytes into `workspace/downloads/<date>/<filename>` (filename sanitized to
  a traversal-safe basename) and returns a workspace-relative `path` that
  `drive_upload` consumes directly. So the pipeline is now two composable, audited
  steps: `browser_download <url>` → `drive_upload path=<…>`. Kept as two commands
  (not a URL-streaming upload) so the bytes are preserved on disk and each leg is
  independently audited.

## Verification

- `mix test` — **530 tests, 0 failures** (was 481). New: `browser_download`/`Browser.download`
  (3 wrapper cases — raw bytes + `Content-Disposition` filename, URL-derived
  filename, blocked-URL refusal — and 2 command cases incl. an end-to-end write into
  a temp workspace proving the file lands where `drive_upload` reads it). Plus 41 across the Google
  service wrappers (`client_test`, `calendar_test`, `drive_test`, `docs_test`,
  `sheets_test`, `slides_test`, `people_test`, `tasks_test`, extended `gmail_test`),
  the catalog tier/gate cases in `commands_test`, and the new quick-chat prompt
  assertion. Highest-value cases: Drive multipart upload, 401-refresh-retry on the
  new methods, Sheets `valueInputOption`, People etag + `updatePersonFields`, 204
  deletes. Clean `--warnings-as-errors`.
- In-process catalog dump confirmed all 40 new commands with correct tiers + the 5
  gated deletes.
- **Still unverified by me:** the live Google round-trip (tests stub `Req`). Needs a
  real reconnect through the broader consent screen, then driving a few commands
  (`drive_list`, `tasks_list`, `sheets_get_values`) against a real account. The CLI
  reads `/api/commands` from the running server, so restart `mix phx.server` to see
  the new catalog.

## Earlier verification (chat build)

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
