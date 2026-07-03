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

## Next (Session 2, per the roadmap)

- **P0-3** — catalog tier invariant test (denylist heuristic + safe-tier
  snapshot) so a one-char tier typo can't loosen the trust model.
- **P1-2** — replace the `String.to_atom` sites (calendar_live, oauth) and turn
  on Credo's `UnsafeToAtom`.
