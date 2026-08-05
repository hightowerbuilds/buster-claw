# Chat live steering — let the operator change the work while it is happening

**Scoped 08-04-26 · Status: PHASES 0 AND 1 COMPLETE — probes run and the
transport boundary is extracted. No live steering yet; that is Phase 2.**

> **Headline: all three harnesses steer.** Claude, Codex, and OpenCode each
> accepted a mid-run correction into the *active* turn, verified by filesystem
> effect and by a single turn/idle boundary. The `:interrupt_then_resume`
> contingency written into Phase 4 is not needed. Probe scripts are
> `scripts/probe_{claude_duplex,codex_appserver,opencode_server}.exs`; findings
> are in the Phase 0 section below and supersede any earlier claim in this doc.

Buster Claw's chat now lets an operator type while an agent is working, but the
new message waits in an in-memory queue until the current run exits. That is
useful, and it is not steering. If the model is ten minutes into the wrong task,
"I meant the failing integration test, not the unit test" should reach the work
that is happening now rather than become a clean new turn after the mistake is
finished.

This roadmap adds that missing behavior across all three supported harnesses:
**Claude Code, Codex CLI, and OpenCode**. It preserves the existing next-turn
queue as a separate, deliberate choice.

The product contract is:

> While an agent is running, the operator can either **steer now** or **queue
> next**. Buster Claw says which happened, and never calls a queued message
> "delivered" merely because a backend accepted an HTTP request.

---

## Vocabulary — three actions that must not collapse into one button

| Action | Meaning | What happens to active work |
|---|---|---|
| **Steer now** | Add new user intent to the active turn | The same turn continues with the new instruction at the backend's next safe boundary |
| **Queue next** | Save a complete follow-up turn | The active turn is unchanged; the message starts after it completes |
| **Interrupt and run** | Stop the active turn, then start this message | Partial model output is abandoned; already-completed external effects are not undone |

The existing `Chat.queue/1`, `reorder_queue/2`, `remove_queued/2`, `interrupt/1`,
and `barge/2` are the second and third rows. The first row is new.

"Steer now" also does **not** mean that a model can read a message in the middle
of one already-running inference request. No harness can alter tokens that have
already been sampled. It means the backend accepts the message into the active
turn and presents it at the next model/tool boundary. The UI must distinguish:

- **sending** — the browser submitted the message;
- **accepted** — the harness acknowledged it for the active turn;
- **queued** — there was no steerable turn, so it will run next;
- **failed** — the harness rejected it and Buster Claw retained it for retry.

We can prove accepted. We cannot prove "the model read this exact sentence" and
must not manufacture that claim.

---

## The lay of the land

### What already exists

- `BusterClaw.Agent.Chat` owns one process per conversation and serializes work.
- Each message currently spawns a short-lived headless process through
  `AgentRunner.open/2`; the process exits at the end of the turn.
- Claude and OpenCode sessions are resumed between processes. Codex currently
  starts fresh each turn because `codex exec resume` has a different subcommand
  shape and `Chat.resume_args/2` deliberately does not pretend otherwise.
- Messages submitted while the process is running enter an in-memory queue.
  They can be reordered, deleted, or hard-dropped by killing the active process.
- `StreamEvent` already normalizes observed Claude, Codex, and OpenCode output
  into one UI vocabulary.
- `ChatPanel` is shared by Home and Trading. StatusLive and TradingLive duplicate
  some orchestration around the same `Chat` API and PubSub messages.
- `AgentRunner.open_port/4` explicitly attaches stdin to `/dev/null`. That is
  correct for one-shot automation and is exactly why the current chat process
  cannot accept live input.

### What must not be broken

- `AgentRunner.run/2` is also the one-shot primitive for Dispatcher, Swarm,
  Trading reads, and other automation. Live-chat transport must not silently
  turn those jobs into long-lived interactive processes.
- Trading and Chart Build carry Claude-specific confinement flags. Their
  `effective_agent/1` pin to Claude is a security decision, not an inconvenience
  to route around. General chats get all three transports; confined money
  surfaces stay Claude-backed until equivalent confinement is independently
  proven for another harness.
- A steering message cannot bypass command trust tiers, Robinhood order
  confirmation, Chart Build's verified-data path, or the `datareq` delivery
  budget.
- The current worktree already contains chat and Trading edits. Implementation
  must preserve those changes and rebase this work onto them rather than
  replacing them.

---

## Backend reality — measured 08-04-26

The three CLIs do not share a protocol. The common behavior belongs in Buster
Claw; the wire details stay behind backend adapters.

| Harness on this machine | Current Buster Claw path | Native interactive path | Steering status |
|---|---|---|---|
| Claude Code `2.1.222` | `claude -p`, one process per turn, `--resume` | `--input-format stream-json` keeps stdin open and accepts JSONL user messages during a long-lived session | **Documented and available** |
| Codex CLI `0.146.0` | `codex exec --json`, one process per turn, no resume in Chat | `codex app-server` over JSON-RPC; `turn/start`, `turn/steer`, and `turn/interrupt` | **Documented and explicit** |
| OpenCode `1.18.3` | `opencode run --format json`, one process per turn, `--session` | `opencode serve`, session HTTP API, SSE events, `prompt_async`, and `abort` | **MEASURED: steers. No HTTP receipt — acceptance comes from SSE** |

### Claude

Claude's streaming-input mode is the closest fit to the existing Port design.
The process starts once per conversation with both input and output set to
`stream-json`. User messages are JSONL written with `Port.command/2`. The first
message starts the work; later messages can arrive while tools or model turns
are active. Its init event carries a `capabilities` list, which should be used
for feature detection where available rather than pinning behavior to a version
number.

This is a **different lifecycle**, not one extra flag on the existing call:
stdin must remain open, a `result` event ends a turn rather than the OS process,
and the conversation process stays alive for future messages.

### Codex

`codex exec` is the wrong integration surface for an interactive chat. App
Server is the supported programmatic surface and gives the exact primitive this
feature needs:

```text
thread/start or thread/resume
        -> turn/start
        -> turn/steer(expectedTurnId: active turn)
        -> turn/completed
```

Moving chat to App Server also closes the existing Codex context gap: the thread
ID is durable and later turns append to the same thread instead of starting
fresh. `AgentRunner` should continue to use `codex exec` for one-shot jobs.

### OpenCode

OpenCode is already client/server internally. `opencode serve` exposes session
creation, an SSE event stream, asynchronous prompts, status, and abort. The
missing fact is semantic: the public docs call `prompt_async` "send a message
asynchronously (no wait)" but do not promise that a second prompt submitted
while the session is busy is incorporated into the active provider turn.

**ANSWERED 08-04-26 — see the Phase 0 findings.** OpenCode *does* incorporate a
prompt submitted mid-run into the active run, so it advertises `:steer`. Two
corrections to the paragraph above, both measured:

- The endpoint is **v1** `prompt_async`. The v2 API (`/api/session/…`) has the
  better vocabulary — a literal `delivery: "steer" | "queue"` — but a v2 session
  never executes without a separate driver.
- The concern about an empty response was well placed and turned out to be
  literal: `prompt_async` returns **no body at all**. Acceptance is derived from
  the SSE `message.updated` that follows ~20ms later, never from the HTTP call.

---

## Decisions taken while scoping

1. **Push, do not poll.** The model will not repeatedly call a Buster Claw
   "check inbox" command. Polling spends tokens, adds latency, can still be
   forgotten, and duplicates native protocols that already push user input into
   the active turn.
2. **Keep `AgentRunner` one-shot.** Interactive chat gets a transport boundary;
   Dispatcher and other automation keep the process lifecycle and `/dev/null`
   stdin they have now.
3. **Default to steering while active.** When the backend advertises native
   steering, the composer's primary action while running is **Steer now**.
   **Queue next** remains visible beside it. On a backend without steering, the
   primary action says **Queue next**; the UI does not offer a placebo.
4. **Backend capability, not backend name, drives the UI.** The useful set is
   `:start_turn`, `:steer`, `:queue_next`, and `:interrupt`. A future OpenCode
   release can gain steering without a LiveView rewrite.
5. **A steering message belongs to the active turn.** It does not increment the
   turn count, reset Chart Build's per-turn delivery budget, or ring the
   answer-ready sound. It is still persisted as a user message and audited as
   operator input.
6. **The agent stays productive, not waiting.** A common prompt addendum tells
   the model that live operator messages may arrive and to reconcile them at
   safe boundaries. It must never pause merely because another message *might*
   arrive.
7. **Acceptance receipts are explicit.** Every submitted message gets a client
   ID and a terminal delivery state. A completion/steer race cannot silently
   inject the message into the next unrelated turn.

---

## Target architecture

```text
StatusLive / TradingLive
          |
          | Chat.submit(text, delivery: :steer | :next)
          v
 BusterClaw.Agent.Chat  ---- transcript / delivery ledger / PubSub / Sentinel
          |
          | normalized transport contract
          v
  +----------------+----------------+------------------+
  | Claude         | Codex          | OpenCode         |
  | duplex Port    | App Server     | loopback server  |
  | stream-json    | JSON-RPC       | HTTP + SSE       |
  +----------------+----------------+------------------+
```

Introduce one behavior and one module per file:

- `BusterClaw.Agent.ChatTransport`
- `BusterClaw.Agent.ChatTransport.Claude`
- `BusterClaw.Agent.ChatTransport.Codex`
- `BusterClaw.Agent.ChatTransport.OpenCode`

The behavior should describe outcomes, not command-line flags:

```elixir
@callback open(keyword()) :: {:ok, handle(), capabilities()} | {:error, term()}
@callback start_turn(handle(), message()) :: {:ok, handle(), turn_ref()} | {:error, term()}
@callback steer(handle(), turn_ref(), message()) ::
            {:ok, handle(), receipt()} | {:error, :no_active_turn | term()}
@callback interrupt(handle(), turn_ref()) :: {:ok, handle()} | {:error, term()}
@callback close(handle()) :: :ok
```

Adapters emit normalized messages back to `Chat`:

```text
thread_ready · turn_started · input_accepted · assistant_delta · tool_started
tool_finished · usage · turn_completed · turn_interrupted · transport_failed
```

`Chat` remains the owner of ordering, persistence, timeouts, audit, UI state,
and the rule that converts a failed race into a queued next turn. Protocol
adapters must not write transcripts or decide product semantics.

### Conversation and turn identity

Track three separate identifiers:

- `conv_id` — Buster Claw's stable tab/conversation ID;
- `backend_thread_id` — Claude session, Codex thread, or OpenCode session;
- `backend_turn_id` — the currently active turn/request, when the backend has
  one.

The active state also carries a Buster Claw `run_token`. Every steer request is
addressed to that token. If the turn finishes before the adapter acknowledges
the message, `Chat` receives `:no_active_turn` and atomically moves the message
to the front of the next-turn queue. It never retries against whatever turn
happened to start afterward.

---

## Phase 0 — Protocol probes before architecture

**Why first:** Claude and Codex have documented primitives; OpenCode's name for
an endpoint is not enough to establish behavior. The adapters should be built
from captured streams rather than guessed event schemas, following the same rule
that produced `StreamEvent`.

1. **Claude duplex probe.** Start `claude -p` with input and output
   `stream-json`, send a task that performs at least two observable steps, then
   write a second JSONL user message while the first is active. Capture:
   init/capability event, replayed user acknowledgment, assistant/tool events,
   result boundaries, and process behavior after the first result.
2. **Claude timing probe.** Inject during model text generation and during a
   tool execution. Record at which boundary the message becomes visible. The UI
   copy must describe measured behavior, not "instant" behavior.
3. **Codex App Server probe.** Perform the initialize handshake, start a thread
   and turn, capture its turn ID, send `turn/steer` with `expectedTurnId`, and
   verify the new instruction affects that same turn. Then verify the stale turn
   ID rejection and `turn/interrupt` result.
4. **Codex confinement probe.** Translate the existing sandbox/model choices to
   `turn/start` fields and confirm App Server does not widen permissions versus
   `codex exec`. This is required before replacing the chat path.
5. **OpenCode busy-session probe.** Start `opencode serve` on loopback with a
   generated password, create a session, subscribe to SSE, begin a multi-step
   task with `prompt_async`, and submit a second prompt while status is `busy`.
   Pass only if the same active run changes course before an idle boundary.
6. **OpenCode failure probe.** Repeat with the configured agent file missing.
   The existing fail-open fallback detection must remain enforceable in server
   mode; an HTTP success under the default `build` agent is a rejected run.
7. Store redacted JSON/JSONL traces as test fixtures and write the observed
   versions beside them. Never fixture auth material, absolute home paths, MCP
   secrets, or prompt content from real accounts.

**Gate:** no adapter implementation begins until all three output streams are
captured and OpenCode is classified as either `:steer` or
`:interrupt_then_resume`.

### Findings — Claude, probes 1 and 2 (run 08-04-26)

`scripts/probe_claude_duplex.exs` (`--inject-on tool|text`), against the
operator's real `claude 2.1.222`, in a disposable temp workspace. Traces in
`tmp/probes/claude-duplex-{tool,text}.jsonl`. **Both variants: STEERED.**

1. **Steering is real.** In both runs the injected "abandon the sequence" message
   changed the *active* turn: `redirect.txt` was written and steps 2–3 never ran,
   all before the first `result` event. One `result`, `num_turns: 3`.
2. **The acknowledgment boundary is the in-flight tool, and the wait is real.**
   Injecting during model text (3.86s) and during a tool call (4.82s) produced
   the *same* replay latency — ~8.1s and ~8.8s — because in both cases the reply
   landed immediately after the running `sleep 8` Bash call returned. Injecting
   *before* a tool call did **not** stop that tool from starting: the model had
   already committed to it. So `SENDING` is not a flicker; it lasts as long as
   the current tool, which for a build or a test run is minutes. UI copy must say
   so rather than implying immediacy.
3. **`--replay-user-messages` is the receipt, and it is unambiguous.** Operator
   messages replay with `message.content` as a **string**; tool returns arrive as
   a **list of `tool_result` blocks**. Both currently normalize to `:user` and are
   dropped by `Chat.project_event/2`. Phase 2 must split them — the string form is
   the `accepted` signal, and it carries no other marker.
4. **Capabilities are advertised, so decision #4 is implementable.** `system/init`
   carries `["interrupt_receipt_v1", "interrupt_cancel_queued_v1",
   "msg_lifecycle_v1"]`. Note there is **no steering capability** — steering is
   implicit in stream-json input mode, so `:steer` must be inferred from the
   transport, not read from this list. The two interrupt capabilities are directly
   useful to Phase 2 item 5 (interrupt instead of killing the process group).
5. **`system/init` re-emits at the start of every turn**, same `session_id`. It is
   not a once-per-process event; Phase 2 item 6 must not latch on the first one.
6. ⚠ **`total_cost_usd` is session-CUMULATIVE, `num_turns` is per-turn.** Measured:
   turn 1 `$0.1197 / 3 turns`, then a 12-output-token turn 2 reported
   `$0.1326 / 1 turn`. Today one process per turn makes the field *equal* the
   turn's cost, which is why nothing has noticed. Under a long-lived process,
   `Chat.result_meta_line/2` and the `cost_usd` on the Sentinel audit event both
   silently become running totals. **Phase 2 must record the previous total and
   report the delta.** This is a regression the extraction would otherwise ship
   quietly, because every existing cost assertion still passes on turn 1.
7. **New event shapes, none breaking.** `rate_limit_event` → `:unknown`;
   `system/task_started` and `system/task_notification` → `:system` (harmless,
   they carry the same `session_id`); `thinking` content blocks render as empty
   text and are already dropped by the `text != ""` guard in `project_event/2`.
8. **The process survives a completed turn** and answered a second message on the
   same stdin and session, with no restart — the premise Phase 2 rests on.

### Findings — Codex, probes 3 and 4 (run 08-04-26)

`scripts/probe_codex_appserver.exs` (`--mode steer|confine`), against
`codex-cli 0.146.0`. Traces in `tmp/probes/codex-appserver-{steer,confine}.jsonl`.
**Steering: STEERED. Confinement: CONFINED.** Both pass.

1. **The protocol is generated, not guessed.** `codex app-server
   generate-json-schema --out DIR` emits the full bundle. All five methods the
   roadmap named exist: `thread/start`, `thread/resume`, `turn/start`,
   `turn/steer`, `turn/interrupt`. Phase 3 should regenerate this bundle and
   diff it as the protocol-drift guard, rather than hand-maintaining shapes.
2. **`turn/start` returns as soon as the turn EXISTS**, with
   `{turn: {id, status: "inProgress"}}` — the work then streams as
   notifications. That is what makes the turn addressable for steering while it
   runs, and it means Phase 3's `turn/start` must not be written as a
   blocking call.
3. **Steering confirmed.** `turn/steer` returned `{"turnId": …}` — a real
   receipt, not a bare ack. `redirect.txt` was written and steps 2–3 skipped,
   inside one turn, one `turn/completed`.
4. ⚠ **Same latency law as Claude.** Steered at 8.25s; the injected `userMessage`
   item did not appear until 16.15s — immediately after the running `sleep 8`
   command returned. Two different harnesses, two different protocols, the same
   rule: **the message lands at the next tool boundary, and the in-flight tool
   sets the wait.** This is now a cross-backend fact and belongs in the UI copy,
   not a Claude-specific footnote.
5. **`expectedTurnId` is genuinely checked**, and the two failure modes are
   distinct messages under one code (`-32600`):
   - wrong id while a turn is active — ``expected active turn id `…` but found `…` ``
   - any id after the turn finished — `no active turn to steer`

   Both are safe to treat as `:no_active_turn` (demote to the front of the queue).
   Scenario C needs no invented guard — the protocol already refuses.
6. **`clientUserMessageId` is a native protocol field** on both `turn/start` and
   `turn/steer`. Phase 6's duplicate-suppression key does not have to be
   Buster-Claw-only bookkeeping on this backend.
7. **Confinement holds.** `thread/start` with `sandbox: "read-only"` +
   `approvalPolicy: "never"` refused a write: `operation not permitted:
   escaped.txt`, exit 1, no file created. `SandboxMode` is the *same* three-value
   enum (`read-only` / `workspace-write` / `danger-full-access`) that
   `AgentBackend.permission_args/2` already emits as `-s`, so the translation is
   one-to-one and needs no new judgement call.
8. ⚠ **App Server still starts the operator's MCP servers** —
   `mcpServer/startupStatus/updated` fires on every thread. This does not make
   App Server *worse* than `codex exec`, but it confirms `AgentBackend`'s
   standing caveat that codex's sandbox does not scope MCP. It is exactly why the
   money surfaces stay Claude-pinned, and Phase 3 must not read "CONFINED" here
   as clearance to widen them.
9. **Notification vocabulary** maps cleanly onto `StreamEvent`: `turn/started`,
   `item/started`, `item/completed` (with `type` in
   `userMessage | reasoning | agentMessage | commandExecution`), `turn/completed`
   carrying the full turn with `durationMs`, plus `thread/tokenUsage/updated` for
   usage. Deltas (`item/agentMessage/delta`, `item/reasoning/textDelta`) are the
   bulk of the stream and must be coalesced before persistence, as Phase 3 item 5
   already requires.

### Findings — OpenCode, probes 5 and 6 (run 08-04-26)

`scripts/probe_opencode_server.exs` (`--mode steer|confine`), against
`opencode 1.18.3`, model `opencode-go/glm-5.2`. Traces in
`tmp/probes/opencode-server-{steer,confine}.jsonl`.
**Steering: STEERED. Confinement: FAILS OPEN SILENTLY.**

1. ⚠ **There are TWO live API generations, and the good one does not run.**
   - **v2** (`/api/session/…`) natively models `delivery: "steer" | "queue"` and
     returns a `SessionInputAdmitted` receipt with `admittedSeq`, `promotedSeq`,
     and the **effective** delivery echoed back. It is exactly the vocabulary
     this roadmap invented independently — and it does not execute. A v2 session
     admits the prompt into a `session.next.*` buffer, then sits at cost 0 with
     no messages. v2 evidently expects a separate driver (the TUI or the bundled
     web app at `/app`). Measured twice, including with `delivery` omitted.
   - **v1** (`/session/{id}/prompt_async`) is the only path that executes from a
     plain HTTP client. It is what Phase 4 must be built on today.
   Watch v2: when it becomes self-driving, it is strictly the better target.
2. **Steering is real on v1.** Submitted at 5.49s while the step-1 command was
   running (started 5.44s); step 1 completed at 13.57s; `redirect.txt` was
   written at 21.81s; steps 2 and 3 never ran. **Exactly one `session.idle`, at
   22.92s** — one continuous run, not an abort-and-restart. OpenCode therefore
   advertises `:steer`, not `:interrupt_then_resume`. The roadmap's pessimistic
   branch (Phase 4 item 5) is **not** needed.
3. **Third confirmation of the latency law.** Submit → in-flight tool ends →
   new instruction acted on. Same shape as Claude and Codex, on a third
   unrelated protocol.
4. ⚠ **`prompt_async` returns an EMPTY body — no receipt whatsoever.** This is
   the exact case the roadmap flagged: there is nothing in the HTTP response to
   justify showing "steered". **But SSE supplies one:** a `message.updated` with
   `role: "user"` plus the part carrying our text appears ~20ms after the POST.
   Phase 4 must derive acceptance from that event, never from the HTTP call.
   Note the distinction it creates, which is worth keeping in the UI vocabulary:
   - OpenCode's receipt is an **admission** receipt (immediate, ~20ms);
   - Claude's replay is a **boundary** receipt (arrives when the tool ends).

   Both are honest as `accepted`; neither proves the model has read the sentence.
5. **`prompt_async` accepts a caller-supplied `messageID`.** Like Codex's
   `clientUserMessageId`, Phase 6's dedup key is a native field here rather than
   Buster-Claw-side bookkeeping. All three backends support it.
6. ⚠ **Confinement fails open, and the API does not tell you.** A session created
   with `agent: "definitely-not-a-real-agent-…"` was accepted, echoed the bogus
   name back verbatim on both create and re-fetch, and then **admitted a prompt
   on it**. The server API is strictly *worse* than the CLI here: `opencode run`
   at least prints the fallback line to stderr that `fallback_warning?/2` scrapes,
   whereas the server offers no signal at all — `SessionV2Info.agent` is an echo
   of the request, not a statement about what will run.
   **Phase 4 item 6's fallback condition is therefore met: confined OpenCode chat
   stays disabled.** General OpenCode chat is unaffected.
7. **Auth is Basic and the username is literally `opencode`** — an empty username
   is rejected with 401. The password comes from `OPENCODE_SERVER_PASSWORD` in
   the environment; the server prints `server is unsecured` when it is unset,
   which is a usable startup assertion for Phase 4 item 1.
8. **The server's OpenAPI document is served live at `GET /doc`.** Like the Codex
   schema bundle, Phase 4 should diff it as the protocol-drift guard rather than
   hand-maintaining shapes.
9. **v1 event vocabulary**: `session.status` (`busy`/`idle`), `session.idle`,
   `message.updated`, `message.part.updated` (parts typed `text` / `tool` /
   `step-start` / `step-finish`, tool state `running` → `completed`),
   `session.diff`, `server.heartbeat`. The existing `normalize_opencode/1` was
   written against `run --format json`, whose shapes differ — Phase 4 needs a
   server-mode reader, not a reused one.

### Phase 0 gate — SATISFIED 08-04-26

All three output streams are captured, and OpenCode is classified: **`:steer`**,
on the v1 API, with acceptance derived from SSE rather than the HTTP response.
Adapter implementation may begin.

The headline is that **all three harnesses steer**, which is better than this
roadmap assumed. Three consequences for the plan below:

- **Phase 4 item 5 is not needed.** The `:interrupt_then_resume` fallback and the
  "Interrupt & redirect" UI branch were contingency for an OpenCode that could not
  steer. It can. Keep `:interrupt` as a capability; drop the fallback path.
- **Capability negotiation is still right, for a different reason.** Not because
  backends differ on *whether* they steer, but because they differ on what they
  can *prove*: Codex returns a turn-addressed receipt, Claude replays at the tool
  boundary, OpenCode says nothing until SSE. `:steer` alone is too coarse — the
  descriptor needs a receipt kind.
- **The latency law is universal and belongs in Phase 5's copy.** Measured on
  three unrelated protocols: a steered message lands at the next tool boundary,
  and the in-flight tool sets the wait (~8s in every run here, because the tool
  slept 8s). `SENDING` is a real, potentially long-lived state, not a flicker.

---

## Phase 1 — Extract the transport boundary without changing behavior

1. Add the `ChatTransport` behavior and the three backend modules, each in its
   own file. Begin with one-shot-compatible implementations so the extraction
   itself does not alter visible behavior.
2. Move argv/protocol knowledge out of `Chat.start_run/2`. `AgentBackend`
   remains the catalog for labels, executables, models, confinement, and usage;
   it gains a transport/capability descriptor rather than growing network code.
3. Extend or replace `StreamEvent` only where the protocols demand it. Keep the
   current normalizers as compatibility readers for Dispatcher/one-shot runs;
   do not force JSON-RPC and SSE into a fake NDJSON shape if a separate
   `ChatEvent` is clearer.
4. Make `Chat` test against a fake transport instead of fake Port references.
   The fake must deterministically simulate accepted steer, no-active-turn,
   delayed receipt, duplicate receipt, transport crash, and completion races.
5. Preserve `Chat.send_message/2` temporarily as a compatibility wrapper:
   idle starts a turn; running queues next, matching today's behavior. New call
   sites use `Chat.submit/3` with an explicit delivery mode.

**Acceptance:** all current chat, StatusLive, TradingLive, stream parser, and
queue tests pass unchanged before a live transport is switched on.

### Status — COMPLETE 08-05-26

`ChatTransport` + three adapters, `Chat.submit/3`, and 26 new tests.
`mix test` 2630/0, `credo --strict` clean, `compile --warnings-as-errors` clean,
`check_cycles.sh` back to its 2 accepted cycles. No existing test was modified.

Deviations and findings, all deliberate:

1. **`for_agent/1` is NOT on `ChatTransport`.** An adapter must depend on that
   module for `@behaviour`, so naming the adapters back from it made the four
   transport files a dependency cycle — caught by `check_cycles.sh`, correctly.
   The mapping is a private `Chat.transport_for/1`, and the selection test drives
   it through `Chat` rather than asserting a copy of the mapping against itself.
2. **`AgentBackend` did NOT gain a transport descriptor**, contrary to Phase 1
   item 2. Every route was a cycle: adapters → `AgentRunner` → `AgentBackend`, so
   `AgentBackend` cannot point at adapters. It is also unread — the UI gets
   capabilities from `Chat.capabilities/1`. Adding an unreferenced descriptor
   would have been structure that rots. `AgentBackend` stays the flag catalog.
3. ⚠ **A regression this extraction introduced, caught by the suite.** The
   handle was being built with the adapter's own name, but `effective_agent/1`
   returns **nil** when no harness is configured, and nil means *let
   `AgentRunner.detect/0` choose* — it honours the `:agent_cli` override and PATH
   order. Hardcoding `:claude` bypassed the model-policy test's stand-in CLI, and
   in the field would have turned detection into a hard
   `{:agent_unavailable, :claude}` on a codex-only machine. The agent is now
   passed through unresolved; two tests pin it.
4. ⚠ **Latent bug found while pinning that, deliberately NOT fixed here.**
   `AgentBackend.stream_args/2` has no clause for `nil`, so it falls through to
   `[]`. A chat started without an explicit `:agent` therefore runs **without**
   `--output-format stream-json`: every output line fails to parse and the whole
   reply lands in `raw_tail` instead of the transcript. Masked in the app because
   every real caller passes `ModelPolicy.backend_for(:chat)`. The fix is one
   clause, but it is a behaviour change and does not belong inside a
   behaviour-preserving extraction — it wants its own commit. Pinned as-is in
   `chat_transport_test.exs` so the fix is a deliberate act.
5. **Race demotion goes to the FRONT of the queue** (roadmap Phase 5 item 6),
   distinguished from `:not_supported`, which takes its place in line. Both
   covered by the fake transport, since no real adapter can steer yet.

---

## Phase 2 — Claude becomes a long-lived duplex conversation

1. Add a dedicated duplex Port opener. Do **not** remove `/dev/null` from
   `AgentRunner.open_port/4`; the new opener is chat-only and deliberately keeps
   stdin writable.
2. Start Claude once per active conversation with:
   `--input-format stream-json`, `--output-format stream-json`, `--verbose`, and
   replay/partial-message flags established by the probe. Preserve model,
   permission, allowed/disallowed tool, MCP, and system-prompt flags exactly.
3. Write the first and subsequent user messages as JSONL. Centralize the encoder
   and reject text above a bounded byte limit before it reaches `Port.command/2`.
4. Treat a `result` event as **turn completion**, not transport completion. Keep
   the Port and input stream alive for the next turn.
5. Split timeouts into a turn deadline and transport health. A turn timeout
   interrupts when supported; if the transport cannot confirm interruption,
   kill the process group and resume the saved session in a fresh process.
6. Read Claude's advertised capabilities from init. Missing capability fields
   degrade conservatively; they do not infer support from `2.1.x` string
   ordering.
7. On reset/close, close stdin and reap the whole process group. On a crash,
   fail the active delivery, preserve queued prompts, and restart lazily on the
   next submission.

**Acceptance:** during a real multi-step Claude task, an operator correction is
accepted into the same active turn and changes the next model action without an
OS-process restart.

---

## Phase 3 — Codex chat moves from `exec` to App Server

1. Add a supervised `BusterClaw.Agent.CodexAppServer` connection. Prefer one
   app-server process per Buster Claw application, multiplexing conversation
   threads by ID, rather than one full server per tab.
2. Perform `initialize`/`initialized` once per connection and correlate every
   JSON-RPC request by a generated request ID. Unknown notifications remain
   observable debug data and never crash the connection.
3. Map a new conversation to `thread/start`; persist the returned thread ID.
   Use `thread/resume` after Buster Claw or app-server restarts.
4. Map normal submissions to `turn/start`, live steering to `turn/steer` with
   `expectedTurnId`, and interruption to `turn/interrupt`.
5. Normalize `item/agentMessage/delta`, item/tool events, turn completion,
   errors, and usage into the existing transcript vocabulary. Coalesce token
   deltas so the database is not given one row per token.
6. Translate Buster Claw's Codex sandbox/model policy into thread/turn fields and
   test it against the Phase 0 confinement fixture. Do not introduce
   `danger-full-access` as an accidental analogue for Claude's permission mode.
7. If app-server dies, restart it under OTP, resume known threads, and reconcile
   any active turn as interrupted unless Codex reports it still running.

**Acceptance:** Codex gains both true mid-turn steering and real conversation
continuity. A second normal turn can refer to the first without Buster Claw
prepending a synthetic transcript summary.

---

## Phase 4 — OpenCode gets the server transport, with an honest capability

1. Supervise `opencode serve` on `127.0.0.1` using an OS-assigned/private port
   and a freshly generated Basic Auth password. Pass the password through the
   environment, never argv or logs.
2. Use Req for health, session, prompt, and abort requests. Add a supervised SSE
   reader for session events; reconnect with a bounded backoff and resume from
   server state where the protocol permits.
3. Create or resume one OpenCode session per Buster Claw conversation. Preserve
   the selected provider/model, variant, agent file, directory, and permission
   posture.
4. If Phase 0 proves busy-session prompt injection, map `:steer` to the verified
   endpoint and show accepted only after the corresponding event/receipt.
5. If Phase 0 does not prove it, advertise `:interrupt_then_resume`. The Steer
   action becomes an explicit **Interrupt & redirect** action for OpenCode:
   abort the busy session, wait for the abort/idle event, submit the new user
   message to the same session, and preserve any ordinary queued turns behind
   it.
6. Detect the "falling back to default agent" condition from server events or
   session metadata. If the server API exposes no trustworthy signal, confined
   OpenCode chat stays disabled rather than failing open.

**Acceptance:** an OpenCode user can submit during active work without losing
the message. The UI says either **Steered** or **Interrupted & redirected** based
on the measured capability; it never relabels asynchronous next-turn delivery.

---

## Phase 5 — One chat interaction model in Home and Trading

1. Add `Chat.submit(conv_id, text, delivery: :steer | :next)` and expose the
   current transport capabilities in status/PubSub.
2. Keep the composer enabled while a turn is running. Its primary action is:
   - **Steer now** when `:steer` is available;
   - **Interrupt & redirect** when that is the backend's explicit capability;
   - **Queue next** when neither live path is supported.
3. Keep **Queue next** available as a secondary action even on steerable
   backends. Operators sometimes want "after that, run the tests" without
   changing the current reasoning.
4. Use one keyboard contract everywhere:
   - `Enter` submits the current primary action;
   - `Shift+Enter` inserts a newline;
   - `Cmd/Ctrl+Shift+Enter` inverts **Steer now** and **Queue next** for one
     submission.
5. Render a submitted steering message immediately as a user bubble with a
   delivery chip: `SENDING`, `STEERED`, `QUEUED NEXT`, `REDIRECTED`, or `FAILED`.
   Use stable DOM IDs based on the client message ID so PubSub receipts update
   the correct bubble.
6. Preserve the existing draggable queue. A steered message does not appear in
   that queue; a race-demoted message appears at its front with a brief
   "turn finished before delivery" explanation.
7. Put the composer and delivery controls in `ChatPanel`; keep StatusLive and
   TradingLive responsible only for surface-specific profile choices and
   follow-up effects. Do not fork the interaction into two subtly different
   implementations.
8. Accessibility: announce delivery-state changes through a polite live region,
   keep the primary action's accessible name current, and never encode state by
   color alone.

### The common attention contract

Every general chat profile receives a short backend-neutral prompt addendum:

```text
The operator may send additional user messages while you are working. Treat a
new live message as the latest statement of intent. Reconcile it at the next
safe boundary before beginning another substantial or irreversible step. Briefly
acknowledge a material redirection. Do not repeat an external side effect that
already completed, and ask when the new instruction conflicts with a completed
action. Keep working normally when no message is present; never wait or poll for
a possible follow-up.
```

For Claude this remains an appended system prompt. For Codex and OpenCode it is
folded into the backend's supported instruction/profile mechanism, following
the existing rule that Claude-only flags never leak into another argv.

The contract makes the model receptive; the transport makes the message real.
Neither is sufficient alone.

---

## Phase 6 — Durable delivery, audit, and surface-specific safety

The current queue is memory-only. Once users can redirect expensive work, a
message acknowledged by the UI must survive a LiveView crash or backend restart.

1. Generate a UUID `client_message_id` in the server on submission. All retries
   and receipts carry it.
2. Add a small delivery ledger rather than overloading append-only transcript
   rows. Suggested fields:
   `id`, `conv_id`, `content`, `requested_mode`, `effective_mode`, `status`,
   `backend`, `backend_thread_id`, `backend_turn_id`, `run_token`, `position`,
   `accepted_at`, `failed_at`, and timestamps.
3. Make the pending queue a query over ledger rows. On boot, recover
   `pending/queued` rows in order; reconcile `sending` rows against backend state
   or mark them retryable. Never blindly resend an uncertain message and risk
   applying an instruction twice.
4. Persist backend thread IDs per conversation and backend. Switching harnesses
   must not overwrite the thread needed when the operator switches back.
5. Keep transcript display append-only, but allow its user-message projection to
   reference the delivery ID and render the final delivery state after reload.
6. Record Sentinel events for steering accepted, steering demoted to queue,
   interrupt-and-redirect, transport failure, and duplicate suppression. Store
   bounded/redacted metadata, not the full prompt body.
7. Preserve caller trust. A live message inherits the same provenance and token
   posture as the active conversation; it cannot upgrade an untrusted run.
8. **Trading:** a steering message may change research or produce a new order
   proposal, but it can never invoke the order-write harness. The existing
   parsed proposal and operator confirmation remain mandatory.
9. **Chart Build:** steering does not reset the current turn's `datareq` budget
   or repeat brake. A queued next turn resets them when that turn actually
   starts, exactly once.
10. **Sound:** steering acceptance does not ring. Ring only when the whole
    conversation settles idle with no queued work, preserving today's rule.

**Acceptance:** kill the LiveView, chat process, and each backend transport at
different points between submission and receipt. Every prompt ends in exactly
one visible terminal state and no prompt is silently discarded.

---

## Phase 7 — Tests, live probes, and rollout

### Pure and process tests

- Idle submit starts one turn.
- Steer-capable running submit targets the current `run_token` and turn ID.
- Queue-next never reaches the active transport.
- Completion before steer receipt demotes the message to the front of the queue.
- A stale receipt cannot mark a later turn's message delivered.
- Double-click/reconnect duplicate IDs produce one backend delivery.
- Transport crash preserves pending/queued messages and marks uncertain sends.
- Interrupt waits for a terminal backend event before starting the redirect.
- Reset closes the transport, clears backend identity deliberately, and applies
  an explicit product decision to pending messages rather than dropping them by
  accident.
- Changing harness preserves independent Claude/Codex/OpenCode thread IDs.
- Tool, assistant, usage, and error events remain normalized for all three.

### LiveView tests

- Assert stable IDs for the composer, primary send action, secondary queue
  action, delivery live region, message receipt, and queue rows.
- Test Home and Trading through those IDs, not raw HTML or changeable copy.
- Test the keyboard contract in the JS hook with Bun.
- Test capability changes update labels without remounting the conversation.
- Test a race-demoted message appears as the first queue item.

### Real harness tests

Add opt-in smoke scripts for installed CLIs. They must use a disposable temporary
workspace and prompts with no external side effects.

- Claude: inject during a multi-step run and verify one process/session.
- Codex: steer using `expectedTurnId`, then test the stale-ID rejection.
- OpenCode: pin the Phase 0 classification so an upstream semantic change is
  noticed rather than silently mislabelled.
- Run these manually before release and in a scheduled CI lane only where auth is
  explicitly available. Normal unit CI never depends on a user's agent login.

### Rollout

1. Ship behind `:chat_live_steering_enabled`, default off outside development.
2. Dogfood one backend at a time: Claude, Codex, then OpenCode.
3. Track only operational metrics: submit-to-accept latency, demotion count,
   failure count, transport restarts, and interrupted turns. Do not log prompt
   bodies.
4. Enable by default only after each backend passes its acceptance scenario and
   `mix precommit`, `bun test assets/js`, the Rust gate, and the relevant live
   harness smoke all pass.

---

## End-to-end acceptance scenarios

### A. Redirect the wrong work

1. Ask the agent to investigate a deliberately slow two-part task.
2. While it works on part one, submit: "Skip part two; inspect the integration
   failure instead" using **Steer now**.
3. The message becomes `STEERED` only after backend acknowledgment.
4. The same active turn changes its next action and briefly acknowledges the
   redirection.

Pass on Claude and Codex. On OpenCode, pass as true steering only if Phase 0
proved it; otherwise the expected result is the clearly labelled redirect path.

### B. Plan the next turn without disturbing this one

1. While the agent is editing, submit "When that is done, run the focused test"
   using **Queue next**.
2. The current turn completes unchanged.
3. The queued message starts once, next, and resumes the same backend thread.

### C. Completion race

1. Submit a steer as the active turn finishes.
2. The old turn rejects the expected ID/token.
3. Buster Claw shows `QUEUED NEXT`, places it first, and runs it once.

### D. Safety surface

1. In Robinhood chat, steer with language that proposes a trade.
2. The active read-only conversation may return an order proposal card.
3. No broker write occurs until the operator separately confirms through the
   existing write harness.

---

## Non-goals

- Replacing the installed CLIs with direct provider APIs.
- Making Dispatcher or Swarm interactive; this roadmap is for user-facing chat.
- Giving Codex or OpenCode Claude's confined Trading profile without a separate
  security proof.
- Claiming instant model attention during an in-flight inference request.
- Reverting filesystem or external side effects when a user changes direction.
- Letting the model burn tokens polling an inbox.
- Sending messages between different conversations or subagents; that is a
  separate orchestration feature.

---

## Risks worth carrying visibly

- **Protocol drift:** all three CLIs are moving quickly. Capability negotiation,
  captured fixtures, and live smoke probes are release requirements, not test
  decoration.
- **False delivery:** the most damaging UI bug is saying "steered" when the
  backend only queued. Receipts and expected turn IDs exist to prevent it.
- **Duplicate instructions:** reconnect/retry behavior can make an agent perform
  an instruction twice. Client IDs and an explicit uncertain state are required
  before automatic retry.
- **Process cost:** long-lived Claude processes and shared Codex/OpenCode servers
  change resource behavior. They must remain lazy, close when the last relevant
  conversation closes, and expose health without noisy polling.
- **Transcript shape:** injected user messages can interleave with assistant/tool
  output. Ordering needs server sequence numbers; browser arrival order alone is
  not a source of truth.
- **Prompt contradiction:** a late steer may conflict with an effect already
  completed. The attention contract tells the model not to replay effects, but
  irreversible actions remain gated by Buster Claw rather than prompt trust.

---

## Sources used for this scope

- Claude Code streaming input:
  `https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode`
- Claude Code programmatic/stream output and capability events:
  `https://code.claude.com/docs/en/headless`
- Codex App Server (`turn/start`, `turn/steer`, `turn/interrupt`):
  `https://developers.openai.com/codex/app-server/`
- OpenCode server/session API (`prompt_async`, SSE, status, abort):
  `https://dev.opencode.ai/docs/server/`
- Installed CLI help captured during scoping:
  Claude Code `2.1.222`, Codex CLI `0.146.0`, OpenCode `1.18.3`.
