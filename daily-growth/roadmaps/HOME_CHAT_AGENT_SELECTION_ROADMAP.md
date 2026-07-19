# Home Chat Agent Selection Roadmap

**Claude by default, Codex as the first alternative**

> Scoped 2026-07-18 against the current Phoenix chat pipeline, Codex CLI 0.144.6,
> and the current official Codex manual. This roadmap adds one
> capability: choosing which installed agent powers the Home chat from
> **Settings → Configuration**. It does not change unattended shifts, Dispatch,
> terminal sessions, or expose arbitrary model IDs.

---

## Outcome

Add a **Home chat agent** panel at the top of Settings → Configuration with two
choices:

- **Claude Code — Default**
- **Codex**

The preference is global and durable. A missing preference resolves to Claude.
The selected CLI must be installed and authenticated; Buster Claw does not add
an API integration or store provider credentials.

This is technically an **agent/provider selection**, not yet a model selection.
Claude Code and Codex have different command lines, session-resume syntax, and
JSON event formats. Calling the setting “Home chat agent” keeps that distinction
honest and leaves provider-specific model choice for a later slice.

## Product contract

| Situation | Required behavior |
|---|---|
| No setting exists | Use Claude. |
| Claude is selected | Start Home-chat turns with the Claude CLI only. |
| Codex is selected | Start Home-chat turns with the Codex CLI only. |
| Selected CLI is missing | Disable sending and show provider-specific install/login guidance; never fall back silently. |
| Selection changes while idle | The next turn uses the new provider and starts a fresh provider session. |
| Selection changes during a run | Let the current run finish with its original provider. The next queued/new turn uses the new provider with a fresh session. |
| Selection changes back later | Start another fresh session; do not resume a now-divergent old provider thread. |
| Existing transcript | Keep it visible and persisted. Only provider session continuity resets. |
| Other agent entry points | Unchanged. Dispatcher/on-duty detection and in-app terminal behavior remain as they are. |

The provider boundary is checked at each **turn boundary**, not only when a
conversation GenServer starts. That makes the global setting take effect across
already-open chat tabs without killing a live process or requiring an app
restart.

---

## Why this is not a one-line setting

The current Home chat is Claude-specific in four load-bearing places:

1. `BusterClaw.Agent.Chat` always adds Claude flags:
   `--output-format stream-json --verbose`, `--resume`, and
   `--append-system-prompt`.
2. `BusterClaw.Agent.StreamEvent` only understands Claude's NDJSON schema.
3. `BusterClaw.AgentRunner.detect/0` prefers Claude and falls back to Codex,
   which is useful for generic unattended work but wrong for an explicit UI
   choice.
4. Home-chat readiness and error copy say “Claude” even when `detect/0` found
   Codex.

Codex provides the primitives this feature needs, but through a different
contract:

- First turn: `codex exec --json ...`
- Continued turn: `codex exec resume --json <SESSION_ID> <PROMPT>`
- Session identity: `thread.started.thread_id`
- Assistant text: completed `agent_message` items
- Tool activity: `item.started` / `item.completed`
- Completion/usage: `turn.completed`
- Failures: `turn.failed` and `error`

Codex JSON mode emits JSONL on stdout while operational progress can use stderr.
The current runner merges stderr into stdout for Claude diagnostics. The provider
seam must therefore control stderr handling so non-JSON Codex diagnostics do not
pollute the JSONL stream.

Official references:

- [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)
- [Codex CLI command reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli#cli-codex-exec)

---

## Phase 0 — Lock the invocation contract

Before changing UI, capture real local fixtures for both providers.

### Claude fixture

Record a short `--output-format stream-json` run containing:

- session initialization;
- assistant text;
- one tool call;
- successful result metadata;
- one authentication/non-zero-exit example.

### Codex fixture

Record a short `codex exec --json` run containing:

- `thread.started`;
- `turn.started`;
- one command or MCP item;
- one `agent_message` item;
- `turn.completed` usage;
- one failed turn/error example;
- a second turn through `codex exec resume` using the captured thread ID.

Use fixtures in tests; never require a logged-in external CLI during ExUnit.

### Codex launch policy to prove in the spike

- Preserve saved Codex authentication; do not introduce API keys.
- Run in the configured Buster Claw workspace with a login shell.
- Pass `--json` and `--skip-git-repo-check`, because a user-selected Buster Claw
  workspace is not guaranteed to be a Git repository.
- Choose and document the least-permissive non-interactive sandbox that still
  lets Codex invoke the local `./buster-claw` command surface. Start by testing
  `workspace-write` with non-interactive approvals and the loopback access needed
  by the CLI. Do not reach for Codex's dangerous bypass flag without a separate,
  explicit trust decision.
- Do not use `--ephemeral`; Home chat needs persisted Codex threads for resume.

**Exit:** both event streams and first/resume argv shapes are represented by
stable fixtures and tests.

---

## Phase 1 — Add the durable preference and provider registry

Use the existing `app_settings` key/value store; no migration is needed.

### New module

Add `BusterClaw.Agent.Configuration` (or equivalently named provider registry)
as the only owner of the preference:

```elixir
@home_chat_provider_key "home_chat_provider"
@providers ~w(claude codex)

home_chat_provider() :: "claude" | "codex"
put_home_chat_provider(value) :: {:ok, Setting.t()} | {:error, term()}
provider_options() :: [map()]
provider_available?(value) :: boolean()
```

Rules:

- Missing, blank, or legacy state reads as `"claude"`.
- Writes accept only the fixed string allow-list; never convert user input to an
  atom.
- Each option exposes a label, executable name, availability, and concise setup
  guidance for the LiveView.
- Availability is provider-specific. Selecting Codex must not call the generic
  Claude-first `detect/0`.

### Runner support

Extend `BusterClaw.AgentRunner` with strict selection:

- `available?(:claude | :codex)` checks one executable.
- `open/2` and `run/2` honor `agent: :claude | :codex` even without an injected
  `agent_binary`.
- An explicitly selected missing provider returns a provider-specific error such
  as `{:agent_unavailable, :codex}`; it never falls through to the other CLI.
- Keep `detect/0` and its current Claude-first generic behavior for Dispatcher
  and other existing callers.

**Exit:** the setting defaults, validates, persists, and resolves each executable
without changing unattended work.

---

## Phase 2 — Separate chat orchestration from provider protocols

Introduce a small provider behavior rather than adding Codex conditionals
throughout `Agent.Chat`.

### Provider contract

Add:

- `BusterClaw.Agent.Provider`
- `BusterClaw.Agent.Providers.Claude`
- `BusterClaw.Agent.Providers.Codex`

The behavior should own:

```elixir
open_turn(prompt, session_id, opts) ::
  {:ok, %{port: port(), provider: atom()}} | {:error, term()}

parse_line(line) :: {:ok, BusterClaw.Agent.Event.t()} | :ignore | {:error, term()}
```

Keep the event consumed by `Agent.Chat` provider-neutral:

- `:session_started`
- `:assistant_text`
- `:tool_use`
- `:result`
- `:error`
- `:unknown`

Optional metadata should support both ecosystems without inventing values:

- `session_id`
- `cost_usd`
- `num_turns`
- input/cached/output/reasoning token counts
- raw provider event

Claude can continue supplying cost and turn count. Codex should supply token
usage when present and leave cost/turn count unset. Update the Home transcript's
meta-line formatter to render whichever metrics are actually available.

### Claude adapter

Move the current flags, resume syntax, append-system-prompt flag, and
`StreamEvent` normalization behind the Claude adapter with behavior-preserving
tests. This phase must not alter Claude's default experience.

### Codex adapter

Build provider-owned argv for the two distinct forms:

```text
codex exec [FIRST-TURN OPTIONS] <PROMPT>
codex exec resume [RESUME OPTIONS] <THREAD_ID> <PROMPT>
```

Map Codex JSONL into normalized chat events:

- `thread.started` → capture `thread_id` as the session ID;
- completed `agent_message` item → assistant text;
- command/MCP/web/file-change items → short tool/activity summaries;
- `turn.completed` → result with usage;
- `turn.failed` / `error` → visible chat error.

Do not render reasoning text into the transcript. It may update a generic
“thinking” activity state, but user-visible output should remain assistant
messages, tool summaries, results, and errors.

### Home-specific instructions

Claude currently receives the SVG guide through `--append-system-prompt`.
Codex has no equivalent flag in the chosen `exec` contract, so the Codex adapter
must safely compose that fixed guide with the user prompt using an explicit
delimiter. Preserve the user message as a discrete process argument; never
interpolate it into shell source.

### Port output

Add a runner option that lets structured providers keep stdout parseable:

- Claude may retain merged stderr so its current diagnostic tail still works.
- Codex JSON mode should parse stdout only and collect/bound stderr separately
  for failure diagnostics.
- Both buffers must remain bounded.

**Exit:** the same `Agent.Chat` lifecycle can run either provider, stream a
response, show tool activity, capture a session ID, resume, time out, interrupt,
and audit completion.

---

## Phase 3 — Make provider switching safe at turn boundaries

Update `BusterClaw.Agent.Chat` state with the provider that owns its current
session:

```elixir
%{
  provider: :claude | :codex | nil,
  session_id: String.t() | nil,
  ...
}
```

At the beginning of every turn:

1. Read the configured Home-chat provider.
2. If it matches `state.provider`, resume normally.
3. If it differs, set the new provider and clear `session_id` before spawning.
4. Snapshot the provider into the in-flight run record so a mid-run setting
   change cannot change how incoming lines are parsed.
5. When that run finishes, the next queued turn repeats the check and can switch.

Add `provider` to the Sentinel chat-run metadata. Keep transcript rows and the
current schema unchanged for this first slice; their stored session ID is
historical and is not used to select a provider after restart.

Provider-specific errors must name the provider and the correct recovery step:

- Claude: install/login with Claude Code.
- Codex: install/login with Codex.
- Never tell a Codex user to run `claude login`.

**Exit:** no session ID crosses providers, no active run is killed by a settings
change, and queued turns deterministically adopt the new selection.

---

## Phase 4 — Add Settings → Configuration UI

Place a new **Home chat agent** panel before Google Workspace in
`BusterClawWeb.SettingsLive`.

### Form

Build the form in `mount/3` with `to_form/2` and render it with `<.form>` and
the existing `<.input>` component. Use stable IDs:

- `#home-chat-agent-panel`
- `#home-chat-agent-form`
- `#home-chat-agent-provider`
- `#home-chat-agent-save`
- `#home-chat-agent-result`

The UI should show:

- Claude Code marked **Default**;
- Codex as the alternative;
- an Installed / Not found status for each CLI;
- one sentence explaining that the choice affects Home chat only;
- a note that changing providers starts fresh model context but preserves the
  visible transcript;
- provider-specific setup guidance when unavailable.

On save:

1. validate through `Agent.Configuration`;
2. persist through `BusterClaw.Settings`;
3. show a compact success/error state;
4. do not restart or kill chat processes.

Disable unavailable choices rather than saving a configuration that makes Home
chat unusable. Still handle an already-saved provider later disappearing from
`PATH`—the Home surface must fail clearly.

### Home readiness and copy

Update `StatusLive` and `ChatPanel` to check the **selected** provider rather than
generic `AgentRunner.detect/0`. Replace Claude-only copy with provider-aware
labels and install/login guidance. Keep Claude language in onboarding where it
describes the default, but add a short pointer that Codex can be chosen later in
Settings → Configuration.

**Exit:** a user can select Codex, save, return Home, and start a Codex-backed
chat without restarting Buster Claw.

---

## Phase 5 — Test matrix and verification

### Unit tests

- Default is Claude when the setting is absent.
- Only `claude` and `codex` persist.
- Provider availability is strict and never falls back.
- Existing generic `detect/0` behavior remains intact.
- Claude argv and parser fixtures remain unchanged.
- Codex first-turn and resume argv are correct.
- Codex JSONL fixtures normalize session, assistant, tool, usage, and errors.
- Partial JSONL chunks are buffered correctly.
- Structured stdout cannot be corrupted by stderr diagnostics.

### Chat process tests

- Claude remains the default.
- Codex captures `thread_id` and resumes it on the next turn.
- Switching Claude → Codex clears the Claude session ID.
- Switching during a running turn lets that turn finish, then switches the next
  queued turn.
- Switching back starts a fresh Claude session.
- A missing selected CLI produces provider-specific UI and no fallback.
- Interrupt, timeout, queue reorder, barge-in, persistence, and audit behavior
  pass for both adapters.

### LiveView tests

- `#home-chat-agent-form` renders in Configuration with Claude selected by
  default.
- Saving Codex persists and re-renders the selected state.
- Unavailable choices are visibly unavailable and cannot be submitted.
- Invalid form values are rejected without changing the stored preference.
- Home composer readiness and guidance follow the saved provider.
- Tests use IDs and LiveView helpers, not raw-HTML equality.

### Manual desktop smoke test

With both CLIs installed and authenticated:

1. Confirm Claude is the default on a fresh database.
2. Send two Claude turns and verify session continuity.
3. Select Codex in Configuration without restarting.
4. Send two Codex turns and verify `codex exec resume` continuity.
5. Run a safe `./buster-claw` tool action from Codex and confirm it appears in
   the chat and Sentinel feed.
6. Switch providers while a turn is running and verify the current turn is not
   cut off or parsed by the wrong adapter.
7. Temporarily hide each executable from `PATH` and verify the exact recovery
   message.
8. Run `mix precommit`.

---

## Files expected to change

### New

- `lib/buster_claw/agent/configuration.ex`
- `lib/buster_claw/agent/provider.ex`
- `lib/buster_claw/agent/providers/claude.ex`
- `lib/buster_claw/agent/providers/codex.ex`
- provider fixture files under `test/support/fixtures/agent/`
- focused provider/configuration test files

### Existing

- `lib/buster_claw/agent_runner.ex`
- `lib/buster_claw/agent/chat.ex`
- `lib/buster_claw/agent/stream_event.ex` (either generalized or retained as the
  Claude parser behind the adapter)
- `lib/buster_claw_web/live/settings_live.ex`
- `lib/buster_claw_web/live/status_live.ex`
- `lib/buster_claw_web/components/chat_panel.ex`
- relevant Settings, StatusLive, Chat, StreamEvent, and AgentRunner tests
- user-facing setup/Get Started copy that currently claims Home chat can only be
  Claude

No Ecto migration, Tauri/Rust change, API credential work, or new dependency is
required for this slice.

---

## Acceptance criteria

This capability is complete when:

- Claude is the durable default for Home chat.
- Settings → Configuration exposes Claude and Codex with installation status.
- A saved Codex selection takes effect on the next Home-chat turn without an app
  restart.
- Claude and Codex both stream assistant text and useful tool activity.
- Each provider resumes only its own sessions.
- Changing providers preserves the transcript but starts fresh provider context.
- Missing CLIs and authentication failures identify the selected provider and
  explain the correct fix.
- Dispatcher, on-duty shifts, terminal agents, trust tiers, command policy, and
  audit behavior do not regress.
- `mix precommit` passes.

## Explicitly deferred

- Provider-specific model IDs and reasoning-effort controls.
- Per-conversation provider selection.
- Automatic provider fallback or failover.
- Changing the unattended Dispatcher/swarm provider.
- OpenAI API or Anthropic API integrations.
- Cloud-hosted agents.
- Migrating an active conversation's hidden context between providers.

The natural next roadmap after this one is **provider-specific model settings**:
keep the same provider registry, add validated model choices beneath each
provider, and pass the selected model through the adapter (`claude --model` or
`codex exec --model`) without changing the chat orchestration again.
