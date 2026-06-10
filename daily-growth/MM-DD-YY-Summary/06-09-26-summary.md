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
- Open question to settle before Phase 3 (`DispatchProjector`): whether the
  projector writes the date-bound `shift/<date>/Dispatch.md` or an additional
  date-independent "open items" view for a long-running pull agent.
