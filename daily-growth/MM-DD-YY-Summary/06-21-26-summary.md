# 06-21-2026 Summary

A planning-then-build day on the **Claw-ecosystem roadmap**. Pressure-tested a
Kimi-authored roadmap against the actual code (it was wrong in seven places), ran
**Phase 0** as a six-spike research shift, then shipped **Phase 1A** — runtime-addable
**composition skills**. Suite green at **577** (was 552).

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

## Roadmap status (where we are)

- **Phase 0 — complete.** Six notes + chosen schema + threat model; exit criteria met.
- **Phase 1A — done** (composition skills land at runtime, gated per step).
- **Phase 1B/1C — next** (PolicyEngine over `policy.md`; per-caller rate limits;
  `/api/commands` skill listing).
- **Phases 2–4 — designed, not started** (memory Tiers 1+2; self-improve
  analyzer→proposer; bounded parallel fan-out).

## Notes

- Roadmap + research artifacts live under `daily-growth/roadmaps/` and
  `daily-growth/research/`; `phase0-synthesis.md` is the decision record to read first.
