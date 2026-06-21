# Chat / Harness Enhancement Roadmap

_Last updated: 2026-06-21_

Enhancements to the homepage chat (`StatusLive` → `BusterClaw.Agent.Chat`): a live
**thinking timer**, a **message queue** you can pile ideas into while a turn runs,
the ability to **interrupt** a running turn, all wrapped in a Tetris-style "next
pieces" rail.

## The constraint that shapes everything

The harness spawns a **fresh `claude -p … --resume <session_id>` subprocess per
turn** (`Chat.handle_call({:send, …})`). The prompt is fixed at spawn; there is no
stdin channel into a running turn. Verified against current Claude Code / Agent SDK
docs:

- **True mid-thought injection is not available** with the CLI harness.
  `--input-format stream-json` (persistent process) exists but is undocumented/risky
  (open issues #24594/#24612), and even the Agent SDK *queues the next message until
  the current turn finishes* — nobody exposes splicing into in-flight reasoning.
- **Killing mid-turn loses that turn.** `--resume` reverts to the last *completed*
  turn; partial work is not checkpointed.

So "drop ideas in while it's thinking" resolves into **two honest mechanics**:

| | Behaviour | Cost |
|---|---|---|
| **Soft drop** (queue) | Idea waits, folds into the *next* turn | Nothing lost, reliable today |
| **Hard drop** (interrupt) | Kill the in-flight turn now, restart with the new idea | Lose the running turn's output |

This maps onto the Tetris metaphor: **soft drop = let the piece fall into the
queue; hard drop = slam it down now (= interrupt).** Same gesture vocabulary, two
semantics.

## Phases

### Phase 0 — Thinking timer (coarse) · ~½ day · **in progress**
Live monospace counter that ticks from turn start until first token (time-to-first-
token), then freezes; the duration is folded into the `:meta` line (`thought 3.1s ·
2 turns · $0.01`). No protocol reverse-engineering, no DB migration — the duration
rides along in the meta message text, so it survives reload.

- `chat.ex` — stamp `run.first_token_at` on the first `:assistant_text`/`:tool_use`;
  broadcast `{:thinking, ms}`; prepend `thought Xs` to the result meta line.
- `status_live.ex` — `:chat_thinking` assign (`nil | :running | {:done, ms}`);
  `thinking_chip` component in the chat header.
- `app.js` — `ThinkingTimer` hook drives the live count client-side (no server spam),
  freezes to the server-authoritative ms on `{:thinking, …}`.

### Phase 1 — Queue backend · ~1 day · **shipped 2026-06-21**
`Chat` gained `queue: []`. `send_message` while `:running` **enqueues** (returns
`:ok`) instead of `{:error, :busy}`; `finish_run` → `dispatch_next/1` pops the front
and starts it as the next turn (no idle flicker between turns), or broadcasts `:idle`
when empty. `{:queue, items}` rides the existing PubSub topic. `Chat.queue/1` and
`Chat.remove_queued/2` round out the API. The queue is in-memory only — items not yet
sent are dropped on restart. One piece = one turn (clean `--resume` threading);
optional "merge selected" left for later. `status_live` renders a minimal queue strip
above the input (with per-item cancel) — Phase 2 turns it into the Tetris rail.

### Phase 2 — The Tetris Rail UI · ~1–2 days · **shipped 2026-06-21**
`:chat_queue` renders as tetromino "pieces" (7 classic shapes/colors, picked by id so
a piece keeps its shape for life). Front piece is "armed" (hazard border + NEXT tag).
Drag-reorder via the `QueueRail` hook (HTML5 DnD, optimistic DOM reorder →
`reorder_queue` event → `Chat.reorder_queue/2` re-broadcasts canonical order). Cancel
per-piece (hover ×). Entrance animation `ic-piece-in`; exit via `phx-remove` (JS.hide
transition); landed messages get `ic-drop-in` — the back half of a "lock-in." All
motion is CSS/JS, `prefers-reduced-motion` honored.

**Deferred from this phase:** inline edit-before-consumption (add an update API + an
editable field later); a direction-aware lock animation differentiating dispatch vs
delete (currently one unified exit).

**Amended (post-eyeball):** the per-piece tetromino glyph was dropped on the user's
call — pieces now show a plain drag-handle (`hero-bars-2`). The rail mechanics (armed
front, drag-reorder, animations) stay.

### Phase 3 — Hard-drop / Stop · ~1 day · **shipped 2026-06-21**
`Chat.interrupt/1` kills the in-flight run (`AgentRunner.kill_port`, guarded by
`is_port/1`), emits a `:meta` "interrupted" marker, audits it (`:interrupted`, info),
then `finish_run` → `dispatch_next` hands off to the queue (next turn runs, or idle).
`Chat.barge/2` moves a queued piece to the front and cuts the running turn so it runs
next — the Tetris hard-drop. UI: a **Stop** button in the chat header (with an `Esc`
hint) + a window-level Esc key in the `AgentChat` hook, both gated on `data-running`
so Esc only fires mid-run. `barge/2` is wired (`barge_queued` event) and tested but
has no per-piece UI button yet.

### Phase 3 — Hard-drop / Cut · ~1 day
`Chat.interrupt/1`: kill the port (reuse `AgentRunner.kill_port`), flush the partial
buffer into an `interrupted` message, then consume the next queued piece. Esc binding
+ a Cut button. Any queued piece can be flagged "barge" to hard-drop instead of wait.

### Phase 4 — (Spike, optional) Persistent streaming session
Investigate `--input-format stream-json` as a long-lived process for: lower latency
(no per-turn respawn), real per-thinking-block timers via `thinking_delta` blocks, and
the closest-to-mid-turn steer the platform allows. **Undocumented protocol — timebox a
spike before committing.** Only after 0–3 prove the UX.

## Sequencing
0 first (visible, trivial, momentum) → 1+2 together (rail is pointless without the
backend) → 3. Treat 4 as a research bet, not a commitment.
