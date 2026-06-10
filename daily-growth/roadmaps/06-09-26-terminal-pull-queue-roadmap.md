# Terminal Pull-Queue Roadmap

## Goal

Replace the clunky "open a role, then email the agent to wake it up" pipeline
with a **pull model**: work lands in the SQLite queue, BusterClaw projects that
queue to the workspace Markdown the agent already reads
(`shift/<date>/Dispatch.md`), and a Claude Code session in the terminal pulls
items, does the work, and writes results back through the CLI.

No harness. No Anthropic API key owned by BusterClaw. The agent is whatever
Claude Code the human launched. BusterClaw's job shrinks to three things: feed
the queue, project it to the workspace, and record what the agent did.

This roadmap also **trims the agent-harness surface** (headless executor, MCP,
multi-channel delivery) that exists only to serve the old push model, and
**consolidates roles into the existing `job-descriptions/` contract.**

## Current State

- The Gmail poller (`./buster-claw mailman poll`) calls `gmail_sync`, which
  saves messages as Library documents. It does not clearly feed the Dispatch
  queue.
- `BusterClaw.Dispatch` already exists as a durable SQLite queue
  (`dispatch_items`) with `enqueue/1`, `enqueue_gmail/3`, `claim_next/2`,
  `mark_running/2`, `heartbeat/1`, `finish/3`, and PubSub on topic `"dispatch"`.
- **The workspace contract already defines the homes** (see `introduction.ex`):
  - `job-descriptions/` holds the role/job roster; `job-descriptions/README.md`
    is the authoritative roster.
  - The Dispatch queue is meant to project to `shift/<date>/Dispatch.jsonl`
    (append-only log) + `shift/<date>/Dispatch.md` (agent-readable).
  - `memory/trusted-email-senders.md` is the authority on which inbound senders
    may drive follow-through work.
  - Shifts already carry `job_key` / `job_name` / `job_description` fields.
- `BusterClaw.Orchestrator` ticks every 30s and **dispatches** due tasks to
  headless executors (`AgentRunner` spawns `claude -p`/`codex exec`,
  `Orchestration.Pipeline` runs commands). This is the API-key harness.
- `BusterClaw.Orchestration.Reporter` auto-sends shift lifecycle alerts through
  `BusterClaw.Delivery` (Slack/Discord/Telegram/webhook).
- MCP exists in both directions: outbound (`mcp.ex`, `mcp/client.ex`,
  `mcp/supervisor.ex`, `mcp/bootstrap.ex`) and inbound (`POST /mcp`,
  `mcp_controller.ex`, `mcp_live.ex`).
- "Role" is smeared across `TerminalCommands.roles`,
  `ShiftAssignment.role_key`/`job_key`, and `Dispatch.recommended_role_key` —
  none of which yet read from `job-descriptions/`.
- `BusterClaw.CLI` is a thin HTTP client over `/api/run` and `/api/commands`,
  authed by a local token file (this token is NOT the Anthropic API key).

## Design Principles

- **The agent just looks at the queue.** The communication mechanism is the
  filesystem. Claude Code reads and writes workspace files natively; we project
  the queue into `shift/<date>/Dispatch.md`, which the workspace contract already
  tells the agent to read. No injection, no special bridge.
- **SQLite is the source of truth. Markdown is the projection.** Writes go
  through the CLI into SQLite; `Dispatch.md`/`Dispatch.jsonl` are regenerated
  from SQLite, never hand-edited as authority.
- **Reuse the existing workspace contract.** Roles are job descriptions in
  `job-descriptions/`; the queue projects to `shift/<date>/Dispatch.*`. Do not
  invent parallel folders.
- **No BusterClaw-owned API key.** Delete the headless executor rather than
  freeze it, so the clunky push path cannot quietly stay alive.
- **Keep the local token API.** `/api/run` + the token file are how the terminal
  CLI talks to localhost Phoenix. This stays — it is the backbone of the pull
  model, not part of the harness being cut.
- **Trims are reversible.** Everything cut is recoverable through git; nothing
  cut blocks the new spine.

## The New Spine

```text
Gmail poller (./buster-claw mailman poll)
   └─> Dispatch.enqueue_gmail ──> SQLite dispatch_items       (source of truth)
                                        │
   PubSub "dispatch" ─> DispatchProjector ─> shift/<date>/Dispatch.md (+ .jsonl)
                                        │
   Claude Code session (human's own, no API key) reads Dispatch.md
                                        │
        does the work, then:  ./buster-claw dispatch done <id> --note "..."
                                        │
                          CLI ─> /api/run ─> SQLite ─> re-project Markdown
```

The only genuinely new code is a small projector GenServer (subscribes to the
existing `"dispatch"` topic, re-renders `Dispatch.md` and appends `Dispatch.jsonl`
on each event) and a `dispatch` verb on the CLI. Everything else is deletion and
rewiring.

## Trim List

Cut now ("trim now" depth). All callers verified by dependency trace.

| Component | Action | Why it is safe |
| --- | --- | --- |
| `BusterClaw.AgentRunner` | Delete | Only caller is the Orchestrator dispatch loop. This is the API-key harness. |
| `BusterClaw.Orchestration.Pipeline` | Delete | Only caller is the Orchestrator dispatch loop. |
| `BusterClaw.Orchestration.Reporter` | Delete | Only driven by Orchestrator lifecycle events. |
| MCP outbound (`mcp.ex`, `mcp/client.ex`, `mcp/supervisor.ex`, `mcp/bootstrap.ex`, `Automation.MCPServer`, `MCP.Registry`) | Delete | Zero coupling to queue/agent path. Claude Code manages its own MCP. |
| MCP inbound (`mcp_controller.ex`, `POST /mcp`, `mcp_live.ex`) | Delete | Redundant mirror of the command catalog; the CLI already exposes commands. |
| Multi-channel `Delivery` fan-out + `delivery_live` + `delivery_dispatch_all` | Trim to dormant | Keep `DeliveryDestination`/`DeliveryAttempt` schema for one optional "ping me" path; cut the Slack/Discord/Telegram machinery and its UI. |
| `BusterClaw.Orchestrator` GenServer | Modify → janitor | Remove the auto-dispatch tick. Keep only: reclaim expired claims + drive projection. |
| Orchestration schemas (Shift, Task, AgentRun, Dispatch.Item) | Keep | This is the queue the new model reads. |
| Local HTTP API + token (`api_token`, `api_auth`, `api_controller`, `/api/run`, `/api/commands`, `cli.ex`) | Keep | Backbone of the pull model. |

Command catalog cleanup: remove `mcp_server_*` and `delivery_dispatch_all`
commands; keep delivery destination CRUD only if the optional ping path is kept.

Note: `introduction.ex` currently advertises MCP and multi-channel delivery as
capabilities. Update the workspace guide text when these are cut.

## Roles Are Job Descriptions

Roles already have a defined home — use it instead of a new concept. A role is a
job description under `job-descriptions/`, with `job-descriptions/README.md` as
the roster the agent is told to read.

```text
workspace/job-descriptions/
  README.md            # the roster: which jobs exist, one-line each
  <job-key>.md         # one job description: mandate, triggers, do / do-NOT,
                       #   which Dispatch items it owns, hand-off contract
```

- `TerminalCommands.roles`, `ShiftAssignment.role_key`/`job_key`, and
  `Dispatch.recommended_role_key` all resolve against `job-descriptions/`
  (matched by `<job-key>`).
- Opening a job (`./buster-claw terminal open <job-key>`) spawns a terminal
  whose Claude Code is pointed at that job's `<job-key>.md` and the Dispatch
  items recommended for it.
- Consolidate the currently-broad roles into a small, sharp roster. First job:
  `mail-triage`.
- Keep `memory/trusted-email-senders.md` as the gate on which senders create
  actionable Dispatch items.

## Implementation Phases

### Phase 1: Cut the Harness Surface

- Delete `AgentRunner`, `Orchestration.Pipeline`, `Orchestration.Reporter`.
- Delete MCP outbound and inbound modules, schema, registry, LiveView, route.
- Remove deleted children from `application.ex` supervision tree.
- Remove `mcp_server_*` and `delivery_dispatch_all` from the command catalog.
- Trim `Delivery` to schema-only (dormant); remove `delivery_live` and its
  route, or hide it behind a flag.
- Update `introduction.ex` to drop MCP / multi-channel delivery from the
  advertised command surface.
- Delete the corresponding test files.

Acceptance:

- `mix compile --warnings-as-errors` is clean.
- `mix test` is green (with harness/MCP/delivery tests removed).
- App boots with no Orchestrator dispatch, no MCP supervisor, no Reporter.
- Gmail sync, the terminal, the CLI, and the queue schemas are untouched.

### Phase 2: Orchestrator Becomes a Janitor

- Strip the auto-dispatch tick from `orchestrator.ex`.
- Keep a slow tick (or PubSub-driven trigger) that reclaims expired
  `dispatch_items` claims so a dead session's items return to `queued`.
- Decide whether Shift/Task/AgentRun stay as-is or get a follow-up simplification
  (out of scope here; the schemas remain).

Acceptance:

- No process spawns `claude`/`codex` anywhere in `lib/`.
- An item claimed by a session that never finishes returns to `queued` after the
  reclaim window.

### Phase 3: Dispatch Projector

- Add `BusterClaw.DispatchProjector` GenServer.
- Subscribe to the `"dispatch"` PubSub topic.
- On `:dispatch_item_queued|claimed|running|finished`, re-render
  `shift/<date>/Dispatch.md` and append the event to `shift/<date>/Dispatch.jsonl`
  (the existing workspace convention).
- `Dispatch.md` lists open items grouped by recommended job: id, source, sender,
  subject, summary, body excerpt, status. Keep it scannable.
- Treat ingested content as untrusted: fence the email body so the agent reads it
  as data, not instructions (ties to the prior security finding).

Acceptance:

- Enqueuing an item updates `Dispatch.md` within one projection cycle and appends
  one `Dispatch.jsonl` line.
- Finishing an item moves it out of the open list and is reflected in both files.
- Projection of `Dispatch.md` is idempotent: re-running produces the same file.

### Phase 4: CLI `dispatch` Verb

- Add subcommands over the existing `/api/run`:
  - `dispatch list [--job <key>] [--status queued]`
  - `dispatch show <id>`
  - `dispatch claim [--job <key>]` (claims next, returns the item)
  - `dispatch done <id> [--note ...]` / `dispatch block <id> [--note ...]`
- Back them with `Dispatch` functions (already present) exposed as safe-tier
  commands in the catalog.
- Human-readable output by default; `--verbose` for raw JSON (match the existing
  mailman output convention).

Acceptance:

- `dispatch claim` atomically claims exactly one item (the existing
  compare-and-swap already guarantees this under SQLite).
- `dispatch done` flips the item to `done` and triggers re-projection.
- Two concurrent `dispatch claim` calls never claim the same item.

### Phase 5: Wire the Poller to the Queue

- Make `mailman poll` enqueue via `Dispatch.enqueue_gmail` (dedupe key already
  exists as `gmail:<message_id>`), in addition to or instead of the Library
  save. Gate actionable items on `memory/trusted-email-senders.md`.
- Decide the relationship between Library documents and dispatch items (link the
  item to the saved doc via metadata, or stop double-storing).

Acceptance:

- A new email from a trusted sender appears as a queued dispatch item and in
  `Dispatch.md`.
- Re-polling the same message does not create a duplicate item.

### Phase 6: Job-Description Consolidation

- Define the `job-descriptions/` reader (`BusterClaw.Jobs` or similar) over
  `README.md` + `<job-key>.md`.
- Migrate `TerminalCommands.roles`, `ShiftAssignment.role_key`/`job_key`, and
  `Dispatch.recommended_role_key` to resolve against it.
- Author a tight `mail-triage.md` and update `README.md` roster.
- `terminal open <job-key>` loads the job description and points at its Dispatch
  items.

Acceptance:

- Opening `mail-triage` gives a terminal whose Claude Code sees that job's
  description and its recommended Dispatch items.
- Editing `README.md` / removing a `<job-key>.md` cleanly updates the menu and
  resolver.

### Phase 7: Carryover Hardening (from prior review)

- Startup reconciliation: on boot, return orphaned `claimed`/`running` items to
  `queued` (replaces the missing agent-run reaper now that runs are gone).
- Apply `Task.async_stream` to the IO fan-out sites (`gmail_sync` message fetch,
  any remaining multi-target loops) for throughput.

Acceptance:

- A hard restart mid-claim leaves no item stuck in `claimed`/`running`.
- Gmail sync of N messages issues bounded-concurrency fetches, not N sequential.

## Test Plan

- `DispatchProjector`: enqueue/claim/finish each update `Dispatch.md` and append
  `Dispatch.jsonl`; `Dispatch.md` render is idempotent; untrusted body is fenced.
- CLI `dispatch`: list/show/claim/done happy paths; concurrent-claim safety; bad
  id handling.
- Poller: `mailman poll` enqueues a dispatch item for a trusted sender; re-poll
  dedupes; untrusted sender does not create an actionable item.
- Jobs: reader maps all `role_key`/`job_key` usages to `job-descriptions/`;
  unknown job returns nil; `terminal open <job-key>` resolves description + items.
- Reconciliation: simulated stale `claimed` item returns to `queued` on boot.
- Regression: confirm deleted surfaces are gone (no `/mcp` route, no Orchestrator
  dispatch) and that compile/test stay green.

## Open Questions

- `Dispatch.md` lifecycle: does the date-scoped `shift/<date>/` folder fit a
  long-running pull model, or do we also want a date-independent "open items"
  view the agent can always read?
- Do dispatch items and Library documents stay separate, or does the item link to
  the saved doc and the doc stop being the primary store?
- Does the optional `Delivery` "ping me when X" path survive at all, or is it cut
  entirely until there is a concrete need?
- Should `claim` be explicit (agent runs `dispatch claim`) or implicit (reading
  `Dispatch.md` marks items in-progress)? Explicit is safer and recommended.
- One job description per file (`<job-key>.md`) or per folder (`<job-key>/`) if a
  job needs more than one context file?
- Reclaim window length for abandoned claims?

## First-Pass Recommendation

Build in this order: **Phase 1 (cut) → Phase 3 (projector) → Phase 4 (dispatch
CLI) → Phase 5 (poller wiring)**. That sequence reaches an end-to-end pull loop —
trusted email in, item in `Dispatch.md`, agent pulls and completes via CLI — as
early as possible. Phases 2, 6, and 7 (janitor, job consolidation, hardening)
follow once the loop is proven. Keep claims explicit and the email body fenced as
untrusted from the first projector commit.
