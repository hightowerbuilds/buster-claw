# 06-13-26 Roadmap — Multi-agent terminal support

Make Buster Claw's human-run terminal agent work for engines beyond Claude Code.
The app is already ~80% engine-agnostic: the terminal spawns the user's `$SHELL`
(`desktop/tauri/src/terminal.rs`), the command surface / CLI / MCP are LLM-neutral
(`lib/buster_claw/commands.ex`, `cli.ex`), and the orchestration schema already
carries an `engine` field (`lib/buster_claw/orchestration/task.ex` `@engines`).
The remaining work is a per-engine **agent profile** plus de-Clauding the seed
config, UI copy, and docs.

## Decisions locked with the operator

- **Target engines:** Claude Code, OpenAI Codex, Gemini CLI, opencode, pi-agent,
  OpenRouter.
  - **OpenRouter is not a standalone terminal agent** — it is a model-API gateway
    (base URL + key) configured *inside* another CLI, so it's a provider dimension,
    not its own profile.
  - **pi-agent's mechanism is unidentified** — needs research before its profile
    can be written.
- **Selection model:** multiple agents seeded **side-by-side** per workspace (run
  different engines in different terminal tabs).
- **Scope:** terminal agents only. **Headless dispatch stays cut** — the
  Orchestrator remains a janitor and the `agent_runner_*` config + `engine` field
  stay latent. See [[orchestration-plan]].

## Already engine-agnostic (no work)

- Terminal spawn — `desktop/tauri/src/terminal.rs` runs `$SHELL` with the login
  profile; no agent assumption.
- Command surface / CLI / MCP — `commands.ex`, `cli.ex`; no LLM coupling.
- Orchestration schema — `orchestration/task.ex` `@engines`, `agent_run.ex` `:engine`.
- No Anthropic API / model-ID / `ANTHROPIC_*` coupling anywhere — the agent brings
  its own subscription.

---

## Phase 0 — Verify per-engine mechanisms (PRE-WORK; blocks Phase 2)

The autonomy key/config file differs per engine; getting it wrong means the agent
still stalls on a permission prompt — the exact failure just fixed for Claude.
Confirm for each engine: launch command, autonomy/bypass config (path + format),
native context filename, and config scope (project vs home).

| Engine | Launch | Autonomy config | Context file | Scope | Status |
|---|---|---|---|---|---|
| Claude Code | `claude` | `.claude/settings.json` → `bypassPermissions` | `CLAUDE.md` | project | ✅ verified (in use) |
| Codex | `codex` | `~/.codex/config.toml` approval/sandbox + `--full-auto` | `AGENTS.md` | **home** | ⚠️ verify |
| Gemini CLI | `gemini` | `.gemini/settings.json` / `--yolo` | `GEMINI.md` | project+home | ⚠️ verify |
| opencode | `opencode` | `opencode.json` permissions | `AGENTS.md` | project | ⚠️ verify |
| pi-agent | ? | ? | ? | ? | ⚠️ identify |
| OpenRouter | (via another CLI) | provider base-URL + API key env | n/a | n/a | provider, not a profile |

Output: a verified profile table (research spike or operator-provided).

## Phase 1 — `BusterClaw.AgentProfile`

1. New `lib/buster_claw/agent_profile.ex`: a registry of profiles, each
   `%{key, name, launch_cmd, context_filename, config_scope, write_autonomy_config: (workspace_root -> :ok)}`.
   One profile per verified engine.
2. Persisted workspace setting for **enabled agents** (a list — multi-select).
   Mirror how `workspace_root` is persisted/boot-read (`workspace_live.ex`
   `write_boot_file` + the Application Support boot file).
3. Helper to enumerate the enabled profiles for the current workspace.

## Phase 2 — Generalize seeding

1. `lib/buster_claw/jobs.ex`: replace the hardcoded `seed_agent_settings/0`
   (`.claude/settings.json`) with a loop over enabled `AgentProfile`s, each writing
   its own autonomy config via `write_autonomy_config/1` (still `maybe_write` — never
   overwrite an operator-authored file).
2. Seed each engine's **native context file** (`CLAUDE.md` / `AGENTS.md` /
   `GEMINI.md`) referencing `INTRODUCTION.md` + the job descriptions, so every agent
   auto-onboards. (Also fixes today's gap: nothing auto-loads `INTRODUCTION.md` even
   for Claude.)
3. Codex home-scope caveat: its autonomy config is `~/.codex/` (global, not
   per-workspace). Either write it once globally with a clear log line, or document
   that Codex autonomy is machine-wide. Flag in the UI.

## Phase 3 — UI

1. `setup_live.ex:162` — replace "Claude Code or Codex" with a multi-select
   "which agents do you use?" that drives the enabled-agents setting.
2. `status_live.ex:120` get-started step 2 — parameterize "start a Claude Code
   session" off the enabled set (e.g. "start your agent: `claude` / `codex` /
   `gemini` …").
3. `orchestration_live.ex` — engine `<option>`s (~688-691) and the `"claude"`
   defaults/fallbacks (~53, 827, 1028) driven by the enabled agents, not hardcoded.

## Phase 4 — Docs

- `daily-growth/user-guide/introduction.md`, `daily-loop.md` — broaden
  "Claude Code (or Codex)" to the supported roster + the "bring your own
  subscription" framing.

## Done-bar

- `mix test` green; `mix compile --warnings-as-errors` + `mix format --check-formatted`
  clean; working tree intentional.
- A fresh workspace seeds an autonomy config + native context file for every
  enabled agent.
- Starting any one enabled agent in a terminal tab, on shift, it reads its context,
  picks up the queue, and acts autonomously — **re-validate the trusted-email posture
  per engine** (it was only tested on Claude).
- Setup / get-started / orchestration copy names no single agent unless it's the
  only one enabled.

## Notes / open follow-ups

- pi-agent + OpenRouter specifics are needed before Phase 2 (Phase 0 output).
- Codex's home-scoped config breaks clean per-workspace side-by-side — accept it as
  machine-wide or document the limitation.
- Re-validate the autonomy posture ("trusted email = the prompt") on each engine;
  bypass semantics differ (Codex's sandbox especially is not a 1:1 of Claude's
  `bypassPermissions`). Relates to [[security-layer-research]].
- Headless per-engine dispatch (a would-be Phase 5) is intentionally deferred — see
  [[orchestration-plan]].
