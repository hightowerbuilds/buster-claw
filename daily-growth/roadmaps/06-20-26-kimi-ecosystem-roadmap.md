# KIMI / Claw-Ecosystem Roadmap — Borrowing from OpenClaw, Hermes & Kimi K2.6

**Date:** 2026-06-20 · **App version:** 0.1.0 · **Source:** BusterClaws essay on lobsterattack.yachts (post 2026-06-21)

## Why this exists

The Lobster Attack feed post "KIMI + The Claw Ecosystem" proposed five upgrade
paths for Buster Claw, drawn from three real systems (verified June 2026, all
post-dating the Jan-2026 knowledge cutoff):

- **OpenClaw** (`github.com/openclaw/openclaw`) — local-first multi-agent gateway,
  A2A agent-to-agent protocol, modular skills, per-agent session isolation.
- **Hermes Agent** (Nous Research, `github.com/nousresearch/hermes-agent`) —
  self-improving single agent: writes reusable Markdown **skill files** after each
  task, 4-tier persistent memory, DSPy+GEPA skill evolution.
- **Kimi K2.6** (Moonshot, Apr 2026) — 1T MoE engine, 256K context, **Agent Swarm**
  of 300 sub-agents / 4,000 coordinated steps; the cheap engine that makes swarms
  viable.

The essay's claims check out, so these are genuine patterns to borrow — not fiction.

## The honest current state (grounded)

Buster Claw already has *primitive* versions of most of these. This roadmap closes
gaps; it does not build from zero.

| Theme | Today | Key files | Gap |
|---|---|---|---|
| 1. Skill surface | **86 hardcoded** commands, compiled catalog, 3 trust tiers | `lib/buster_claw/commands.ex`, `plugs/api_auth.ex` | No runtime-addable skills; every new capability = recompile + restart |
| 2. Persistent memory | `<workspace>/memory/*.md` + per-conversation chat transcript table | `agent/transcript.ex`, `jobs.ex` | No cross-run summaries, no index/recall, no pattern memory |
| 3. Multi-agent | Durable Dispatch pull-queue, 5 roles, Orchestrator janitor, Dispatcher work-pump | `dispatch.ex`, `orchestrator.ex`, `dispatcher.ex` | **Serial only** — one headless run per tick; no decomposition, no parallel roles |
| 4. Self-improving | **None** | — | No pattern detector, no skill proposer |
| 5. Security | Sentinel audit spine, gated commands, loopback token, SSRF guard, trusted-senders | `sentinel.ex`, `url_guard.ex`, `trusted_senders.ex` | Audit is log-only (no enforcer); no declarative policy; no rate/budget limits |

## Dependency shape (why the phases are ordered this way)

```
        ┌─────────────────────────────┐
        │ Phase 0: Research spikes    │  (parallel, no code)
        └──────────────┬──────────────┘
                       │
        ┌──────────────▼──────────────┐
        │ Phase 1: Dynamic Skill       │   skill registry + the policy engine
        │   Registry  +  Policy Engine │   MUST land together — a runtime-addable
        │   (Themes 1 + 5)             │   skill is a security surface
        └──────────────┬──────────────┘
                       │
        ┌──────────────▼──────────────┐
        │ Phase 2: Cross-run Memory    │   summaries + recall index
        │   (Theme 2)                  │
        └──────────────┬──────────────┘
                       │
        ┌──────────────▼──────────────┐
        │ Phase 3: Self-improvement    │   pattern → proposed skill → human approve
        │   (Theme 4)  needs 1+2+5     │
        └──────────────┬──────────────┘
                       │
        ┌──────────────▼──────────────┐
        │ Phase 4: Parallel Swarm      │   roles as first-class, fan-out/fan-in
        │   (Theme 3)  needs 2+5       │
        └─────────────────────────────┘
```

Rationale: the registry (1) is the substrate self-improvement (4) writes into;
memory (2) is what pattern-detection reads; the policy engine (5) must gate *both*
dynamic skills and parallel actions before they exist. Swarms (3) come last because
they multiply the blast radius of everything else — you want memory + policy solid
first.

---

## Phase 0 — Research spikes (parallel, ~days, no production code)

Each spike produces a short design note under `daily-growth/research/`. Run them
concurrently (good candidate for a Buster Claw shift / sub-agent fan-out).

- **S0.1 — OpenClaw skill + A2A model.** Read `openclaw/openclaw` skill format and
  the `openclaw-a2a-gateway` (A2A v0.3.0) protocol. Q: what does a "skill" manifest
  look like, and is A2A worth adopting for our roles vs. our loopback CLI?
- **S0.2 — Hermes skill files + self-evolution.** Read `hermes-agent` skill-file
  spec (agentskills.io standard) and `hermes-agent-self-evolution` (DSPy+GEPA). Q:
  what's the minimal skill-file schema we can adopt verbatim so our skills are
  portable?
- **S0.3 — Hermes 4-tier memory.** Document the four tiers and map each to a Buster
  Claw store (workspace md / SQLite / index). Q: which tiers do we actually need?
- **S0.4 — Kimi Agent Swarm coordination.** Study the 300-sub-agent / 4,000-step
  decomposition model. Q: what's the fan-out/fan-in contract and failure handling we
  should mirror in OTP?
- **S0.5 — Threat model for dynamic skills.** Before writing any registry: what can
  a malicious/buggy runtime skill do, and which existing guards (tiers, gating,
  Sentinel, SSRF) cover it? Feeds Phase 1.

**Exit criteria:** five design notes + a chosen skill-file schema + a one-page
threat model.

---

## Phase 1 — Dynamic Skill Registry + Policy Engine (Themes 1 & 5)

The foundation. Make capabilities addable at runtime *and* make the security layer
able to enforce, not just observe — these ship as one phase because a runtime skill
that isn't policy-gated is a vulnerability.

### 1A. Skill registry
- New `skill_definitions` SQLite table: `{name, type, tier, gated, manifest,
  handler_kind, source, enabled}`. Adopt the skill-file schema chosen in S0.2.
- Extend dispatch in `commands.ex` (`Commands.call/3`): after the static
  `build_catalog()` lookup misses, fall through to a DB-backed registry resolved at
  runtime (no recompile). Keep the 86 native commands as the trusted built-in tier.
- Handler kinds, least-powerful first: (1) **composition** — a skill = an ordered
  list of existing native commands (safest, ship this first); (2) **script** — a
  sandboxed shell/CLI invocation; (3) defer arbitrary-code handlers until the
  threat model says yes.
- Surface in `/api/commands` and `./buster-claw commands` with a `source:
  native|dynamic` marker so the catalog stays auditable.

### 1B. Policy engine (extends Sentinel)
- New `BusterClaw.PolicyEngine`: declarative rules evaluated at dispatch time
  (e.g. "dynamic skills may not call `gated` commands," "skill X allowed only for
  trusted caller," optional time/domain constraints). Rules live in
  `<workspace>/memory/policy.md` or a `policies` table — keep it operator-editable
  like `trusted-senders.md`.
- New tier for dynamic skills: a runtime skill defaults to the most-restricted
  caller class and can never exceed the trust of its invoker.
- Make Sentinel an **enforcer hook**, not only a recorder: `Sentinel.observe` stays,
  but `PolicyEngine.check/2` runs *before* execution and can refuse, recording a
  `:security_block`.
- Add per-caller **rate limits / budgets** (close the "spam `gmail_search`" gap).

**Exit criteria:** a composition skill added at runtime via API, visible in the
catalog, blocked by a policy rule when it tries a gated command, with both events on
the Sentinel feed. Tests green.

---

## Phase 2 — Cross-run persistent memory (Theme 2)

- **Run summaries:** at the end of each headless `AgentRunner.run/2`, persist a
  structured summary `{goal, actions[], outcomes, skills_used, ts}` to a
  `run_summaries` table and/or `memory/summaries/*.md`.
- **Recall:** a full-text (SQLite FTS5) index over summaries + workspace memory so an
  agent can query "what have I done with X before?" via a new `memory_search`
  command. Embeddings/vector are optional later — FTS first.
- **Map the Hermes 4 tiers** (from S0.3) onto: ephemeral run context → run summaries
  → durable workspace `memory/` → user model. Keep it file-first so it stays
  auditable and git-diffable.

**Exit criteria:** a second run can recall and reference the first run's outcome via
`memory_search`.

---

## Phase 3 — Self-improving / auto-skill (Theme 4)

Depends on 1 (a place to write skills), 2 (history to learn from), 5 (gating the
output).

- **Analyzer** (new GenServer, interval or post-shift): reads `security_events` +
  `run_summaries`, aggregates repeated action sequences (heuristics first — no LLM
  required: "ran A→B→C 12× this week").
- **Proposer:** emit a *proposed* composition skill (Phase 1A handler kind 1) into a
  `skill_suggestions` table — **never auto-enabled**. Human-in-the-loop: operator
  approves via CLI/UI, which flips `enabled` in `skill_definitions`. (This is the
  Hermes loop, made safe by Buster Claw's confirmation-gate philosophy.)
- **Optional later:** adopt DSPy/GEPA-style evaluation (S0.2) to score and refine
  approved skills.

**Exit criteria:** the analyzer detects a repeated sequence and files a suggestion;
operator approves it; the new skill is then dispatchable.

---

## Phase 4 — Parallel multi-agent swarm (Theme 3)

The biggest change to the orchestration model; last because it multiplies blast
radius.

- **Roles as first-class:** a `roles` table `{name, capabilities[], max_parallel}`
  replacing the hardcoded `role_shell/1` list in `jobs.ex`.
- **Decomposition + fan-out:** extend `Dispatcher` so an item can spawn N parallel
  sub-runs (bounded concurrency, per-role budgets from the Policy Engine), with a
  fan-in/aggregation step — mirroring the Kimi swarm contract from S0.4. Keep the
  OTP supervision + crash-loop brake guarantees.
- **Coordination:** decide A2A (S0.1) vs. staying on the loopback CLI/queue. Default
  recommendation: stay on the durable queue + loopback (simpler, already auditable);
  adopt A2A only if cross-machine agents become a goal.
- **Sentinel for swarms:** every sub-run carries provenance; parallel gated actions
  still require the same confirmation gates.

**Exit criteria:** one Dispatch item decomposes into ≥3 parallel sub-runs that
aggregate into a single result, all on the audit feed, within policy budgets.

---

## Cross-cutting principles (keep these — they're the moat)

- **Human-in-the-loop stays.** Self-generated skills and irreversible actions remain
  confirmation-gated. Hermes auto-enables; Buster Claw proposes-then-approves.
- **File-first + auditable.** Prefer workspace markdown + SQLite over opaque stores
  so everything is git-diffable and on the Sentinel feed.
- **Least power by default.** New dynamic skills start at the lowest trust tier and
  the safest handler kind.
- **No silent scope creep.** Each phase ships behind tests; the catalog always marks
  native vs. dynamic.

## Suggested first action

Run Phase 0 as a Buster Claw research shift (the five spikes fan out cleanly to
sub-agents), then commit to Phase 1 with the threat model (S0.5) in hand.
