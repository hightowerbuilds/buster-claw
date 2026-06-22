# Ecosystem Roadmap — Refined (pressure-tested against the code)

**Date:** 2026-06-20 · **App version:** 0.1.0 · **Refines:**
`06-20-26-kimi-ecosystem-roadmap.md` · **Method:** every "current state" claim in
the Kimi roadmap was verified against the actual source (file:line). This file
keeps the five themes and phase ordering — those are sound — but corrects the
factual baseline and re-scopes three phases that were built on wrong premises.

> Read the Kimi roadmap first for the narrative and the OpenClaw/Hermes/Kimi
> source material. This is the corrected, buildable version.

---

## Status (updated 2026-06-21) — Phases 0–4 substrate complete

| Phase | Status | Commit(s) |
|---|---|---|
| 0 — Research spikes | ✅ done | (notes under `daily-growth/research/`) |
| 1A — Composition skills (`skills/*.md`) | ✅ done | `4e5ead7` |
| 1A.1 — Surface skills in `/api/commands` + CLI | ✅ done | `4808fcb` |
| 1B — Policy engine (`policy.md`) | ✅ done | `584548e` |
| 1C — Rate limits (ETS counter) | ✅ done | `a311bc4` |
| 2 — Cross-run memory (run_summaries + FTS5) | ✅ done | `a64a85b` |
| 3 — Self-improving (analyzer → propose → approve) | ✅ done | `de8356a` |
| 4 — Parallel swarm mechanism (`Swarm.run/2`) | ✅ done | `85761d7` |
| 4.1 — Swarm coordinator (planner → fan-out) + Dispatcher wiring | ✅ done | `a1b84ee` |
| 4.2 — `dispatch_enqueue` operator/agent seam (drives the swarm path live) | ✅ done | (this session) |

**Also:** SQLite test flake root-caused + fixed (`ce44b16`), prod busy_timeout
hardened (`67dfd61`).

**Done since this roadmap was written:**
- ✅ **Surface dynamic skills in `/api/commands` + CLI `commands`** (`4808fcb`).
  `/api/commands` returns `list_commands ++ list_skills`; `list_skills/0` reads
  `skills/*.md` **live from disk** each call, so the feared `:persistent_term`
  invalidate-on-write was unnecessary — only the static native catalog is cached;
  runtime-added skills are always fresh. Covered by `skills_test.exs` +
  `api_controller_test.exs` ("surfaces enabled composition skills tagged
  source=composition").
- ✅ **Phase 4 coordinator — built and wired** (`a1b84ee`). `Swarm.Coordinator`
  runs a serial planner (one `AgentRunner` pass → JSON `[{role,prompt}]`, parsed
  fail-closed) then the unchanged `Swarm.run/2` fan-out. The Dispatcher claims
  `strategy: "swarm"` items via `start_swarm_run`, inherits `queue_provenance`
  fail-closed into every sub-run, counts `planner + sub-runs` against the per-shift
  cap, and `record_outcome/3` has swarm clauses (completed / quorum-not-met →
  blocked / unplannable → blocked) that also write a `run_summaries` row. The
  **opt-in decision** was settled as **(A) explicit per-item `strategy` field**
  (`dispatch_strategy` / `dispatch strategy <id> swarm`). Covered by
  `coordinator_test.exs` + the swarm branches of `dispatcher_test.exs`.
- ✅ **`dispatch_enqueue` operator/agent seam** (this session). Previously items
  only entered the queue via Gmail triage, so the swarm path could not be driven
  by hand — that was the real blocker behind "nothing driven in the running app."
  New restricted-tier command + CLI `dispatch add <summary> [--swarm] [--subject]
  [--source] [--untrusted]` enqueues a manual item (trusted by default).
  Also fixed a latent gap: `Dispatch.enqueue/1` now mints a unique `dedupe_key`
  for any non-Gmail source instead of failing the changeset.

**Remaining — one manual smoke test, no code:**
- **Live validation in the running app.** Every path is unit-tested with injected
  runners; what's left is one real end-to-end run with a live `AgentRunner`
  (Claude Code) under an unattended shift — the Phase 4 exit criterion ("one item
  decomposes into ≥3 parallel sub-runs that aggregate into one result, all on the
  audit feed, within budgets"). Runbook (server running, a few open dispatch
  items / a live agent in the terminal):
  ```
  ./buster-claw dispatch add "Research X across 3 angles and write a combined brief" --swarm
  ./buster-claw dispatch list          # confirm the item is queued, strategy=swarm
  ./buster-claw shift start --json '{"unattended":true}'   # Dispatcher pumps the swarm item
  ./buster-claw shift status           # watch dispatched/done counts
  # Then check the Sentinel feed for per-sub-run provenance + the swarm outcome.
  ```
  Once this passes once, this whole roadmap retires to `old-maps/`.

---

## What the verification changed

Seven claims in the original were wrong or understated. None of them sink the
roadmap, but two of them change what we build.

| # | Original claim | Reality (verified) | Impact |
|---|---|---|---|
| 1 | "86 hardcoded commands" | **85**, in `commands.ex` `build_catalog/0` (l.77). Catalog is **built at runtime and memoized in `:persistent_term`** (l.1219-1231), not compile-time. Handlers *are* compiled funcs dispatched via `apply/3` (l.1374). | Cosmetic. The "no runtime-addable capability without recompiling a handler" gap is still real. |
| 2 | "3 trust tiers" | Two *command* tiers — `:safe` / `:restricted` — and three *caller* levels — `:trusted` / `:agent_untrusted` / `:mcp` (`plugs/api_auth.ex` l.42-56). | Terminology. The policy engine must speak both axes; don't model it as one 3-tier ladder. |
| 3 | "Audit is log-only (no enforcer)" | **An enforcer already exists.** `Commands.authorize/2` refuses gated commands for `:agent_untrusted` and records a pending-confirmation via `Sentinel.Pending` (commands.ex l.1275-1277, 1387-1401). 8 commands are gated. | **Changes Phase 1.** The policy engine *extends `authorize/2`*, it does not graft a new check onto `Sentinel.observe`. |
| 4 | "No rate/budget limits" | **Budgets already exist.** `wallets` / `wallet_budgets` / `wallet_transactions` / `wallet_feeds` tables + `WalletPoller` cap unattended **run cost**; the Dispatcher checks the budget gate before launching (dispatcher.ex l.123-127). | **Narrows Phase 1.** The gap is per-*caller/per-command* call-rate limits on the API surface — not budgets from zero. Reuse the wallet ledger. |
| 5 | "5 roles … `role_shell/1` in `jobs.ex`" | **No `role_shell/1` exists.** Jobs are already **file-discovered at runtime** from `<workspace>/job-descriptions/*.md` (`Jobs.list/0` l.25-38); only one seed job ships (`mail-triage`). | **Changes Phase 4.** "De-hardcode the roles" is a non-goal — roles are already data. The real Theme-3 gap is *parallel execution*, nothing else. |
| 6 | memory store: "`<workspace>/memory/*.md`" as an active layer | `memory/` is **scaffolding**. The only runtime write is the seeded `trusted-email-senders.md` (jobs.ex l.87-90). The DB-backed `memories` table was **dropped 2026-06-14** as unused. | **Re-frames Phase 2.** We're building a memory layer from a clean slate, not closing a gap on a live one. Slightly more work; zero migration baggage. |
| 7 | run-summary hook in "`AgentRunner.run/2`" | `run/2` exists and is the right launcher, but it just returns a result. The post-run seam is **`Dispatcher.record_outcome/3`** (dispatcher.ex l.249-275), which already records the Sentinel outcome + bumps shift counters. | Phase 2 hook placement only. |

Everything else checked out: the durable pull-queue (`Dispatch.claim_next/2`,
pessimistic lock + orphan reclaim), the **serial-only** dispatcher (one run per
tick; the `batch` param is a *prompt instruction* to the agent, not parallelism —
dispatcher.ex l.14, 157-158), the OTP tree + crash-loop brake
(`Orchestrator.trip_crash_loop/2`, l.54-90), the SSRF guard, and file-backed
trusted senders are all exactly as described.

One framing nit: the Orchestrator is a **kill-switch watcher + crash-loop brake**,
not a "janitor." It explicitly no longer dispatches runs (orchestrator.ex l.7-10).

---

## The one architectural change worth making

The original reaches for a **new `skill_definitions` SQLite table** for Theme 1.
But the codebase *already has the pattern we want*: capability units defined as
**markdown files discovered at runtime** — that's exactly what `job-descriptions/`
and `trusted-email-senders.md` are. They're git-diffable, on disk, operator-editable,
and need no recompile.

So the refined Phase 1 builds **composition skills as markdown files** in
`<workspace>/skills/*.md`, discovered the same way `Jobs.list/0` discovers jobs —
**not** a new DB table. This is more consistent with the codebase, honors the
roadmap's own "file-first + auditable" moat principle, and is less code. Use SQLite
only for the things that genuinely need querying (run summaries → FTS, suggestions
→ approval state). Files for definitions, DB for history. (If a skill needs an
`enabled` toggle and audit trail, that's a small `app_settings`-style row keyed by
skill name — still not a full registry table.)

---

## Refined phases

Ordering is unchanged (1 → 2 → 3 → 4, research spikes first). The scope deltas:

### Phase 0 — Research spikes (unchanged, still the right first move)
Keep all five spikes. Add one: **S0.6 — inventory the existing seams** we're
extending so nobody rebuilds them: `Commands.authorize/2` (enforcement point),
the wallet ledger (budgets), `Jobs.list/0` (file-discovery pattern),
`Dispatcher.record_outcome/3` (post-run hook). Half a page; prevents duplicate work.

### Phase 1 — Composition skills + Policy engine (Themes 1 & 5) — **re-scoped**
- **1A. File-discovered composition skills.** `<workspace>/skills/*.md`, each an
  ordered list of existing native commands (handler kind 1 only, to start).
  Resolve in `Commands.call/2` **after** the catalog miss, mirroring `Jobs.list/0`.
  Mark `source: native|composition` in `/api/commands` + `./buster-claw commands`.
  Defer script/arbitrary-code handlers until S0.5 says yes.
- **1B. Policy engine = generalize the gate that already exists.** Refactor
  `Commands.authorize/2` from hardcoded "agent_untrusted can't call gated" into a
  declarative rule set (file: `<workspace>/memory/policy.md`, same pattern as
  trusted-senders). Rules evaluated **before** dispatch; a refusal records a
  `:security_block` on the existing Sentinel feed. A composition skill can never
  exceed the trust of its invoker, and may not reach a gated command unless a rule
  allows it.
- **1C. Rate limits — the actual gap.** Per-caller / per-command call-rate limits
  (close the "spam `gmail_search`" hole). **Reuse the wallet ledger** for the
  spend side; add a lightweight per-caller counter for the call-rate side. Don't
  build a second budget system.
- **Exit:** a composition skill added by dropping a markdown file (no restart),
  visible in the catalog, blocked by a `policy.md` rule when it reaches for a gated
  command, both events on the Sentinel feed, rate limit trips on Nth call. Tests green.

### Phase 2 — Cross-run memory (Theme 2) — clean-slate, hook corrected
- **Run summaries:** persist `{goal, actions[], outcomes, skills_used, ts}` from
  **`Dispatcher.record_outcome/3`** (not `AgentRunner.run/2`) to a new
  `run_summaries` table. The Sentinel outcome is already recorded right there —
  add the structured summary alongside it.
- **Recall:** SQLite **FTS5** over `run_summaries` + workspace markdown, exposed as
  a new `memory_search` native command. Embeddings/vectors are explicitly out of
  scope for v1.
- **Map the Hermes 4 tiers** (from S0.3) onto: run context → run summaries →
  durable `memory/` md → user model. Note honestly that the durable `memory/` tier
  is *new* (the old DB table was retired), so this phase stands it up rather than
  reusing it.
- **Exit:** run B recalls run A's outcome via `memory_search`.

### Phase 3 — Self-improving / auto-skill (Theme 4) — unchanged, it was right
Analyzer (GenServer, heuristics-first, no LLM required) reads `security_events` +
`run_summaries`, detects repeated A→B→C sequences, files a **proposed composition
skill** (a `skills/*.md` draft + a `skill_suggestions` row) — **never auto-enabled**.
Operator approves via CLI/UI → the file activates. This is the Hermes loop made safe
by Buster Claw's confirm-gate philosophy. DSPy/GEPA scoring stays "optional later."
- **Exit:** analyzer files a suggestion from a real repeated sequence; operator
  approves; the new skill is dispatchable.

### Phase 4 — Bounded parallel fan-out (Theme 3) — **re-scoped, still last**
The original's "replace the hardcoded `role_shell/1` role list" is dropped — roles
are already file-data via `job-descriptions/`. The single real gap is that the
**Dispatcher is serial** (one run per tick). So Phase 4 is *only* about parallelism:
- Let one Dispatch item fan out into **N bounded parallel sub-runs** (concurrency
  cap + per-role budget drawn from the **existing wallet ledger**), with a fan-in
  aggregation step — mirroring the Kimi swarm contract from S0.4. Keep the OTP
  supervision + crash-loop brake; every sub-run carries provenance to Sentinel and
  parallel gated actions still hit the same confirmation gate.
- **Coordination:** stay on the durable queue + loopback CLI (already auditable);
  adopt A2A only if cross-machine agents ever become a goal. (Unchanged
  recommendation — and now clearly the lower-risk default.)
- **Exit:** one item decomposes into ≥3 parallel sub-runs that aggregate into one
  result, all on the audit feed, within wallet budgets.

---

## Cross-cutting principles (kept — they're the moat)

Human-in-the-loop, file-first + auditable, least-power-by-default, no silent scope
creep. The refined Phase 1 leans *harder* into file-first by using `skills/*.md`
instead of a registry table.

## Suggested first action (unchanged)

Run Phase 0 as a Buster Claw research shift (six spikes fan out cleanly), then
commit to the re-scoped Phase 1 with the S0.5 threat model and the S0.6 seam
inventory in hand — so we extend `authorize/2` and the wallet ledger rather than
rebuild them.

---

### Appendix — corrected current-state table

| Theme | Today (verified) | Key files | Real gap |
|---|---|---|---|
| 1. Skill surface | **85** native commands, runtime-memoized catalog (`:persistent_term`), `apply/3` dispatch | `commands.ex` | No runtime-addable capability without a compiled handler |
| 2. Persistent memory | per-conversation transcript (`agent_chat_messages`); `memory/` dir is scaffolding (DB `memories` table dropped 06-14) | `agent/transcript.ex`, `agent/message.ex`, `jobs.ex` | No cross-run summaries, no FTS recall — build fresh |
| 3. Multi-agent | durable pull-queue; **serial** dispatcher (1 run/tick); jobs already file-discovered | `dispatch.ex`, `dispatcher.ex`, `orchestrator.ex`, `jobs.ex` | **Parallelism only** — no fan-out/fan-in |
| 4. Self-improving | none | — | No analyzer, no proposer |
| 5. Security | Sentinel audit + **existing `authorize/2` enforce gate** + 8 gated cmds + **wallet budgets** + SSRF + trusted-senders | `sentinel.ex`, `commands.ex` (`authorize/2`), `wallet*`, `url_guard.ex`, `trusted_senders.ex` | No *declarative* policy; no per-caller call-rate limit |
