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

### Repositioning audit (off "local-first" / "research tool")

- Identity shift: Buster Claw is **a desktop runtime where an AI agent manages
  the user's web interactivity**, not a local-first research tool. The core
  reason it's not local-first: the primary AI usage is **Claude Code / Codex in
  the in-app terminal**, driving Buster Claw via its MCP server + workspace —
  the intelligence is remote. Built-in chat is secondary.
- Scrubbed stale framing from live copy: README (intro + features + a new "How
  it's used" lead), `Intentions.md` analysis persona, `introduction.ex` (model
  guide), and `setup_live.ex` onboarding. Fixed a factual error in
  `docs/LOCAL_TRUST.md` (secrets are AES-256-GCM at rest, not plaintext JSON).
- Committed as `6d77a09`.

### Advanced tab UX

- Collapsed all Advanced sub-routes into a single "Advanced" tab in the top tab
  strip (`assets/js/app.js` TabStrip): `currentKey()` maps any advanced route to
  `/advanced`, and `sync()` prunes legacy per-subroute tabs. Traversing the
  sub-tabs now only moves the in-page highlight — no new top-level tabs.
- Removed the eyebrow/title/subtitle headers from all ten Advanced views,
  preserving the Poll All / Acknowledge all / Connect Account controls.
- Committed as `6d77a09`.

### Workspace markdown blog preview

- Clicking a `.md` file in the Workspace tab now renders a sanitized, blog-style
  reading view (no raw source). New `BusterClaw.Markdown.to_html/1` strips
  frontmatter, renders with Earmark, and sanitizes via HtmlSanitizeEx's markdown
  scrubber (workspace files can be agent-authored; CSP is report-only).
- Added `earmark` + `html_sanitize_ex` (pure Elixir/Erlang — bundle-safe).
- Self-hosted **Atkinson Hyperlegible** (400/700 + italics) in
  `priv/static/fonts`; added a `.md-prose` stylesheet — **14px Atkinson**, ~68ch
  reading column, styled headings/links/quotes/lists/tables; code stays mono.
- Gotcha: a running dev server started before a dep is added won't have it in
  its code path — adding deps requires a server restart (hit
  `Earmark.as_html/2 undefined` until restart).
- Committed as `72256bc`.

### Split panes + workspace sidebar bumper

- Joined tabs (`/split`) now fill the window: added a `full_bleed` option to
  `Layouts.app` (drops the `max-w-7xl`/padding cap) and made the split grid +
  panes `flex-1`, so widening/heightening the desktop window grows the panes
  (previously capped at 1280px and a fixed `min-h-[70vh]`).
- Added a collapsible **bumper** to the Workspace file tree: a slim
  hazard-orange–tinted handle attached to the sidebar's right edge with a
  `<`/`>` chevron. Collapsing hides the tree (kept mounted, state preserved) so
  the markdown preview goes full-width for reading.

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
