# 06-10-2026 Summary

## Today

Completed the final phases of the terminal pull-queue rewrite and merged the
whole arc to `main`. (Per-phase detail for Phases 1–7 lives in the
`06-09-26-summary.md` running log; this entry records today's milestone.)

### Phase 6 — job-description consolidation

- Made `job-descriptions/` the single definition of the specialist roles every
  scattered `role_key`/`recommended_role_key` already pointed at.
- New `BusterClaw.Jobs` reader over `<workspace>/job-descriptions/<key>.md`
  (frontmatter `name`/`summary` via `Library.Frontmatter`); `README.md` is the
  roster. `Jobs.ensure/0` (app startup) seeds a starter `mail-triage` job +
  roster + a `memory/trusted-email-senders.md` template that trusts nobody by
  default (non-parseable placeholders), never overwriting operator files.
- Added `job_list` / `job_show` commands and CLI `jobs list` / `jobs show`.
- Rewrote the agent guide (`introduction.ex`) section to "Jobs & the pull queue".
- Gitignored the dev-workspace artifact dirs so runtime seeding doesn't dirty
  the repo tree.

### Phase 7 — carryover hardening (from the original code review)

- `Dispatch.reclaim_orphans/0` returns in-flight (`claimed`/`running`) items to
  `queued` on boot (called from `DispatchProjector.init`), so a hard restart
  can't strand work.
- Parallelized the Gmail message fan-out with `Task.async_stream`
  (`max_concurrency: 5`, `ordered`, `timeout: :infinity`) — the N+1 sequential
  fetch fix. Req.Test stubs + the Ecto sandbox reach the task subprocesses via
  `$callers`, so existing Gmail tests pass unchanged.

### Merge to main

- Merged `phase1-cut-harness` → `main` with `--no-ff` (merge commit `28c3ea7`)
  to preserve the full phase history under one merge.
- The app is now the terminal-first, no-API-key-of-its-own pull model: a human's
  Claude Code session reads the fridge (`shift/Dispatch.md`) and writes back
  through the audited `buster-claw dispatch` CLI.

## Verification

- On `main` after merge: `mix test` — 363 tests, 0 failures.
- `mix compile --warnings-as-errors` and `mix format --check-formatted` clean.
- Working tree clean. Nothing pushed yet (local `main` only).

## Notes

- Roadmap `daily-growth/roadmaps/06-09-26-terminal-pull-queue-roadmap.md` is fully
  implemented (Phases 1–7).
- Deferred follow-ups (out of scope, for whenever):
  - `terminal open <job>` could auto-load the job's context into the session
    (deeper `TerminalLive` work).
  - The `Delivery` "ping me when X" path is still dormant, pending a concrete need.
