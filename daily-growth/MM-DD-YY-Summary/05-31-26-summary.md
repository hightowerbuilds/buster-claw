# 05-31-2026 Summary

## Today

### Codebase orientation

- Did a full fan-out read of the codebase to re-ground on the post-rewrite
  architecture (Elixir/Phoenix LiveView + Tauri desktop shell, ~22k lines lib).
- Confirmed the keystone: `lib/buster_claw/commands.ex` (~1.3k lines) is the
  single canonical command surface (~76 commands). Every frontend — HTTP API
  (`/api/run`), MCP server (`/mcp`), CLI escript, and the internal chat agent —
  dispatches through `Commands.call/2`, which enforces caller tiers
  (`:trusted | :agent | :mcp`), refuses `:restricted` commands for untrusted
  callers (queued in `Sentinel.Pending`, not executed), and audits via
  `Sentinel.observe`.
- Mapped the core pipeline (Sources → Ingest → Library → Analysis → Delivery),
  the AI layer (supervised per-session chat GenServers, pluggable providers,
  Anthropic-only agentic tool loop capped at 6 iterations, MCP client/host),
  automation (scheduler/hooks/webhooks/integrations), the Sentinel security
  spine, and the LiveView + Tauri frontends.

### Single-command dev launcher

- Diagnosed why the desktop window wasn't opening: `cargo tauri dev` (debug
  build) deliberately does **not** spawn Phoenix — `main.rs:39–43` waits for an
  external `mix phx.server` on `:4000` (so Elixir edits hot-reload). It times
  out after 180s. Phoenix's first-boot compile exceeded that, so Tauri quit
  before Phoenix was ready. Pure ordering bug, not a config problem.
- The release build path is different and self-contained: `main.rs:44–78`
  spawns the bundled Phoenix release on a private port and shows the window once
  `/_health` passes — that's `scripts/build_desktop.sh`'s output (`.app`/`.dmg`).
- Added **`scripts/dev.sh`** — one command for day-to-day dev:
  1. Reuses Phoenix if already on `:4000`, else starts `mix phx.server`
     (logs → `_build/dev/phx.server.log`).
  2. Polls `/_health` until ready, so Tauri never hits its timeout.
  3. Opens the desktop window (`cargo tauri dev`).
  4. Ctrl-C / window-close tears down the Phoenix it started; an already-running
     one is left alone.
- Verified end-to-end: launcher reused the running Phoenix and opened the window
  with zero "waiting for dev server" warnings (`buster-claw-desktop` PID alive,
  Phoenix `/_health` → 200).

## Notes

- Run dev with: `./scripts/dev.sh` (single command, no manual port juggling).
- Build the installable, self-contained app with: `./scripts/build_desktop.sh`.
- Repo has committed cruft worth gitignoring: `erl_crash.dump`, multiple SQLite
  `*.db`/`-shm`/`-wal` files, and the fully-bundled Erlang release under
  `desktop/tauri/resources/release/`.
- Two parallel AES-256-GCM vaults exist (`BusterClaw.Vault` and
  `BusterClaw.Google.Vault`) — consolidation candidate.
- Agentic tool-calling loop is Anthropic-only; OpenAI/Gemini/Codex tool adapters
  still TODO (fall back to plain chat).

## Next

- Consider a `make dev` / `mix` alias wrapping `scripts/dev.sh` for
  discoverability (optional — the script alone is sufficient).
- Add a `.gitignore` sweep for the crash dump, dev/test DBs, and the staged
  release resources.
