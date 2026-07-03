# 07-02-2026 Summary

Commissioned a **veteran-perspective review of the whole app** and immediately
worked the top of its punch list. The review + follow-through roadmap live in
`daily-growth/07-02-26-veteran-review.md`; Session 1 (the security-critical
slice) shipped the same day.

## Veteran review (new doc)

A full read of the codebase — supervision tree, policy engine, dispatcher, SSRF
guard, auth plug, CI, tests, commit history. Verdict: the architecture thesis
(be the auditable command surface; the intelligence is remote) is right and the
security model is real (timing-safe token compare, token-derived trust tiers,
fail-closed provenance, budget governor). Pushback items were concrete, not
vibes: an actual IPv6 hole in the SSRF guard, README front-door drift, catalog
tier metadata with no invariant test, `String.to_atom` on parsed input, and the
`daily-growth/` archive growing strata. Appended a prioritized P0/P1/P2 roadmap
with per-item steps, files, and done-whens, sequenced into four sittings.

## Session 1 — shipped

**P0-1 · SSRF guard hardened (`lib/buster_claw/url_guard.ex`).** The DNS path
resolved IPv4 only, so an **AAAA-only hostname bypassed the IPv6 blocklist**
via the fail-open branch — a real hole for a guard whose whole job is vetting
prompt-injected URLs. Now: resolution runs over **both** `:inet` and `:inet6`,
every resolved address is vetted, and a host that resolves to nothing in either
family **fails closed** (`{:error, :unresolvable_host}`) with a logged warning.
`validate/2` grew test-only `:resolver` / `:resolve_dns` opts so the new tests
inject resolution instead of touching global config (async-safe). 8 new tests
cover AAAA-only → loopback/link-local/ULA/IPv4-mapped, dual-stack with one bad
family, unresolvable → closed, v6-only public → allowed, and literals never
reaching the resolver. 18/18 pass; credo-clean (also folded the redundant last
`with` clause it flagged).

**P0-2 · DNS rebinding governed, not forgotten.** The remaining TOCTOU gap is
now a written, bounded, ticketed risk instead of a moduledoc aside: new
**"Known accepted risks"** section in `docs/LOCAL_TRUST.md` (why exposure is
bounded: per-hop re-validation shrinks the window to a single request; the
command API still wants a Bearer token; softest target is the sidecar) and
**Shortlist #13** for the real fix (resolve-once + pin the connection to the
vetted IP, with the SNI/Host caveats noted).

**P1-1 · Front-door drift fixed.** README still told users to run
`./buster-claw mailman poll` — a verb that no longer exists (it falls through to
an unknown `mailman_poll` command). Fixed both README occurrences to
`on-duty`, corrected `docs/COMMAND_SURFACE.md` (the mailman startup profile's
default command is `./buster-claw on-duty`, verified against
`TerminalCommands.startup_command/1`), and cleaned two stale doc-comments in
`terminal_workspace.ex`.

## Verification

- `mix test test/buster_claw/url_guard_test.exs` — 18/18.
- Full suite: 668 tests, **10 failures — all pre-existing on a clean tree**
  (verified via stash/run/pop): VoiceLive ×2, StatusLive ×7, SplitLive ×1.
  Looks like fallout from the 06-28 voice STT demolition; **needs its own
  cleanup pass** (noted for Session 3's hygiene day).
- `mix compile --warnings-as-errors` clean; credo clean on touched files.

## Session 2 — shipped (same day)

**P0-3 · Catalog tier invariants
(`test/buster_claw/commands/catalog_invariants_test.exs`, 7 tests).** The trust
model keys off tier/gated metadata in a 1,246-line data file; now a typo can't
loosen it silently. Structural checks (unique policy-glob-friendly names, valid
tier/type, boolean gated, non-empty descriptions), **gated ⟹ restricted**, a
destructive-name heuristic (`send|delete|create|update|save|reply|…` must be
restricted or gated — current catalog is clean, exception allowlist starts
empty and is itself checked for staleness), and the crown jewel: a **safe-tier
snapshot** asserting the exact sorted 60-command list an MCP/agent token may
run. Any tier promotion now fails CI with the command named and a
regeneration one-liner in the test comment.

**P1-2 · Atom-minting closed off repo-wide.** Fixed the runtime sites — 
`calendar_live.ex` (param-derived view → explicit `view_atom/1` clauses),
`google/oauth.ex` (`get_value` → `to_existing_atom` + rescue-to-nil),
`policy_engine.ex` (guarded action token → explicit `action_atom/1`, call
eliminated) — then enabled **Credo `UnsafeToAtom`** (moved from the disabled
list), which caught four more sites grep missed: `orchestration.ex`
(`:"#{counter}_count"` → explicit `counter_field/1` clauses), `commands.ex`
(compile-time CRUD codegen — false positive, justified
`credo:disable-for-lines`), and two test files (unique-name pattern justified;
`commands_test` now uses `to_existing_atom` with a rescue that reads as
"missing implementation" instead of a confusing raise). Check runs repo-clean:
290 files, 0 issues.

**Verification:** 675 tests (was 668, +7), same 10 pre-existing Voice/Status/
Split failures, none new. `--warnings-as-errors` clean; UnsafeToAtom clean;
the 7 strict-credo findings in touched files are all pre-existing lines (part
of the known ~50 on main).

## Next (Session 3, per the roadmap)

- **P1-3** — triage `erl_crash.dump` (read the `Slogan:` line), sweep root
  artifacts, verify `.gitignore`.
- **P2-2 / P2-1** — flatten `old-maps/older-maps/` into a single `archive/`;
  split `catalog.ex` by domain now that the invariant tests watch its back.
- Also queued from Session 1: the 10 pre-existing LiveView test failures
  (voice-demolition fallout) need their own pass.
