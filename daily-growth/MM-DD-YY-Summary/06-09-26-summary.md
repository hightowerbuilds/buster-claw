# 06-09-2026 Summary

## Today

### Codebase review and direction

- Reviewed the whole app end-to-end (core domain, web layer, Tauri shell,
  migrations, docs) and produced a senior-level assessment: strong trust/audit
  architecture, the orchestration engine as the heart, and the main gaps being
  crash-recovery plumbing and underused Elixir parallelism.
- Discussed and rejected a Rust + GPUI rewrite: it optimizes UI rendering the app
  doesn't need while discarding the OTP supervision that carries the hardest
  problem (supervised concurrent orchestration).
- Decided the product direction: move from the clunky "open a role, then email the
  agent" push pipeline to a **pull model** where a terminal Claude Code session
  reads the work queue from SQLite/Markdown — no harness, no app-owned API key.

### Pull-queue roadmap

- Wrote `daily-growth/roadmaps/06-09-26-terminal-pull-queue-roadmap.md`.
- Aligned it to the existing workspace contract (`introduction.ex`): roles are
  job descriptions in `job-descriptions/`; the queue projects to the established
  `shift/<date>/Dispatch.md` + `Dispatch.jsonl`; CLI verb is `dispatch`.
- Produced a verified dependency map of trim candidates (headless executor, MCP,
  delivery) separating the executor from the queue schemas that are kept.

### Phase 1 — cut the agent-harness surface

- Deleted the headless executor: `BusterClaw.AgentRunner`,
  `BusterClaw.Orchestration.Pipeline`, `BusterClaw.Orchestration.Reporter`.
- Deleted MCP in both directions: outbound (`mcp.ex`, `mcp/client.ex`,
  `mcp/supervisor.ex`, `mcp/bootstrap.ex`, `Automation.MCPServer`,
  `MCP.Registry`) and inbound (`mcp_controller.ex`, `POST /mcp`, `mcp_live.ex`).
- Removed the deleted children from the supervision tree (`application.ex`),
  including the now-unused `RunnerSupervisor`.
- Trimmed the command catalog: removed `mcp_server_*` and `delivery_dispatch_all`
  (74 → 67 commands). `Automation` no longer exposes MCP server CRUD.
- Removed the `/mcp` routes (live + `POST`) and all MCP references from
  `advanced_tabs`, `layouts`, `split_live`, `settings_live`, and `runtime/status`.
- De-advertised MCP / multi-channel delivery in the workspace guide
  (`introduction.ex`) and the first-run wizard (`setup_live.ex`).
- Converted `BusterClaw.Orchestrator` into a **lease janitor**: it no longer
  dispatches headless runs (those modules are gone). It now only enforces the
  shift window + kill switch and reclaims expired task leases. This pulled the
  Phase 2 janitor conversion forward, as the Orchestrator directly referenced the
  deleted executors.

### Delivery scoping decision

- Kept `Delivery` dormant rather than deleting it: the destinations UI
  (`/delivery`, `/advanced`) and `Delivery.dispatch_all` stay (no callers now,
  still tested) so the dock's Advanced tab keeps working. Full removal is gated
  on the roadmap's open "ping me when X" question.

## Verification

- `mix compile --warnings-as-errors` clean.
- `mix format --check-formatted` clean.
- `mix test` — 335 tests, 0 failures (down from 351 as the harness/MCP test files
  were removed).
- Grep confirmed zero remaining functional references to any cut symbol
  (`AgentRunner`, `MCP.*`, `Pipeline`, `Reporter`, `mcp_server`,
  `delivery_dispatch_all`, `RunnerSupervisor`).
- Net change: 16 files deleted, roughly −2,000 lines.

## Notes

- Behavior change: the orchestration new-task wizard still creates tasks, but
  nothing auto-runs them now — expected until the pull loop (Phases 3–5) exists.
  Noted in the `OrchestrationLive` moduledoc.
- Work done on branch `phase1-cut-harness`.

## Phase 3 — Dispatch Projector (later today)

- Resolved the open date-scoping question: do **both** views ("fridge AND
  diary"), written concurrently. Updated the roadmap's Phase 3, spine, and a new
  "Decided" section.
- Enriched the `"dispatch"` PubSub broadcast to carry the item
  (`{:dispatch, event, item}`) — no existing subscribers, so safe — and added
  `Dispatch.list_open/0` (queued/claimed/running, oldest first).
- Added `BusterClaw.DispatchProjector` GenServer. On each dispatch event it
  writes two views of the SQLite queue:
  - **Fridge** — `shift/Dispatch.md`: full overwrite of currently-open items,
    grouped by job. The agent's primary read.
  - **Diary** — `shift/<date>/Dispatch.md` (readable, overwritten) +
    `shift/<date>/Dispatch.jsonl` (append-only, one line per primary event).
- Coherence guarantees: `.md` renders are pure functions of their inputs (no
  wall-clock) so they're byte-idempotent; only the `.jsonl` is appended. Writes
  are best-effort (a filesystem error logs, never crashes the projector).
- Untrusted inbound content (email body) is rendered as an indented code block
  (4-space prefix) so it's inert data — it can't break out or inject markdown.
- Gated behind `:dispatch_projector_enabled` (config), off in test so unrelated
  dispatch tests don't write files; projector tests start it against a tmp
  workspace and a pinned `:local_today`.

## Verification (Phase 3)

- `mix compile --warnings-as-errors` and `mix format --check-formatted` clean.
- `mix test` — 340 tests, 0 failures (+5 projector tests).
- Projector tests assert real file output: fridge grouping/open-count, the
  indented fence on an injection-style body, `.jsonl` `queued`/`claimed`/
  `finished` lines, and fridge-render idempotency.

## Phase 4 — `dispatch` CLI verb (write-back)

- Added the queue write-back surface so a terminal Claude Code session can act on
  the fridge: claim work, complete it, or block it — all via the local CLI/API.
- Server commands (all `:safe`, in `commands.ex`): `dispatch_list`
  (open items, `--status`/`--job`/`--limit`), `dispatch_show`, `dispatch_claim`
  (`--job`-scoped), `dispatch_done`, `dispatch_block` (with optional `--note`).
  Mutating ones are audited through Sentinel like every consequential command.
- Extended `Dispatch.claim_next/2` with a `:role` filter so a job can pull only
  its own items even when another job's item is older.
- CLI (`cli.ex`): `dispatch list|show|claim|done|block` subcommands with compact
  human-readable output by default and `--verbose` for raw JSON, matching the
  mailman convention.
- The end-to-end pull loop is now wired except intake: email → (Phase 5) →
  queue → fridge → agent `claim`/`done`. A claimed item stays on the fridge;
  a done/blocked item drops off and the diary keeps the record.

## Verification (Phase 4)

- `mix compile --warnings-as-errors` and `mix format --check-formatted` clean.
- `mix test` — 349 tests, 0 failures (+9: dispatch command + CLI formatter tests).
- Tests cover: list/claim/show/done/block command paths, job-scoped claim
  ordering, empty-queue claim, safe-tier enforcement, and CLI output formatters.
