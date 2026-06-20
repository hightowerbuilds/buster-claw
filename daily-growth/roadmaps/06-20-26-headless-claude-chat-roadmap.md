# BusterClaw → Headless Claude Chat Interface Roadmap

**Date:** 2026-06-20
**Target:** A real-time, chat-like surface on the homepage driven by **headless Claude** — so a user can talk to the agent (and have it drive `./buster-claw`) without opening the in-app terminal. Extends the autopilot/headless work; no API keys, bring-your-own-agent model unchanged.
**Relates:** `06-17-26-always-on-shift-roadmap.md` (the `AgentRunner` headless primitive + `Dispatcher` discipline this reuses), `lib/buster_claw/autopilot/tui.ex` (the proven stream-json parsing spike this extracts).

---

## Build status (2026-06-20)

Built end-to-end (all phases). Full suite green (**476 tests, 0 failures**),
clean compile under `--warnings-as-errors`, assets build clean.

| Phase | Status | Notes |
|---|---|---|
| 1 — `StreamEvent` shared parser | ✅ done | `lib/buster_claw/agent/stream_event.ex`; `tui.ex` refactored to consume it (no behavior change; existing TUI tests still green) |
| 2 — `Agent.Chat` GenServer | ✅ done | `lib/buster_claw/agent/chat.ex`; reuses new `AgentRunner.open/2` streaming Port; serialized + timeout + `--resume` threading; injectable `:spawner` for tests |
| 3 — transcript persistence | ✅ done | `agent_chat_messages` table + `Agent.Message` + `Agent.Transcript`; Chat broadcasts *display-ready* messages and persists them best-effort; StatusLive seeds history on mount |
| 4 — homepage chat column | ✅ done | `StatusLive` chat panel (right column; calendar moved into the left stack) + `AgentChat` JS hook (autoscroll, Enter-to-send) |
| 5 — tests & wiring | ✅ done | `stream_event_test.exs`, `chat_test.exs`, `transcript_test.exs`, `chat_persistence_test.exs`, StatusLive chat cases; config flags `agent_chat_enabled` / `agent_chat_timeout_ms` / `agent_chat_persist` (off in test) |

**Not yet verified in a real run:** the actual `claude -p --output-format stream-json` round-trip
(tests use an injected spawner). Needs a manual `mix phx.server` + send a message, ideally also in
the packaged `.app` (the login-shell path in `AgentRunner.open/2` is what makes packaged-env auth work).

---

## Why this is feasible (the spike already exists)

The autopilot TUI (`lib/buster_claw/autopilot/tui.ex`) already spawns headless Claude with
`--output-format stream-json --verbose` and parses the NDJSON event stream **in real time**
(`classify/1`, `activity/1`), rendering it to an ANSI starfield. Mechanically that is ~80% of a
chat backend — we redirect the same parsed stream from ANSI into Phoenix PubSub → a LiveView.

There are two headless paths today, both batch at the boundary:

- **`AgentRunner.run/2`** (Dispatcher's daemon path): `claude -p <prompt> --permission-mode bypassPermissions`, buffers the whole stdout, returns once. Gives us the spawn discipline (login shell, wall-clock timeout, kill) we reuse.
- **`Autopilot.Tui.run/2`** (`./buster-claw autopilot`): streams + parses line-by-line. Gives us the parser we extract.

## The core principle

The run must live **inside the Phoenix BEAM** (a supervised GenServer, like `Dispatcher` /
`Sentinel.Pending`), **not** in the `./buster-claw` escript. The escript is a separate OS process
and cannot broadcast into the running app's PubSub. We reuse `AgentRunner`'s Port spawn plumbing
and lift the parsing from `Autopilot.Tui`.

## Decisions (locked 2026-06-20)

| Decision | Choice | Notes |
|---|---|---|
| **Conversation model** | One-shot `claude -p` per message, threaded with `--session-id` / `--resume` | Each message respawns a short-lived headless run that resumes the prior session. Crash-safe, simplest, real memory. Slight per-turn respawn latency, accepted. |
| **Homepage layout** | **Replace the calendar column** | Chat takes the right column (max height); the Daily Calendar moves into the left panel stack. Stays a 2-col grid (`lg:grid-cols-2`). |
| **Prompt scope** | **Bare passthrough** | Send the user's text with no preamble/system prompt. Behaves like raw Claude Code in the workspace. (Revisit if users want an operator framing later.) |
| **Trust boundary** | Unchanged | The agent drives `./buster-claw`; server-side `Commands` tier + provenance gate remain the real authorization. **Chat input is untrusted user text.** |

---

## Phases

### Phase 1 — Shared stream event normalization

**New: `lib/buster_claw/agent/stream_event.ex`**

- Extract the pure parsing currently inside `tui.ex` (`split_lines`, `decode`, and a normalizer
  built from `classify/1` + `activity/1`) into one tested module.
- Input: a raw NDJSON line from `--output-format stream-json`. Output: a normalized term, one of:
  - `{:system, meta}` — session init, **carries `session_id`**
  - `{:assistant_text, text}` (and `{:assistant_delta, text}` if `--include-partial-messages` is enabled later)
  - `{:tool_use, name, summary}` — e.g. `"Bash: ./buster-claw dispatch list"`
  - `{:tool_result, ...}`
  - `{:result, %{text, cost_usd, num_turns, session_id}}`
- **Refactor `Autopilot.Tui` to consume this module** so the starfield TUI and the chat backend
  share one parser — no divergence. `tui.ex` keeps its ANSI rendering; only parsing moves out.

**Why first:** reusable core, pure/testable, de-risks everything downstream.

### Phase 2 — The chat session GenServer

**New: `lib/buster_claw/agent/chat.ex`** (`BusterClaw.Agent.Chat`)

- Supervised in `application.ex` next to `Dispatcher`, gated by a config flag
  (`agent_chat_enabled`, mirroring `dispatcher_enabled`); **off in tests**.
- One conversation = one process via `DynamicSupervisor` + `Registry` keyed by conversation id
  (v1 can ship as a single named server, then generalize).
- API:
  - `send_message(conv_id, text)` → spawns
    `claude -p text --output-format stream-json --verbose --permission-mode bypassPermissions [--resume session_id]`
    via a Port, reusing `AgentRunner`'s `exec` shell/login/timeout/kill plumbing (extract a shared
    spawn helper rather than duplicate it).
  - On each NDJSON line: parse via `StreamEvent` → broadcast on PubSub topic `"agent_chat:<conv_id>"`
    → append to an in-memory transcript.
  - Capture `session_id` from the system/result event; store it for the next turn's `--resume`.
- Discipline borrowed from `Dispatcher`: serialized (one run in flight per conversation),
  wall-clock timeout, clean reset on crash. Injectable `:runner` seam for tests (same pattern the
  Dispatcher uses) so CI never spawns a real `claude`.

### Phase 3 — Transcript persistence (optional / fast-follow)

**New Ecto migration + `lib/buster_claw/agent/message.ex`** (table `agent_chat_messages`), mirroring
how `security_events` is stored.

- Persist role (`user` / `assistant` / `tool`), content, `session_id`, cost/turns, timestamps.
- Lets a conversation survive page reload / app restart — consistent with the project's
  "all state durable" principle.
- Can be deferred until streaming is working end-to-end if we want to see it live first.

### Phase 4 — The homepage column (LiveView UI)

- **New component: `BusterClawWeb.Components.AgentChat`** (or a `live_component`) rendered inside
  `StatusLive`.
- **Layout change in `status_live.ex`:** keep `lg:grid-cols-2`; move the Daily Calendar panel into
  the left stack and put the chat component in the right column at full height.
- `StatusLive.mount` subscribes to `"agent_chat:<conv_id>"` when `connected?`;
  `handle_info({:agent_chat, event}, ...)` appends to a transcript assign and pushes to the client.
- `handle_event("chat_send", %{"text" => t}, ...)` → `Agent.Chat.send_message/2`; optimistically
  append the user bubble.
- **New JS hook in `assets/js/app.js`** (the `Hooks` map, ~line 358): auto-scroll-to-bottom on new
  messages + submit-on-Enter for the textarea. Precedent: the terminal's `TerminalView` hook.
- Styling: reuse the `ic-panel` brutalist idiom every homepage section already uses. A streaming
  "agent is working" indicator can reuse the `classify` states (scanning / transmitting / drifting)
  as status chips.

### Phase 5 — Tests & wiring

- Unit tests for `StreamEvent` (pure; follows the existing `tui.ex` `classify` test).
- `Agent.Chat` tests with the injected fake runner — no real `claude` in CI.
- LiveView test: send → broadcast → render.
- Config flags in `config.exs` / `test.exs`; `agent_chat_enabled: false` in test.

---

## What's reused vs. genuinely new

| Reused (exists today) | New |
|---|---|
| stream-json parsing (`tui.ex`) | `StreamEvent` module (extracted) |
| Port spawn + login shell + timeout + kill (`AgentRunner`) | `Agent.Chat` GenServer |
| injectable-runner test seam (`Dispatcher`) | `ChatLive` component + JS hook |
| PubSub broadcast pattern (`Sentinel`) | optional `agent_chat_messages` table |
| `ic-panel` UI idiom, supervision-tree config gating | `--session-id`/`--resume` threading |

No blockers — the streaming spike is already proven in `tui.ex`.

## Build order

1 → 2 → 4 (visible end-to-end with in-memory transcript) → 5 → 3 (persistence as fast-follow).

## Open questions / later

- **Partial token streaming:** add `--include-partial-messages` and filter
  `stream_event` → `event.delta.type == "text_delta"` for a live typing effect. Defer to a polish pass.
- **Multiple concurrent conversations:** v1 single conversation; `DynamicSupervisor` + `Registry`
  keying is designed in but can land when needed.
- **Operator framing:** if bare passthrough feels too raw, add an `--append-system-prompt`
  establishing the Buster Claw operator role (was an alternative for the prompt-scope decision).
- **Interrupt / stop a run mid-stream:** a "stop" control that kills the in-flight Port
  (the kill plumbing already exists in `AgentRunner`).
