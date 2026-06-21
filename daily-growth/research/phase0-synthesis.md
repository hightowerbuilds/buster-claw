# Phase 0 — Synthesis & locked decisions
**Date:** 2026-06-20 · **Status:** Phase 0 complete · **Inputs:** S0.1–S0.6
**Refines:** `roadmaps/06-20-26-ecosystem-roadmap-refined.md`

## Exit criteria — met
- ✅ Six design notes: `s0.1`…`s0.6` in `daily-growth/research/`.
- ✅ A chosen skill-file schema (S0.2) — verified to round-trip through the existing
  `Frontmatter` parser with **zero parser changes**.
- ✅ A one-page threat model (S0.5) with an explicit pre-execution gate.

## The honest caveat (read this first)
All four web spikes independently reported **low confidence on the ecosystem internals**:
OpenClaw / Hermes-agent / Kimi-K2.6 specifics are vendor/SEO content that post-dates the
Jan-2026 cutoff, and the primary source (`lobsterattack.yachts`) is an unreachable JS SPA. The
"+39.5% self-evolution" and "300 agents / 4,000 steps" figures are marketing.

**Why the plan still stands:** every decision below was re-anchored on *verifiable, in-cutoff*
systems — Anthropic Agent Skills / `SKILL.md`, the A2A spec, MemGPT/Letta memory tiers, OTP
primitives — and on Buster Claw's **actual code**. The roadmap is buildable on its own
engineering merits whether or not the essay's three systems are wholly real. We are borrowing
*patterns*, not trusting *claims*.

## Locked decisions

1. **Skill definitions are files, not a table.** Adopt the S0.2 schema: `<workspace>/skills/*.md`,
   discovered at runtime by a near-clone of `Jobs.list/0`. Frontmatter = `name` / `description` /
   `metadata` (verbatim from Agent Skills) + our `tier` / `args` / `steps`. `steps`/`args`/`metadata`
   are **single-line JSON** (not YAML block lists) because the existing `Frontmatter` parser handles
   JSON scalars/`[...]`/`{...}` but not `- item` lists — so it works today, no parser change.

2. **One enforcement choke point.** Generalize `Commands.authorize/2` into `PolicyEngine.check/2`,
   evaluated in `call/2` **before** `dispatch/2`, for native and composition alike. Skill steps
   re-enter `call/2` with `caller = min(skill_tier, invoker)` — **never `apply/3`**. The 8-point
   execution gate (S0.5) is the definition of "safe to run a dynamic skill."

3. **Defer A2A; stay on the durable queue + loopback CLI.** A2A is a real standard but solves
   cross-machine/cross-vendor coordination we don't have, and an A2A ingress would bypass Sentinel.
   Cheap win now: align `job-descriptions/*.md` frontmatter to the `SKILL.md` convention (file work,
   zero protocol commitment). Revisit only for cross-machine agents or third-party interop.

4. **Memory = Tiers 1+2 only.** Keep the transcript (Tier 1, done); build `run_summaries` + SQLite
   **FTS5** + a `memory_search` command (Tier 2), written from `Dispatcher.record_outcome/3`. **Cut**
   Tier 3 (durable agent-notes — the dropped `memories` table already showed it didn't earn its keep;
   if needed, let the agent append to a plain markdown file via normal file tools) and **Tier 4**
   (user-model — one solo dev needs none; `trusted-email-senders.md` covers the one real user-fact).

5. **Defer DSPy/GEPA self-evolution.** No eval set / scoring function exists for a solo dev. Keep
   skills pure-text and step outcomes Sentinel-logged so the analyzer→proposer loop (Phase 3) and,
   later, scoring can bolt on at zero cost.

6. **Parallelism (Phase 4) = `Task.Supervisor.async_stream_nolink/4`.** `max_concurrency` cap 3–4,
   per-run timeout, `on_timeout: :kill_task`. Contract: a serial coordinator emits a `plan` of
   `{role, prompt, budget_cents}`; sub-runs fan out under the cap, each its own `AgentRunner` Port
   with its own fail-closed token, each emitting a `:command_invoke`/`:skill_invoke` event tagged
   `{swarm_id, role, index}` and **reserving `budget_cents` up-front** as a `wallet_transactions`
   row (reconcile on done). Fan-in is an explicit deterministic step over **all** typed results
   (`:ok | :error | :timeout`) → `done` if successes ≥ `quorum`, else `block` (never silent drop).
   **A whole swarm is one Dispatcher tick**, so a flaky sub-role is *data*, not a tick failure — only
   coordinator death or a quorum-block streak feeds the Orchestrator's crash-loop brake; coordinator
   crash recovers via the existing `{:DOWN}` + `reclaim_orphans/0` path.

## Phase 1 — now concrete enough to build (definition of done)
1. `Skills.list/0` + `Skills.get/1` clone the `Jobs` file-discovery pattern over `skills/*.md`
   (memoized in `:persistent_term`, safe-empty default, invalidate on write).
2. `Commands.call/2` resolves a composition skill after the catalog miss; `source: composition`
   shown in `/api/commands` + `./buster-claw commands`.
3. `PolicyEngine.check/2` at the choke point; rules in `<workspace>/memory/policy.md`.
4. Loader guards: `enabled` default-false, `handler_kind: composition` allowlist, name-collision
   rejection, flat-list + `max_steps` validation.
5. Per-caller/per-command rate counter (reuse the wallet ledger for spend; new counter for call-rate).
6. `:skill_invoke` audit category + per-step `skill:` provenance.
7. **Acceptance test:** drop a `skills/*.md` (no restart) → appears in catalog → a `policy.md` rule
   blocks it when it reaches a gated command as `:agent_untrusted` → both events on the Sentinel feed
   → rate limit trips on the Nth call. Green.

## Recommended next action
Build **Phase 1A** first (the `Skills` loader + the S0.2 schema + catalog fall-through) — it's the
lowest-risk, highest-clarity slice and it's inert without 1B. Then land **1B** (policy engine) in the
same phase before any skill is allowed to touch a gated command, exactly as the dependency graph
requires.
