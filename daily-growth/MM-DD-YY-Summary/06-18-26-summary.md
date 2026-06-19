# 06-18-2026 Summary

The always-on day. Starting from a business-fit review of the app, designed and
built an entire **unattended ("always-on") shift** subsystem end to end: Buster
Claw can now work its own Dispatch queue with headless `claude`/`codex` runs — no
human in the terminal — with provenance-based safety gating, a token budget, an
operator surface, a value report, and durable resume across restarts. 13 commits;
the test suite went **412 → 435**, green. (Begun the evening of 06-17; the bulk
landed today.)

## Business-fit review + roadmap (`daily-growth/`)

- `roadmaps/06-17-26-business-fit-review.md` — reviewed the app as a prospective
  business user: strengths (auditability, injection-aware trust, BYO-agent/no-key,
  data posture), the central tension (it demands terminal fluency + macOS + Gmail),
  who struggles (segmented by *structural gates*, not skill), and a ranked
  "remove-the-gate" priority. The #1 gap — single-machine, supervised-only — became
  this build.
- `roadmaps/06-17-26-always-on-shift-roadmap.md` — the plan. Settled the key design
  decision in discussion: **the agent is autonomous/trusted by default ("do a lot
  without asking"); the one guardrail kept is untrusted-input → outbound/irreversible
  action.** Keyed on provenance (the dispatch item's existing `trusted`/`auth_status`),
  not nag-prompts.

## Phase 0 — `AgentRunner` (`lib/buster_claw/agent_runner.ex`)

- Headless one-shot run primitive: spawns the user's own agent CLI non-interactively
  via a `Port` (`/bin/sh -c 'exec "$@" 2>&1'`), in the workspace cwd, merging
  stderr, with a wall-clock deadline that kills the OS process on hang.
- **Injection-safe**: the prompt is a discrete `args` element, never interpolated
  into a shell string (test proves `$(echo pwned)` returns literal).
- Inherits the BEAM env so it reaches the agent's *persisted* login — **headless
  auth needs no TTY**. This was the make-or-break spike; proven via `claude --help`
  (`-p`/`--permission-mode bypassPermissions`) and `codex exec`.
- Trust boundary documented: `bypassPermissions` only stops the agent stalling on
  *its own* prompts; `BusterClaw.Commands` remains the real authorization boundary.

## Phase 1 — `Dispatcher` work-pump (`lib/buster_claw/dispatcher.ex`)

- A supervised GenServer: when the active shift is `unattended`, the kill switch is
  clear, and the queue is non-empty, it spawns one `AgentRunner` pass to work the
  queue via `./buster-claw`. Serialized (one run in flight), cooldown'd, event- and
  tick-driven, crash-safe (monitored run process; orphans reclaimed on boot).
- Added an `unattended` boolean to `shifts` (migration + schema + `start_shift` opt).
- Gated by `:dispatcher_enabled` (on in dev/prod, off in tests). Key architectural
  call: the pump lives in the **OTP/Phoenix layer, not the Tauri webview**, so
  always-on doesn't depend on a window being open.

## Phase 3 — provenance gate (`commands.ex`, `api_token.ex`, `api_auth.ex`, `dispatcher.ex`)

- **3a (gate):** marked `gmail_send` + the `*_delete` commands `gated`; added an
  `:agent_untrusted` caller tier that may do a lot but is refused the gated set
  (→ `Sentinel.Pending`). Trusted callers unaffected; `:agent`/`:mcp` stay safe-only.
- **3b (wiring):** a third loopback token (`ApiToken.agent_value/0`) that `ApiAuth`
  classifies as `:agent_untrusted`. The Dispatcher decides each run's provenance from
  the queue — **fail-closed: any untrusted open item → the whole run is untrusted** —
  and hands it that token via `BUSTER_CLAW_API_TOKEN` (which the CLI reads first).
  Token mirrors the MCP token (per-machine in prod, dev/test sentinels, boot guard).
- **Finding that reshaped this phase** (`gmail_sync.ex:174`): untrusted mail is
  **never enqueued** — only trusted-sender mail reaches the queue. So the stranger-mail
  threat is blocked *upstream*; the gate is fail-safe insurance for any future/other
  untrusted enqueue (the `trusted` field defaults to `false`). The user chose to wire
  it anyway as cheap insurance.

## Phase 2 — budget governor (`dispatcher.ex`, `config.exs`)

- Per-shift run cap (counted in `dispatched_count`): on breach the shift is **stopped**
  with a Sentinel `:security_block` (like the Orchestrator crash-loop brake) rather
  than skipped — halts cleanly for the operator. Pairs with the per-run wall-clock cap,
  now given an explicit 600s default. Config: `dispatcher_max_runs_per_shift` (50),
  `dispatcher_run_timeout_ms` (600s).

## Phase 4 — operator surface + value report

- **4 (`commands.ex`, `status_live.ex`):** `shift_start` now takes `unattended`
  (threaded to `start_shift`); `shift_status`/`shift_start` report it — startable via
  `./buster-claw run shift_start --json '{"unattended":true}'`. Added an **Unattended
  Shift** panel to Home: start/stop, live run/done/failed counts, engage/clear the
  kill switch; subscribes to the orchestration topic for live state.
- **4c (`activity_report.ex`, `status_live.ex`):** `ActivityReport.summary/1` aggregates
  a recent window (Dispatch status/`finished_at` + Sentinel run events) into requests
  handled/blocked/failed, open, and runs. Surfaced as an `activity_report` command and
  a **This Week** Home panel (live-refreshing on dispatch events). The "what did it do
  for me" piece.

## Phase 5 — always-on (durable resume) (`plist`, `daily-loop.md`)

- Always-on largely *falls out* of the architecture: a shift's state is durable, so an
  active unattended shift **resumes on its own** after an OTP/launchd relaunch (the
  Dispatcher reads `active_shift()` on boot) — no auto-start hook needed.
- Fixed the stale launchd plist comment ("12-hour shift" → indefinite/durable-resume).
- User guide: added a "Hands-off (unattended) mode" section.

## Verification

- `mix test` — **435 tests, 0 failures**; ran the full suite repeatedly to confirm
  stability (one rare pre-existing SQLite `Database busy` flake under parallel async
  writes; mitigated by making the write-heavy `activity_report_test` `async: false`).
- New tests across every phase: AgentRunner (5, incl. injection + timeout-kill),
  Dispatcher (12, incl. provenance→token + budget brake), Commands gate (5),
  api_controller agent-token path (2), shift unattended round-trip (2), StatusLive
  panels (4), ActivityReport (4).

## Notes / deferred

- **Approvals UI deferred** — its gated-pending queue is always empty today (untrusted
  items aren't enqueued), and `Sentinel.Pending` stays record-only. Build it when a
  source actually queues untrusted work.
- **Packaged-env caveat** (needs a real `.app`/launchd build to verify): the BEAM env
  must carry `HOME`/`PATH`/agent-auth and `BUSTER_CLAW_URL` for headless runs.
- **Residual risk** the sender-keyed model doesn't cover: injected instructions inside
  a *trusted* sender's mail — a separate content-level problem.
- Unattended ships **off by default** and inert until an unattended shift is started.
