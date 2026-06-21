# Phase 4 Coordinator — design plan (2026-06-21)

The last substantive ecosystem-roadmap item. Phase 4 shipped the **mechanism**
(`Swarm.run/2`: bounded fan-out, typed results, quorum fan-in, per-sub-run Sentinel
provenance, injectable `:runner`). What's missing is the **driver**: the thing that
turns a unit of work into a `plan` and runs it under the Dispatcher in the live app.
Today `Swarm.run/2` has never executed a real `AgentRunner` — every test injects a
runner.

## The architectural tension to resolve first

The current unattended model (post pull-queue cut) is **agent-pulls-queue**: the
Dispatcher launches *one* generic agent run that reads `Dispatch.md`, claims items via
the `./buster-claw` CLI, works them, and exits (`dispatcher.ex:230` `work_prompt/2`).
The Dispatcher does **not** decompose — the agent decides what to do.

A coordinator that "decomposes a Dispatch item into a Swarm plan" is a *different*
control model: the brain (LLM) looks at a specific item and splits it into role-typed
sub-runs. These two models coexist; the coordinator is an **opt-in alternate path**,
not a replacement for the pull-queue pump. Resolving *how* an item opts in is the one
real product decision (below).

## Proposed shape

### `BusterClaw.Swarm.Coordinator` (new)

One serial planner pass → `Swarm.run/2`. Keeps the planner serial per S0.4.

```elixir
@spec coordinate(goal :: String.t(), keyword()) ::
        {:ok, summary} | {:error, :unplannable | term()}
def coordinate(goal, opts \\ []) do
  with {:ok, plan} <- plan(goal, opts) do
    Swarm.run(plan, opts)            # reuses the whole Phase-4 mechanism unchanged
  end
end
```

`plan/2`:
1. Build a **planner prompt** embedding the goal + the available safe-tier command
   surface + "emit ONLY a JSON array `[{\"role\":..,\"prompt\":..}]`, ≤ N subtasks".
2. Run **one** `runner.(planner_prompt, run_opts)` (injectable; default
   `AgentRunner.run/2`).
3. Parse the plan, validate (non-empty, ≤ `:swarm_max_subtasks`, each entry a
   `{role, prompt}` of strings), `{:error, :unplannable}` on failure.

### Dispatcher wiring

- A new branch in `start_run/2`: when the work requests fan-out, route through
  `Coordinator.coordinate/2` instead of the single `runner.(prompt, run_opts)`.
- Still **one monitored spawn** = one tick → crash-loop brake composes correctly
  (a flaky sub-role is data; only a coordinator crash or quorum-block streak is a
  tick failure). S0.4 point on crash-loop composition.
- **Provenance** inherits `queue_provenance/0` fail-closed and is passed as
  `Swarm.run`'s `:run_opts` → every sub-run gets the same token (untrusted if any
  queued item is untrusted). Fan-out cannot launder an untrusted item into a
  trusted sub-role.
- **Budget**: count each sub-run as a run. Check `dispatched_count + n <= cap`
  *before* launch (fail-closed: block + `:security_block` if the swarm would
  exceed the per-shift cap); bump `dispatched_count` by `n` on completion. Wallet-
  cents reservation stays **deferred** (Phase 4 decision — cost is bounded by the
  concurrency cap + `max_runs_per_shift`, not the ledger).
- **`record_outcome/3`** gains a clause for a swarm summary
  (`%{ok: ok, quorum: q, results: _}`): `ok >= q` → `"completed"`, else `"failed"`
  (with the failed roles in the note). `Memory.record_run/1` captures a per-role
  detail tail so cross-run recall sees the fan-out.

## The one decision that changes the build

**How does a unit of work opt into fan-out?** Three options, each a different
implementation:

- **(A) Explicit per-item `strategy` field.** Add `strategy: "swarm"` to a dispatch
  item; the Dispatcher routes those through the coordinator. Most predictable, most
  auditable, least magic. Requires a migration + CLI flag (`dispatch add … --swarm`).
- **(B) Per-job default.** A `job-descriptions/*.md` flag (`strategy: swarm`) makes a
  whole job's items fan out. No per-item control, no migration — rides the existing
  file-discovery moat.
- **(C) Coordinator-always.** Every tick runs the planner, which decides serial vs.
  fan-out. Most "agentic", but every tick pays a planner run (token cost) and it's the
  hardest to reason about / audit. Not recommended for a solo-dev unattended daemon.

## Recommended staging (de-risk before the LLM)

1. **Stage 1 — prove the swarm runs real agents.** Wire `Swarm.run/2` into the
   Dispatcher behind a **deterministic/static planner** (e.g. a fixed 2-role split, or
   one sub-run per claimed item). No LLM. This is the first time a real `AgentRunner`
   Port fans out in the live app — it validates concurrency cap, per-sub-run timeout,
   provenance, and the new `record_outcome` clause **without** the parsing/quality risk
   of an LLM planner.
2. **Stage 2 — add the LLM planner.** Swap the static planner for
   `Coordinator.plan/2`. Now the only new risk is plan *quality/parse*, on top of an
   already-proven execution path.

This ordering means the brittle part (LLM plan transport + parse) lands last, on a
substrate that's already been seen working.

## Open sub-decisions (lower stakes, can default)

- **Plan transport.** Stdout JSON parse (fits `AgentRunner` today, brittle) vs. the
  planner writes a `plan.json` to the workspace that the coordinator reads (robust,
  matches the file-first moat). Lean **file** for Stage 2.
- **Default quorum** for coordinator swarms — `Swarm.run` already defaults to majority;
  research-style fan-out wants majority, irreversible work wants `n`. Carry per-item.

## Test plan (in-process, no live server — the usual constraint)

- Coordinator: valid plan → `Swarm.run` called with parsed plan (injected runner);
  unparseable output → `{:error, :unplannable}`; over-`max_subtasks` rejected.
- Dispatcher: a swarm-strategy item routes to the coordinator (injected); quorum-met →
  `"completed"` summary + `dispatched_count += n`; quorum-not-met → `"failed"` + failed
  roles noted; would-exceed-cap → blocked + `:security_block`. Provenance: an untrusted
  queued item forces the agent token into `Swarm.run`'s `run_opts`.
- Memory: a swarm outcome writes one `run_summaries` row recall can find.
