# 06-21-2026 Summary

A big day on the **Claw-ecosystem roadmap** — planning through shipping the whole arc.
Pressure-tested a Kimi-authored roadmap against the actual code (wrong in seven places),
ran **Phase 0** as a six-spike research shift, then shipped **Phase 1** (1A composition
skills, 1B policy engine, 1C rate limits), **Phase 2** (cross-run memory), **Phase 3**
(self-improving skills) and **Phase 4** (the parallel-swarm mechanism). Also root-caused
and fixed a long-standing intermittent SQLite test flake. Suite green at **622** (started
the day at 552); ten commits.

## Pressure-testing the Kimi roadmap

`daily-growth/roadmaps/06-20-26-kimi-ecosystem-roadmap.md` proposed five upgrade
paths (skills / memory / multi-agent / self-improving / security) drawn from
OpenClaw, Hermes Agent, and Kimi K2.6. The strategy was sound but its "current
state" baseline was off. Verified every claim against source (file:line) and wrote
the corrected version, `roadmaps/06-20-26-ecosystem-roadmap-refined.md`. Seven
errors, two of which changed the plan:

- **Security understated.** An enforcement gate *already exists* —
  `Commands.authorize/2` + `Sentinel.Pending` refuses gated commands and records a
  pending confirmation. And budgets already exist (the `wallets` ledger +
  `WalletPoller` cap unattended run cost). So the policy engine *extends
  `authorize/2`*, it doesn't graft a new check onto `Sentinel.observe`.
- **Multi-agent premise wrong.** No `role_shell/1`, no hardcoded 5-role list —
  jobs are *already* file-discovered from `job-descriptions/*.md`. "De-hardcode the
  roles" is a non-goal; the only real Theme-3 gap is that the dispatcher is serial.
- Cosmetic: 85 commands not 86; catalog is runtime-memoized (`:persistent_term`),
  not compile-time; "3 tiers" conflates 2 command tiers with 3+ caller classes;
  `memory/` is scaffolding (the DB `memories` table was dropped 06-14, so Phase 2
  is clean-slate); the run-summary hook belongs in `Dispatcher.record_outcome/3`,
  not `AgentRunner.run/2`.

The one architectural call: skill definitions should be **markdown files**
(`<workspace>/skills/*.md`, discovered like jobs), **not** a new `skill_definitions`
SQLite table — consistent with the codebase's own file-first moat, and less code.

## Phase 0 — six research spikes

Ran as a fan-out: four web-research spikes to background sub-agents (S0.1–S0.4),
two code-grounded notes written here (S0.5–S0.6). All under `daily-growth/research/`,
plus a `phase0-synthesis.md` that locks the decisions.

- **S0.1 OpenClaw/A2A** — skill manifest ≈ Anthropic `SKILL.md`; **defer A2A** (real
  standard, but solves cross-machine coordination we don't have and would bypass
  Sentinel).
- **S0.2 skill schema** (the key deliverable) — a concrete `skills/*.md` frontmatter
  (`name`/`description`/`metadata` verbatim from Agent Skills + our `tier`/`args`/
  `steps`), verified to round-trip through the existing `Frontmatter` parser with
  **zero parser changes** (steps/args/metadata are single-line JSON, which the parser
  already decodes). **Defer DSPy/GEPA** self-evolution — no eval set for a solo dev.
- **S0.3 memory** — ship **Tiers 1+2** (transcript + `run_summaries`/FTS5), **cut 3+4**
  (the dropped `memories` table is the codebase's own signal that flat-notes memory
  didn't earn its keep).
- **S0.4 swarm** — mirror Kimi's fan-out as `Task.Supervisor.async_stream_nolink/4`
  (cap 3–4, quorum fan-in, per-sub-run wallet reservation); a whole swarm is **one**
  Dispatcher tick, so a flaky sub-role is data, not a crash-loop trip.
- **S0.5 threat model** — 10 threats mapped to existing guards + an 8-point execution
  gate. The load-bearing rule: **skill steps dispatch through `Commands.call/2`,
  never `apply/3`** — so a skill inherits its caller's trust and every step is
  re-checked against the gated set.
- **S0.6 seam inventory** — every phase mapped to the existing seam it extends, so we
  don't rebuild `authorize/2`, the wallet ledger, or the file-discovery pattern.

**Honest caveat:** all four web spikes reported *low confidence on the
OpenClaw/Hermes/Kimi internals* — vendor/SEO pages post-dating the Jan-2026 cutoff,
and the primary source (`lobsterattack.yachts`) is an unreachable JS SPA. The
"+39.5%" and "300-agent" figures are marketing. The plan survives this because every
decision was re-anchored on *verifiable* systems (Anthropic Agent Skills, MemGPT/Letta,
the A2A spec, OTP) and the actual code — we borrowed patterns, not claims.

## Phase 1A — composition skills (runtime-addable command surface)

The first build slice: capabilities addable at runtime by dropping a markdown file,
no recompile. A composition skill owns **no new capability** — only new *sequencing*
of existing native commands.

- **`lib/buster_claw/skills.ex`** (new). Discovers `<workspace>/skills/*.md` exactly
  like `Jobs` (no DB table), parses the S0.2 schema via the existing `Frontmatter`,
  and enforces the S0.5 load guards: `enabled` **defaults false**; `handler_kind:
  composition` only (script/code rejected); name must match `[a-z0-9-]` and the
  filename stem; `steps` a non-empty flat list within `max_steps` (config
  `:skill_max_steps`, default 20). A disabled/invalid skill is non-resolvable.

- **`commands.ex`** — the choke-point integration. `call/2` is now a router: native
  command wins; a catalog miss may resolve to an enabled skill; else
  `:unknown_command`. **Every step re-enters `call/2` as the same caller, never
  `apply/3`** (the threat-model rule, in code), so the catalog's tier/gated rules
  apply per step and a skill can't exceed its invoker's trust. Step args interpolate
  `$arg` (skill inputs) and `$prior` (previous step's result). Added `list_skills/0`
  — kept **separate** from `list_commands/0` so the native-catalog invariant (every
  listed entry is a dispatchable function with a tier) still holds. A skill run emits
  its own `:command_invoke` / `:security_block` Sentinel events with `skill:`
  provenance.

- **`jobs.ex`** — `ensure/0` now seeds a `skills/` folder with a roster README and one
  enabled example (`save-note`, a one-step `document_save` wrapper).

Deliberately deferred to keep 1A tight: **1B** the declarative PolicyEngine
(`authorize/2` is still the hardcoded gate), **1C** per-caller rate limits, and
surfacing skills in `/api/commands` + CLI `commands` (that endpoint caches its
catalog in `:persistent_term`, so it needs an invalidate-on-write — belongs with 1B).

## Verification

- `mix test` — **577 tests, 0 failures** (was 552). New `skills_test.exs` (10 cases):
  loader/validation (valid load, disabled non-resolvable, unsupported handler_kind,
  over-`max_steps`, name/stem mismatch), `list_skills/0` catalog marker, an
  **end-to-end** run (`save-note` → real document created, `$title`/`$body`
  interpolated), and the two **threat-model invariants**: a restricted skill refused
  for `:mcp` (with the refusal on the Sentinel feed), and a skill **cannot reach a
  gated command** (`document_delete`) as `:agent_untrusted` →
  `{:step_failed, "document_delete", :requires_confirmation}`.
- Full suite re-run after the `Jobs.ensure` seed hook + the `call/2` refactor — no
  regressions. Changed files `mix format`-clean.
- **Verified in-process, not over HTTP** (the usual constraint — booting the server
  outside test gets SIGTERM'd as an agent task). **Still unverified by me:** the live
  `./buster-claw run save-note --json '{...}'` round-trip through the running server,
  and a fresh-dropped `skills/*.md` showing up callable without a restart.

## Phase 1B — Policy engine (declarative authorization)

Generalized the hardcoded `Commands.authorize/2` into **`PolicyEngine.check/1`**,
evaluated at the `call/2` choke point for native commands and composition-skill
steps alike. Two layers:

- **Baseline** (non-overridable): `:agent`/`:mcp` → safe-tier only; `:agent_untrusted`
  → no gated commands. Returns `{:confirm, _}` → surfaces for human approval (the
  existing `:requires_confirmation` behavior).
- **Operator rules** from `<workspace>/memory/policy.md` (file-backed,
  `:persistent_term`-cached, mirroring `trusted-senders.md`): `deny`/`allow <glob>
  for <caller>`. Rules run *after* the baseline passes, so they can only **tighten**,
  never loosen. A matching `deny` → `{:block, _}` → hard refusal (`:policy_blocked`);
  most-specific pattern wins, ties favor deny.

`commands.ex` records both refusal kinds as critical `:security_block`s; `api_controller`
maps `:policy_blocked` → 403; `jobs.ex` seeds a baseline-only `policy.md` (examples
commented, so default == prior behavior). The parser strips fenced/`<!-- -->`/angle-
bracket placeholder lines so prose and templates never log spurious bad-rule warnings.
**Committed `584548e`** (9 new tests).

## Phase 1C — Rate limiting (the last threat-model gap)

Closes T4 (a non-gated command like `gmail_search` spammed in a loop). Policy
authorizes *what* may run; **`RateLimiter`** bounds *how often*. A fixed-window
counter keyed by `{caller, command, window}` in a public ETS table; `check/2` is an
atomic `:ets.update_counter` (off the GenServer mailbox, ~no added latency); the
GenServer owns the table and sweeps stale windows. Config-driven
(`:rate_limit_enabled`/`_window_ms`/`_default`/`_overrides`), **fail-open**. Runs
after `PolicyEngine` allows (refusals don't burn quota); applies to native commands
and skill steps; a trip records a `:security_block` and returns `:rate_limited` →
**429**. Always-on supervised child; off in test. **Committed `a311bc4`** (6 new tests).

## SQLite flakiness — root-caused and fixed

The full suite was intermittently failing `(Exqlite.Error) Database busy` — same seed,
different results, in *unrelated* async tests. **Not from this work**: the committed 1B
baseline flaked identically. Root cause: SQLite is **single-writer** at the file level;
`pool_size: 5` gave each `async: true` test its own connection, so a common
read-then-write transaction (`SELECT` then conditional `INSERT`, e.g. `*_seeded/0`)
upgrades a shared lock to a write lock and, if another connection holds it, gets an
**immediate `SQLITE_BUSY` that `busy_timeout` cannot wait out** (by design, to avoid
deadlock). Fix: **`pool_size: 1`** in test so the sandbox serializes writers — verified
with 10 consecutive green runs; suite still ~7.4s (was never DB-parallelism-bound).
Also **hardened dev/prod** with a 5s `busy_timeout` (WAL keeps readers unblocked; this
makes the app's background writers wait rather than error). **Committed `ce44b16`, `67dfd61`.**

## Phase 2 — Cross-run memory (run summaries + FTS5 recall)

Tier-2 memory (per `s0.3`): a structured summary of each headless agent run, plus
full-text recall so a later run can answer "what have I done with X before?".

- **Migration** — `run_summaries` table + an **FTS5 external-content** virtual table
  over goal/detail/outcome, kept in sync by `AFTER INSERT`/`DELETE` triggers (the Ecto
  write path stays a plain insert). Verified FTS5 is compiled into this exqlite build.
- **`Memory` context + `RunSummary` schema** — `record_run/1` (best-effort, rescues so
  a summary write never breaks the run), `recent/1`, `search/2` (FTS5 `MATCH` ranked by
  bm25; user terms extracted + quoted so punctuation/operators can't break the query;
  empty → `{:error, :empty_query}`).
- **`Dispatcher.record_outcome/3`** writes a summary for every outcome
  (completed/failed/error), capturing a bounded tail of the agent's stdout as `detail`.
- **`memory_search`** command (safe-tier read), limit-capped.

**The bug worth noting:** the runner returns `agent: :claude` (an *atom*), which Ecto
rejected casting into a `:string` field — the summary silently returned
`{:error, changeset}` and never persisted. The **Dispatcher integration test caught it**
(it uses the real run shape, unlike the string-fed unit tests), confirming it would have
failed in production. Fixed by stringifying `agent`/`provenance`/`outcome` before cast.
**Committed `a64a85b`** (14 new memory tests + the integration test).

## Verification (cumulative)

- `mix test` — **606 tests, 0 failures** (started the day at 552). Suite is now
  **reliably green** across seeds (the flake is gone).
- Clean `--warnings-as-errors`; all changed files `mix format`-clean.
- **Still unverified by me** (need the running app, which the user drives): the live
  `./buster-claw run` round-trips for `save-note`, a `policy.md` deny, a rate-limit trip,
  and `memory_search`; plus a real unattended run writing a summary.

## Phase 3 — Self-improving skills (analyzer → propose → approve)

Heuristic self-improvement, no LLM. **Committed `de8356a`** (8 new tests).

- **`Analyzer`** reads recent `command_invoke` audit events, groups them into sessions
  (same caller within a time gap), and counts repeated consecutive command n-grams
  (length 2–3, requiring ≥2 distinct commands so a plain loop isn't proposed). Anything
  seen ≥ `:analyzer_min_occurrences` (default 3) is filed.
- **`Skills.Suggestions`** + `skill_suggestions` table (steps as JSON text): `record`
  dedupes a pending sequence by signature and bumps its count; `approve` writes the
  **enabled** `skills/*.md` via a new `Skills.write/1`; `reject` keeps it for history.
- **`Analyzer.Server`** — a slow (hourly), flag-gated GenServer that scans unattended;
  **off in test** (heeding the earlier always-on-child flakiness lesson).
- **Commands:** `skill_analyze` (restricted), `skill_suggestions` (safe read),
  `skill_suggestion_approve` (**gated** — creating an enabled skill is human-only,
  threat model T5), `skill_suggestion_reject`. A test asserts an untrusted caller is
  refused approval and nothing gets enabled.

## Phase 4 — Parallel swarm mechanism (bounded fan-out/fan-in)

The S0.4 mechanism — the novel, reusable core. **Committed `85761d7`** (8 new tests).

- **`Swarm.run/2`** over a supervised `SwarmTaskSupervisor` using
  `Task.Supervisor.async_stream_nolink/4`: `nolink` makes a crashing sub-run *data*
  (an `{:exit, _}`), `on_timeout: :kill_task` enforces the per-sub-run ceiling,
  `ordered` aligns results to the plan, `max_concurrency` caps fan-out.
- Every sub-run (ok/error/timeout/crash) yields one typed result and one
  `:command_invoke` Sentinel event tagged `{swarm_id, role, index}` — auditable, nothing
  silently dropped. Deterministic **quorum** fan-in: `{:ok, summary}` when successes ≥
  quorum (default majority), else `{:error, {:quorum_not_met, summary}}` carrying every
  result. Injectable `:runner` keeps tests from spawning real agents.
- **Deliberately deferred** (need design, not plumbing): the **LLM coordinator** that
  splits a Dispatch item into a plan, and the wallet-cents reservation (the wallet ledger
  is the user's financial domain; cost is bounded instead by the concurrency cap +
  `max_runs_per_shift`). `budget_cents` is carried through the plan shape for later.

## Roadmap status (where we are)

The full ecosystem-roadmap arc now has its substrate built + tested:

- **Phase 0–4 — complete.** Runtime composition skills (1A), declarative policy gate
  (1B), rate limits (1C), cross-run memory (2), self-improving propose/approve loop (3),
  and bounded parallel fan-out (4).
- **Remaining integration / follow-ups** (both integration items now **done** — see the
  second-session section below):
  - Phase 4 **coordinator** — ✅ shipped (`a1b84ee`).
  - Surface skills in `/api/commands` + CLI `commands` — ✅ shipped (`4808fcb`).
  - Nothing in Phase 4 has been driven in the **running app** yet (tests use an injected
    runner). Still open; needs a live shift the user drives.

## Second session — integration completion + command-menu cleanup

Picked the roadmap back up and closed the two remaining integration items, then did a
pass on the in-app terminal command menu (the "cmd-list" dropdown) to match the
headless-operator reality.

### Skills surfaced in the command surface (`4808fcb`)

`GET /api/commands` now appends runtime-discovered composition skills to the native
catalog, each entry tagged `source: native | composition`; the CLI `commands` prints a
`[skill]` marker. Native catalog stays `:persistent_term`-cached; skills are serialized
fresh per request (no cache to invalidate when a skill file is dropped/removed). Closes
the last Phase 1A integration gap. Test asserts a freshly-dropped `skills/*.md` shows up
tagged `composition` without a restart.

### Phase 4 coordinator (`a1b84ee`) — the roadmap's last substantive piece

A Dispatch item marked `strategy: "swarm"` is routed through the new
**`Swarm.Coordinator`** instead of the generic agent-pulls-queue pump:

- `coordinate/2` = one **serial planner** `AgentRunner` pass (decomposes the item's
  request into a JSON `[{role,prompt}]` plan, **depth-scanned** out of stdout so a stray
  `[` in a string can't desync it, validated, capped at `:swarm_max_subtasks`) → the
  unchanged `Swarm.run/2`. Planner + sub-runs independently injectable; an
  unparseable/empty plan is `:unplannable` and the caller **blocks** the item rather than
  guessing.
- **Dispatcher wiring** — claims one swarm item, runs the coordinator in the monitored
  child (whole swarm = one tick, so the crash-loop brake composes), threads queue
  provenance **fail-closed** into every sub-run, finishes the item (quorum-met → done,
  else blocked), bumps `dispatched_count` by the realized cost (planner + sub-runs)
  against the per-shift run cap, and writes a cross-run memory summary.
- **Surface** — new `strategy` column on `dispatch_items` (`single | swarm`) +
  `dispatch_strategy` command + CLI `dispatch strategy <id> <single|swarm>`. The generic
  claim path skips swarm items so it can't steal a coordinator-owned one. Wallet-cents
  reservation stays deferred (cost bounded by concurrency cap + run cap).
- 17 new tests (10 coordinator, 5 Dispatcher swarm-path, 2 dispatch-command). Design
  written up in `daily-growth/roadmaps/06-21-26-swarm-coordinator-plan.md`.

### Command-menu cleanup (`d12c984`, `5cf8c59`, `913751d`, `ada5251`)

The dropdown (`lib/buster_claw/terminal_commands.ex`) was all long-running *operational
processes* and missing the everyday work commands — and conflated three different
autonomy models. Reworked it to read as "what an operator/agent does in here":

- **Added** a **Dispatch Queue** group (list / claim / `strategy <id> swarm`) and a
  **Commands** group (`commands` / `runtime_status` / `memory_search`). `d12c984`
- **Reframed the Shift group around headless.** It only surfaced an *attended* `shift
  run`; the genuinely useful walk-away mode (an **unattended** shift = Dispatcher pump +
  run cap + kill-switch + no-sleep) wasn't in the menu. Now: Shift Status (default) /
  Start Headless Shift / Stop Shift. The key clarification: an unattended shift *is* "run
  headless indefinitely, but with brakes and a black box." `5cf8c59`
- **Consolidated Autopilot into the Shift group** ("Shift & Autopilot") so the two
  autonomy tools sit together with the trade-off legible (shift = supervised envelope;
  autopilot = lightweight, no brakes, **no shift needed**). `913751d`
- **Removed the dev Server group** — dev-only scaffolding (hardcoded `~/Developer/...`
  path, "run in your OWN terminal", meaningless from the in-app terminal, broken in a
  packaged build that spawns its own Phoenix). `ada5251`

Menu is now: Install · Mailman · Shift & Autopilot · Dispatch Queue · Commands · Prompts.

### Verification (second session)

- `mix precommit` green after the coordinator: **640 tests, 0 failures** (was 623).
- Each menu change: clean `--warnings-as-errors` + the 14 terminal-menu tests green.
- **Still unverified by me** (needs the running app the user drives): a live swarm —
  `dispatch strategy <id> swarm` then a shift that actually plans + fans out real agents.

### Open threads

- **Budget-gate tightening** (designed, not yet landed): cap a swarm's plan to the
  shift's *remaining* run budget so a fan-out can't overshoot the per-shift cap (today the
  pre-launch check is approximate — `n` isn't known until the plan exists; overshoot is
  bounded to the planner).
- Live-app validation of the swarm + the menu changes.

## Notes

- Roadmap + research artifacts live under `daily-growth/roadmaps/` and
  `daily-growth/research/`; `phase0-synthesis.md` is the decision record to read first.
