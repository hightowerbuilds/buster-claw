# BusterClaw → Always-On (Unattended Shift) Roadmap

**Date:** 2026-06-17
**Target:** Close the #1 business-fit gap from `06-17-26-business-fit-review.md`: a shift that works the queue **without a human babysitting a terminal**, without losing the bring-your-own-agent / no-API-key model.
**Relates:** `06-17-26-business-fit-review.md` (why), `old-maps/06-09-26-terminal-pull-queue-roadmap.md` (the pull-queue this builds on), `old-maps/06-14-26-distribution-roadmap.md` (the launchd/packaging path this rides).

---

## Build status (2026-06-17)

The backend is **complete and tested** (full suite green, 423). Built in order 0 → 1 → 3 → 2:

| Phase | Status | Commit |
|---|---|---|
| 0 — `AgentRunner` headless run primitive | ✅ done | `51c01f7` |
| 1 — `Dispatcher` work-pump | ✅ done | `c973ae7` |
| 3a — provenance gate (Commands layer) | ✅ done | `fe6ad9b` |
| 3b — per-run provenance wiring (3rd token → ApiAuth → Dispatcher) | ✅ done | `823b639` |
| 2 — budget governor (per-shift run cap + run timeout) | ✅ done | `6ce28b3` |
| 4 — operator surface + weekly value report | ⬜ next | — |
| 5 — always-on packaging (launchd headless boot) | ⬜ todo | — |

**Finding that reshaped Phase 3** (see `gmail_sync.ex:174`): untrusted mail is **never enqueued** — only trusted-sender mail reaches the queue. So the stranger-mail threat is already blocked *upstream*; the provenance gate is **fail-safe defense-in-depth** for any future/other source that queues an untrusted item (the `trusted` field defaults to `false`, so such an item is auto-gated). The unaddressed residual risk is injected content *inside trusted-sender mail* — out of scope here.

**Not yet usable end-to-end:** there is no way to *start* an unattended shift except programmatically (`Orchestration.start_shift(unattended: true)`). Exposing that (CLI verb + UI toggle) is Phase 4. The Dispatcher ships enabled but is inert until an unattended shift exists.

---

## The thesis (settled in discussion)

Going headless does **not** remove the in-terminal workaround. The workaround is *"BusterClaw ships no LLM and runs your agent on your subscription."* That survives — we're only **automating the launch** of the same agent. The in-terminal session was quietly doing two jobs; we keep one and replace the other:

| Job the terminal did | Fate |
|---|---|
| **Run your agent on your subscription (no keys here)** | **Kept** — a daemon spawns the *same* `claude`/`codex` binary non-interactively. |
| **A human sits and watches it act** | **Replaced** — by a budget governor + a *narrow* provenance gate (only outbound/irreversible actions from untrusted senders surface). |

Result: **two modes over one queue.**
- **Attended** (today): you drive `claude` in the in-app PTY. Best for judgment work and building trust.
- **Unattended** (this roadmap): the Orchestrator spawns headless agent runs against the **same Dispatch queue** when work lands, bounded by a budget, with restricted actions gated into an approval queue.

The Dispatch queue is the seam: the agent — human-launched or daemon-spawned — is just a **queue worker** either way.

---

## Trust & autonomy model (settled)

**The agent is autonomous and trusted by default. It does a lot without asking.** Permission friction is the thing we're removing, not capability. The only guardrail kept is the one place autonomy has teeth: **untrusted input → irreversible/outbound action.** Nothing else gates.

The gate keys off **provenance, not command tier** — and Dispatch items already carry the signal (`trusted_sender` / `trusted` / `auth_status`):

| Work origin | What the agent does without asking |
|---|---|
| **You / a trusted sender** | **Everything** — reads, drafts, saves, calendar edits, *and* sends/deletes. Fully hands-off. |
| **Unknown / untrusted sender** | All reading, drafting, saving, calendar edits — freely. The *only* thing that surfaces is the **outbound/irreversible finish** (`gmail_send`, `*_delete`). |

So the approval queue is a rare exception (a handful of items a week — outbound actions triggered by strangers), not the spine. The agent runs as **`:trusted`**; the provenance gate is a thin check applied only to outbound/irreversible commands whose originating item is untrusted.

---

## What already exists (so this is wiring, not a rewrite)

- **The durable queue** — `Dispatch.claim_next/2`, `mark_running/2`, `heartbeat/1`, `finish/3`, `reclaim_orphans/0` (crash recovery on boot already works).
- **The shift + janitor** — `Orchestration.start_shift/active_shift/stop_shift`, the STOP-file kill switch, the `Orchestrator` ticker with a **crash-loop brake**, and **`bump_shift(:dispatched | :done | :failed)` counters that already exist** (vestigial from the cut headless design).
- **The untrusted caller tier** — `Commands.call/3` takes `caller: :agent`; a `:restricted` command from an untrusted caller is **refused with `{:error, :requires_confirmation}` and recorded via `Sentinel.Pending`** instead of executing. This is the approval seam, half-built.
- **Agent detection** — `Setup.agent_cli_available?` (`claude`/`codex` on PATH or `~/.local/bin/claude`).
- **The outer watchdog** — `desktop/tauri/launchd/com.hightowerbuilds.busterclaw.plist` (KeepAlive relaunch).

**The missing piece is small and specific:** something that *spawns the agent non-interactively* and a *governor* that decides when to. Everything it reports into already exists.

---

## Key architectural call

**The work pump lives in the OTP/Phoenix layer, not the Tauri webview.** The Mix release runs headless already; the desktop shell is just a window onto it. So unattended mode must not depend on a webview being open — it's a supervised GenServer + a `Port` to the agent CLI. launchd → app → Phoenix → shift, no foreground required. This is the difference between "always-on" being real and being a second terminal you still have to watch.

---

## Locked decisions

| Decision | Choice | Consequence |
|---|---|---|
| Agent launch | **`Port` from Elixir** to the detected CLI (`claude`/`codex`), non-interactive | No Tauri dependency; runs in the release. |
| Queue worker identity | Headless runs call the surface as **`caller: :trusted`** (autonomous) | The agent acts, it doesn't propose. Capability is *not* removed — friction is. |
| Human-as-rate-limiter | Replaced by an explicit **budget governor** (turns/time/runs) | A daemon can't quietly run up a token bill. |
| Restricted actions | **Provenance gate, not blanket approval** | Only outbound/irreversible commands (`gmail_send`, `*_delete`) whose originating item is **untrusted** surface for a glance. Everything else auto-fires. |
| Modes | **Attended and Unattended coexist** over one queue | The PTY stays; it's optional, not removed. |
| Default posture | Unattended is **opt-in, off by default** | Trust is earned; attended remains the safe default. |

---

## Phases

### Phase 0 — Headless run primitive (`BusterClaw.AgentRunner`)
**Goal:** one function that runs the user's agent non-interactively against the workspace and returns a structured result.
- New module spawns the detected agent via a `Port`/`System.cmd`, cwd = workspace root, with a prompt like *"Work the Dispatch queue for job `<key>`: read `shift/Dispatch.md`, claim and complete items via `./buster-claw`."*
- Capture stdout/stderr → a run log + `Sentinel.observe(:command_invoke, …)`; enforce a hard wall-clock timeout (kill the Port on breach).
- **Spike first:** confirm the exact non-interactive invocation per agent (Claude Code headless/print mode + SDK; Codex's non-interactive exec mode) and the auth requirement (see Cross-cutting). Don't hardcode flags until verified.
- **Exit:** `AgentRunner.run(job_key, opts)` returns `{:ok, summary}` / `{:error, reason}`; a manual call drains a test item end-to-end.

### Phase 1 — The work pump
**Goal:** the shift drives `AgentRunner` automatically when there's work.
- Add an **`unattended` flag** to the shift (schema + `start_shift` opt). Extend the `Orchestrator` tick (or a sibling `Dispatcher` GenServer) so that, when the active shift is unattended, kill switch is clear, budget remains, and `Dispatch.list_queued/1` is non-empty → trigger one bounded `AgentRunner` run.
- **Serialize** runs (one at a time, or a tiny concurrency cap); use `bump_shift/2` counters and `Dispatch.heartbeat/1`; lean on existing `reclaim_orphans/0` for crash recovery.
- **Exit:** queue an item with no terminal open → it gets claimed, worked, and finished by a spawned run; counters increment; Security feed shows it.

### Phase 2 — Budget & safety governor
**Goal:** the thing that replaces the human as a limiter.
- Per-run and per-shift caps: max runs/hour, max wall-clock, optional turn cap passed to the agent. On breach → `stop_shift("budget")` reusing the crash-loop-brake pattern (isolated, never crashes the ticker).
- Config-driven defaults; surfaced in settings.
- **Exit:** a runaway/looping agent is bounded and the shift halts cleanly with a Sentinel `:security_block`.

### Phase 3 — Provenance gate + narrow approval queue
**Goal:** keep the agent autonomous, but stop the one foot-gun — an *untrusted* sender steering it into an outbound/irreversible action.
- Thread the originating dispatch item's trust (`trusted_sender` / `trusted` / `auth_status`) onto the command call so the surface knows the work's provenance.
- Gate **only** outbound/irreversible commands (`gmail_send`, `*_delete`) **and only when the originating item is untrusted** → route those to a pending store (promote `Sentinel.Pending` to durable: command + args + originating item). Everything else — all reads/drafts/saves/calendar, and *all* actions on trusted-origin work including sends/deletes — executes immediately as `:trusted`.
- New **Approvals** surface (extend `SecurityLive` or a dedicated LiveView): list the (rare) gated actions with **approve / edit / reject**. Approve → execute; reject → record + drop.
- **Exit:** a stranger's email that tries to trigger `gmail_send` produces a pending item (not a sent mail); the same action requested by *you* sends immediately with no prompt; both are on the audit feed.

### Phase 4 — Operator surface & value report
**Goal:** make unattended legible enough to trust and to justify.
- Shift control: start/stop attended vs unattended, live runs, budget consumed, pending approvals, kill switch — one panel.
- **Weekly value report** (gate #5 from the review): fold `shift/<date>/Dispatch.jsonl` + Sentinel into *"this week your agent handled N items, drafted M replies, K awaiting approval."* Data already exists; this is a view.
- **Exit:** an operator can see, in-app, exactly what the unattended shift did and what's waiting on them.

### Phase 5 — Always-on packaging
**Goal:** launchd → app → unattended shift, no human.
- Headless boot setting: on launch, if "always-on" is enabled, `start_shift(unattended: true)` automatically. Verify it runs with the window closed.
- Fix the **stale plist comment** ("unattended 12-hour shift" — shifts are now indefinite).
- Document the always-on setup (auth persistence, budget, how to stop) in the user guide.
- **Exit:** reboot the Mac → app relaunches → shift resumes and works the queue with no terminal and no window interaction.

---

## Cross-cutting: non-interactive agent auth (the real wrinkle)

Interactive `claude` rides your logged-in session. A daemon spawning headless runs needs that auth available unattended — a persisted CLI login or a token in the BEAM's environment. We don't hold *our own* key, but we now invoke a *credentialed* agent on a timer. **Required work:** detect whether the agent has usable non-interactive auth at shift start; if not, refuse to go unattended with a clear, actionable error (don't silently fail every run). Document the one-time login. This is the single sharpest edge of the whole effort — spike it in Phase 0.

---

## Out of scope (other gates — see business-fit review)

These don't belong here; they're separate gate-removals tracked in `06-17-26-business-fit-review.md`'s priority table:
- Microsoft 365 / Outlook auth
- Slack / Stripe (business integrations)
- In-app no-CLI onboarding for non-developers
- Multi-user / teams
- Windows support

This roadmap unlocks **"while I'm away"** only — but it's the one that turns "a tool I use" into "a teammate that works."

---

## Open questions

1. **Batch shape:** one run per queued item (isolated, more token overhead) vs. one run that drains a bounded batch (cheaper, shared context, slightly less isolation)? Leaning toward **bounded-batch per tick**.
2. **Agent invocation form:** exact non-interactive command/auth per `claude` and `codex` — resolve in the Phase 0 spike before committing flags.

**Settled:** trust/autonomy model — the agent is trusted/autonomous by default; only outbound/irreversible actions (`gmail_send`, `*_delete`) from *untrusted* senders surface for approval. See the "Trust & autonomy model" section.
