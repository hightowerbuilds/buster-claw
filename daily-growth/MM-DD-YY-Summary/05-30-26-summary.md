# 05-30-2026 Summary

## Today

### Codebase review

- Ran a fan-out review of the Phoenix codebase (~18.5k lines lib, ~7.4k lines
  test) across three lenses: security attack surface, architecture/code quality,
  and test maturity.
- Headline findings:
  - Secrets (provider API keys, integration/webhook/delivery tokens) were
    serialized in cleartext by the command surface and stored unencrypted at
    rest, exfiltratable via the chat agent's safe-tier tools (prompt injection).
  - `hook_test` was `:safe`, letting the agent run stored shell hooks.
  - Browser/ingest fetchers had no SSRF protection.
  - Architecture is sound; main debt is catalog/impl drift risk in `commands.ex`,
    a god `Integrations` context, an oversized `status_live.ex`, and duplicated
    changeset-error/chunk-collector code.
  - Test suite graded B+: disciplined HTTP mocking, deterministic time, real
    assertions; gaps around `agent_tools.ex` and the agentic loop.

### UML / architecture diagrams

- Added `docs/UML.md`: layered Mermaid diagrams generated from the code —
  system layers, supervision tree, domain model (all 18 schemas + relations),
  command-surface dispatch, provider abstraction, plus functional flows
  (ingest→analyze→deliver, agentic chat loop, HTTP routing/auth tiers).
- Linked it from the README Development Notes section.

### Security hardening pass

- C1 — Secret redaction in `Commands.Result.to_json`: denylist
  (`api_key`, `secret`, `token`, `webhook_secret`, `client_secret`,
  `refresh_token`, `access_token`, `password`) plus any `*_enc` column now
  serialize as `"[REDACTED]"`; unset secrets stay nil. Closes the prompt-injection
  exfiltration path through the agent's safe-tier `*_list`/`*_get` tools.
- C2 — Encryption at rest:
  - Added `BusterClaw.Vault` (app-wide AES-256-GCM) and `BusterClaw.Encrypted`,
    a transparent Ecto type (cast/hold plaintext, encrypt on dump, decrypt on
    load, legacy-plaintext passthrough).
  - Applied to `providers.api_key`, `webhooks.secret`,
    `delivery_destinations.token`, `integrations.token`, and
    `integrations.webhook_secret`. No ripple into contexts — structs still hold
    plaintext after load.
  - Added backfill migration `20260528223000_encrypt_secrets_at_rest`
    (idempotent; skips already-encrypted values).
  - Verified end-to-end against the real dev DB: `api_key` now stored as
    `0x01…` ciphertext, loads back as plaintext.
- H1 — Reclassified `hook_test` as `:restricted` (no longer exposed to the chat
  agent, verified by an `AgentTools` test).
- H2 — Added `BusterClaw.URLGuard`: blocks loopback, link-local/metadata
  (169.254.0.0/16), and RFC1918 hosts (IP literals incl. IPv6/IPv4-mapped, plus
  DNS resolution) at the `Browser.fetch` / `Ingest.Fetcher` entry points, and
  re-validates each redirect hop via a Req request step. DNS resolution is
  config-gated (`:ssrf_resolve_dns`, off in test).
- Residual gaps documented (not fixed): DNS-rebinding TOCTOU, fail-open on
  resolution error, and OS-keychain storage for the vault key.

### Leftovers.md updates

- Added a "Security Hardening (2026-05-28)" section recording C1/C2/H1/H2.
- Corrected the stale "reconfirm encrypted-secret design" line to note
  encryption is now applied to provider/integration/webhook/delivery secrets.
- Reframed the packaging item to "OS keychain support for the vault key" (the
  one remaining piece).

### In-app browser

- Added a dedicated in-app browser at `/browse` (`BusterClawWeb.BrowseLive`)
  rendered inside `Layouts.app`, so the app-nav sidebar + bumper is always
  present to return to the rest of the app.
- Features: URL bar (bare hosts auto-upgrade to `https://`), back/forward/reload
  with in-memory history, and inline links that re-fetch in place so the user
  never leaves the app.
- Added `BusterClaw.Browser.Reader`: tokenizes fetched HTML server-side into a
  safe `{:text, …}` / `{:link, text, url}` stream — no raw HTML, no sanitizer
  dependency, no JS hook. Scripts/styles stripped; anchors resolved to absolute
  http(s) against the page URL; `mailto:`/`#`/`javascript:` degrade to text.
  Links render as `phx-click` buttons.
- Reused the SSRF guard: blocked addresses show a safe inline message.
- Added the `/browse` route and a "Browse" sidebar nav item.
- Rationale: `Content.html_to_markdown` strips all tags, so the existing
  markdown had no links — the reader works from the raw page HTML instead.

### Document reader source link + deep linking

- Added `handle_params/3` to `BrowseLive` so `/browse?url=…` auto-loads (browse
  pages are now bookmarkable/deep-linkable).
- Repointed the Documents reader's source link from a bare external `<a href>`
  (which hijacked the whole Tauri webview) to a `<.link navigate={~p"/browse?…"}>`
  ("Open Source") that opens the source page inside the in-app browser.
- Net result: every route into external content — address bar, in-page links,
  and the document source link — now stays inside the app.

### Library tab group + sidebar slimming

- Added `BusterClawWeb.LibraryTabs` (a shared tab row in the same style as the
  Advanced tabs) and grouped Documents, Sources, and Analysis as sibling tabs.
- Removed Sources and Analysis from the sidebar; Documents is the single entry
  point into the group. Both stay routable.
- Renamed the first Library tab's label from "Documents" to "Library".
- Deleted the local Library data folder at
  `/Users/lukehightower/Desktop/websites/Library` (regenerated on next ingest).

### Tabbed window shell (sidebar → bottom dock, browser-style top tabs)

- Moved the navigation from the left sidebar to a horizontal **dock across the
  bottom** of the window.
- Added a browser-style **tab strip across the top** (`TabStrip` hook in
  `app.js`): each open route is a tab with its name and an × to close. Open tabs
  persist in `localStorage` (`bc:tabs`); the active tab tracks the URL.
- Updated `status_live_test` to assert the new `#tab-strip` / `#app-dock` shell.

### Multiple browser tabs

- Tabs are keyed by full path incl. query, so several `/browse` tabs coexist.
- A **"+"** at the end of the tab strip opens a fresh independent browser tab
  (`/browse?t=<id>`), each with its own URL bar and history.

### Split-view tab joining

- Drag a tab onto another (**Alt+drop**) to join them into a side-by-side
  **split tab** at `/split?left=…&right=…`; plain drag **reorders** tabs.
- `BusterClawWeb.SplitLive` renders each pane via nested `live_render`, mounted
  `embedded: true`; `BusterClawWeb.ChromeHook` (an `on_mount` added to the
  `:live_view` macro) makes embedded panes render **bare** (no tab strip/dock).
- Split panes have **Swap panes** and **Open as tab (unjoin)** controls.
- **URL-carry**: a joined Browse pane keeps its current page — the join link
  carries the url, `SplitLive` passes it via `session["url"]`, and `BrowseLive`
  loads from params **or** session (its `?url=` handling moved from
  `handle_params` to `mount` so it can be embedded).
- **Tab titles**: `BrowseLive` pushes `bc:tab_meta` (title + url) on load; the
  tab strip shows the page title instead of "Browse".
- The last two were built by **dispatching two parallel agents** over disjoint
  file sets (SplitLive vs. `app.js`/`BrowseLive`) with a shared contract, then
  integrated and verified centrally.

### Terminal tab (xterm.js + Rust PTY)

- Added an in-app **Terminal** tab. xterm.js renders in the webview; the PTY
  that runs `$SHELL` lives in the existing Tauri Rust shell via `portable-pty`,
  reached over IPC. No new language (Elixir + Rust + JS already in play).
- Rust: `desktop/tauri/src/terminal.rs` (session map + `terminal_open/input/
  resize/close` commands + a reader thread emitting `terminal:data:<id>`),
  wired into `main.rs` (`manage`, `invoke_handler`, exit cleanup);
  `withGlobalTauri` enabled in `tauri.conf.json`.
- Frontend: `@xterm/xterm` + `@xterm/addon-fit` installed into `assets`, xterm
  CSS imported in `app.css`, a `TerminalView` hook in `app.js` (Tauri-detect,
  open/listen/onData/resize; shows a "desktop app only" notice in a plain
  browser). `TerminalLive` at `/terminal` + dock nav entry.
- Decision recap: chose xterm.js over embedding Alacritty's engine — Alacritty
  is a standalone GPU window, not embeddable in a webview; xterm.js is simpler
  and the PTY in the existing Rust shell keeps it real without new languages.
- Unblocked `cargo tauri dev`: a leftover **full staged release** (2,154 files)
  in `desktop/tauri/resources/release` from a past `build_desktop.sh` was
  tripping `tauri-build`'s resource walk (EACCES); restored the dev `.gitkeep`
  placeholder (packaging re-stages it).

### Agent mode on by default

- `BusterClaw.AgentMode` now boots **on** (new `:agent_mode_default` config,
  defaults `true`; override with `config :buster_claw, :agent_mode_default,
  false`). The agent surface is live as soon as the app opens.

### BusterClawCLI data root (decided; build deferred)

- Decided `BusterClawCLI` is the app's **actual data root** (not a workspace):
  user-choosable location, default `~/Desktop/BusterClawCLI`, structure
  `library/sources/analysis/memory`, provisioned on **`.dmg` install**, and the
  Terminal opens into it. Contents still evolving; full build deferred to the
  DMG-install milestone. Captured in project memory.

### Tab interactions: context menu, join / separate / reorder

- Right-click a tab for a context menu (`TabStrip` hook). A normal tab shows
  **Join tabs ▸** → a list of other open tabs; picking one joins them.
- Drag a tab to **reorder**; **Alt+drop** onto another tab joins them.
- Joining **consumes** the two source tabs (they live inside the joined tab).
- A split tab's menu shows **Swap sides** and **Separate tabs** (splits it back
  into its two component tabs).

### Tab chrome cleanup (headers, status bar, rename)

- Removed page headers from the **Browser** and **Terminal** tabs and pulled
  them flush with the tab bar (embedded panes are flush against the partition).
- Removed the SplitLive "Split view" header; moved Swap into the menu.
- Removed the shell status-bar chips (Agent mode / PubSub / Endpoint).
- Renamed **Browse → Browser** in the dock, tab labels, and split pane label.

### Terminal in split panes

- `/terminal` is now embeddable in split panes (added to SplitLive's pane map);
  unique per-instance container id so two terminal panes don't collide. Each
  pane is its own PTY session.

### Runtime control → Advanced tab

- Extracted the home page's runtime control (mode selector, Models/API-key
  panel, agent-handoff panel + all events/helpers) into a new
  `BusterClawWeb.RuntimeLive` at **/runtime**, added as a **Runtime** tab in the
  Advanced tab row. The home page no longer carries provider/agent controls.

### Recent emails on the home page

- The GWS container now shows **recent emails** (`#home-recent-emails`), fetched
  live from Gmail for the default connected account (`Gmail.search`, the
  account's `default_query` or `newer_than:7d`, 5 messages) via an async
  `:load_recent_emails`. Graceful loading / no-account / error / empty states;
  re-fetches when an account connects.

### Cybersecurity layer — research & planning (no app code changed)

- Researched the full security posture for a defensive "notify the user of
  dangerous data/activity" layer, given the app brokers untrusted external
  agents (MCP), downloads untrusted content → LLM, and sends data outbound. All
  output is planning docs in `daily-growth/roadmaps/` — nothing built.
- **⭐ MCP tier-bypass (CRITICAL, verified in source):** the chat agent is
  sandboxed to `tier == :safe` (`agent_tools.ex:31-50`), but `McpController`
  applies **no** tier filter — `tools/list` uses full `Commands.list_commands()`
  (`mcp_controller.ex:56`) and `tools/call` → `Commands.call/2` runs with no
  check (`commands.ex:55-65`). Any MCP client with the bearer token can call any
  restricted command (`gmail_send`, shell `hook_*`, `mcp_server_connect`,
  provider/credential swaps).
- **Desktop RCE-class path (verified):** `tauri.conf.json` has `"csp": null` +
  `"withGlobalTauri": true`, and `app.js` drives a real `$SHELL` PTY via
  `invoke("terminal_open")`. Any JS in the webview (LiveView XSS, or the in-app
  browser hitting a hostile page) → full shell as the user; invoke handlers
  aren't origin-scoped.
- Other gaps: no durable audit log (`agent_mode.record_activity` is ephemeral,
  off by default, not called by MCP); untrusted content fed verbatim into LLM
  prompts; delivery/hook outbound targets POST to arbitrary URLs; URLGuard
  fails open on DNS error + the sidecar `Req.post` path is unguarded.
- Roadmap docs written (suggested order **0→1→5→2→3→4→6**):
  - `05-30-26-security-notification-layer-research.md` — master: threat model,
    controls inventory, 6-phase "Sentinel" design (classify→audit→notify→gate
    via `Commands.call/3`).
  - `05-30-26-phase-0-mcp-tier-fix-plan.md` — close the silent-exec hole.
    **Decided:** Option A+B (scoped MCP token, airtight) + a minimal pending stub.
  - `05-30-26-phase-1-audit-notify-spine-plan.md` — `Sentinel` on the existing
    `Workflow.record_event`, `risk:`/`outward:` metadata, alert center + Tauri
    OS notifications.
  - `05-30-26-desktop-shell-terminal-hardening-plan.md` — Phase 5 (RCE): CSP,
    lock down `withGlobalTauri`, origin-scope `terminal_*`, isolate in-app browser.
  - `05-30-26-phases-2-4-plans.md` — confirmation gating, data-trust/injection
    hardening, baseline web/crypto hardening.
- Open Phase-5 question: does the in-app browser share the privileged webview or
  use a separate one? (Determines config tweak vs. rebuild for isolation.)

### Visual identity: Industrial Claw (shipped this session)

- Replaced the stock Phoenix/daisyUI scaffold look (source of the "prototype
  feel") with a brutalist, high-contrast, tool-like identity. Balanced
  transparency; full-app page-by-page scope. Captured in design memory; mockup at
  `daily-growth/mockups/industrial-claw-preview.html`.
- **Color** — daisyUI dark+light themes rebuilt in `assets/css/app.css`: dark
  default (near-black `#121212`/`#0c0c0c`, text `#fafafa`, hazard-orange accent
  `#ff4d1c`, `--depth/--noise: 0`, 2px borders) + warm-paper light (`#f4f1ea`).
- **Fonts** — **Archivo** (heavy display), **IBM Plex Sans** (body), **IBM Plex
  Mono** (data/labels/terminal), all **self-hosted** in `priv/static/fonts/`
  (no CDN — respects offline/desktop posture), wired via `@font-face` + `@theme`
  `--font-*`, key weights preloaded in `root.html.heex`.
- **Transparency** — balanced: glass blur (`.ic-glass`) on tab strip + dock only;
  panels solid with hard offset shadows. **No grid background** (tried, removed
  at user request).
- **Utilities** — `.ic-panel`, `.ic-panel-h`, `.ic-eyebrow`, `.ic-stat-n/-l`,
  `.ic-dot`, `.ic-glass`, plus `.btn`/`.input`/`.table` daisyUI overrides.
- **Applied** — shell chrome (tab strip with accent active-bar + mono labels,
  dock, BC logo, theme toggle in `layouts.ex` + `TabStrip` hook); every page
  heading (~18 LiveViews) → mono eyebrow + heavy display `<h1>`; flagship pages
  fully restyled (Home/Status, Chat, Documents, Terminal).
- **Terminal background now matches the app** — the xterm.js theme reads live
  `--color-base-100/-content/-primary` CSS tokens at mount (was hardcoded
  `#1e1e2e`), so it tracks dark/light; font switched to IBM Plex Mono.
- Status: font files + `app.css`/`app.js`/LiveView changes are working-tree, not
  yet committed. Remaining: non-flagship page *bodies* still have stock-styled
  cards under the new headings.

### Desktop relaunch + home header trim

- Relaunched the Tauri desktop app for this session. Hit a fresh manifestation of
  the read-only-resource issue: 60 stale **read-only** copies (`-r-xr-xr-x`) in
  `desktop/tauri/target/debug/release` from a prior staged build made
  `tauri-build`'s `copy_resources` fail with EACCES (it overwrites without
  `remove_file`). Cleared with `chmod -R u+w resources/release target/debug/release`;
  app launches clean. Also applied the pending `security_events` migration.
- Trimmed the home header: removed the "Local-first research and chat runtime."
  tagline and set the "Buster Claw" `<h1>` to exactly 20px (`text-[20px]`).

### First-run Setup wizard + Settings tab (shipped this session)

- **Why:** no guided onboarding existed and there was **no settings store** at all
  (config lived only in `config/*.exs` + env vars; per-feature data in Ecto tables).
- **Settings store (foundation):** new `app_settings` key/value table
  (`20260531020000_create_app_settings`), `BusterClaw.Settings.Setting` schema, and
  `BusterClaw.Settings` context (`get/put/get_all/delete` + `onboarding_completed?`/
  `mark_onboarding_complete`/`reset_onboarding`).
- **Workspace relocation model:** adopted a **workspace root** containing
  `library/ sources/ analysis/ memory/`. Non-breaking — `Artifact.root/0` still reads
  `:library_root` (≈15 test files depend on it); added `Artifact.workspace_root/0`
  (defaults to the parent of the library root), `workspace_subdirs/0`, and
  `ensure_workspace_dirs/0`. `config.exs`/`runtime.exs` derive `library_root` from
  `BUSTER_CLAW_WORKSPACE_ROOT` when the desktop sets it; dev/test untouched.
- **Tauri workspace IPC:** new `desktop/tauri/src/workspace.rs`. Boot source of truth
  is a Tauri-owned plain-text `workspace_root` file in the data dir (read in `main.rs`
  before Phoenix spawns, passed as `BUSTER_CLAW_WORKSPACE_ROOT`; default
  `~/Desktop/BusterClawCLI`). Commands: `workspace_current`, `workspace_pick` (existing
  folder), and `workspace_relaunch` (`app.restart()`). Added `tauri-plugin-dialog`,
  build.rs command list, autogenerated permissions, and capability grants.
- **Frontend bridge:** `WorkspacePicker` hook in `app.js` (Tauri-detect; degrades to a
  read-only path in the plain-browser dev server) bridges the LiveView to the IPC.
- **`/setup` wizard** (`SetupLive`): steps intro → workspace → GWS → AI provider → done.
  Reuses `Google.upsert_account`/`GoogleOAuth.authorization_url` and
  `Providers.create_provider`/`set_active_provider`; finishing calls
  `Settings.mark_onboarding_complete/0`.
- **`/settings` hub** (`SettingsLive`): global prefs (workspace path + change, onboarding
  status, re-run setup) + a card grid linking to existing config tabs (Runtime/GWS/
  Integrations/Delivery/MCP/Scheduler/Hooks/Webhooks/Security). No duplicated UIs.
- **Routing/nav/home:** added `/setup` + `/settings` routes, a **Settings** dock entry,
  and a "Set up Buster Claw" home CTA shown only while onboarding is incomplete.

### Create-a-workspace flow (name it, then choose where it goes)

- Reworked the wizard's workspace step from pick-existing-only to **create new**: a name
  field (default `BusterClawCLI`) + "Choose location & create →" that opens a native
  location picker and creates `<location>/<name>` with the full sub-dir scaffold.
- New Tauri commands `workspace_choose_parent` (pick location, no side effects) and
  `workspace_create(parent, name)` (validates the name — rejects empty/slashes/`..` —
  creates + scaffolds + persists). JS hook chains them via `workspace:choose_and_create`.
- "Use an existing folder" kept as a secondary option; "Apply & restart" appears once a
  workspace is created/picked.

### Setup progress is derived; identity step added

- **Why:** the home CTA was gated on a single "finished" flag, so a user who skipped steps
  still looked "done." Now completion is **derived from real state** so the button reflects
  actual progress and disappears only when everything is genuinely done.
- New `BusterClaw.Setup` module: tracked steps `profile` / `workspace` / `google` / `provider`
  with per-step `complete?` checks (profile = name or org set; workspace = explicit confirm;
  google = ≥1 connected account; provider = ≥1 provider) + `status/0`
  (`completed`/`total`/`complete?`).
- **Home CTA** now reads "Set up Buster Claw" at 0/4 and "Finish setup · N of 4 complete"
  while partial; hidden only at 4/4 (replaces the old `onboarding_completed?` gate).
- **New identity step** ("You") collects **name / organization** (≥1 required) into settings
  (`profile_name`/`profile_org`); wizard step bar is now Welcome · You · Workspace · Google ·
  AI Model. Workspace step gained a **"Use this workspace"** confirm so it can complete in dev
  too. Done step shows a live checklist of the 4 tracked steps.
- **Settings hub** gained a **Profile** form (edit name/org) and a **Setup progress** checklist.

### Home page: GWS panel removed, two-column full-height layout

- Removed the "Connect GWS" panel (and its nested recent-emails section) from the home page
  along with all its now-dead handlers/helpers/aliases. GWS lives at `/gws` + the setup wizard.
- Home is now a **two-column, full-height** layout: an (empty, reserved) left container and the
  daily calendar on the right, both stretching down to the dock. Achieved by making the shell's
  `main`/content wrapper a full-height flex column in `layouts.ex` (centering preserved via
  `mx-auto`/`max-w-7xl`), then `flex-1` on the home grid.

### Terminal opens in the workspace

- The Terminal tab (and split-pane terminals) now start in the **workspace folder** instead of
  home. `TerminalLive` passes `Artifact.workspace_root/0` as `data-cwd`; the `TerminalView` hook
  forwards it to `terminal_open`, which `cd`s there when it's a real dir (falls back to home).

### Settings polish

- Profile and Workspace panels sit **inline** (Profile left, Workspace right); workspace folder
  list is **stacked**. Added a **Profile** form (name/org) and set the profile name to
  "Luke Hightower" (org `hightowerbuilds`). The **Configure** cards now show a **green check**
  for every surface that's actually configured (providers, GWS, integrations, scheduler, webhooks
  — derived from each context's list function).

### Workspace file manager (replaced the native picker)

- **Why:** the native Tauri folder dialog was fragile (desktop-only, restart-required, split
  state). Replaced it with an in-app, **server-side** IDE-style file manager — Phoenix has full
  local FS access, so no Tauri dialog/IPC and it works in dev + desktop identically.
- **`BusterClaw.FileManager`** — secure lazy FS ops (`list`/`read_file`/`create_dir`/`create_file`/
  `rename`/`move`/`delete`), every call guarded by `within?/2` (no escaping the base).
- **`BusterClawWeb.FileTree`** — reusable LiveComponent: expand/collapse folders (lazy), click a
  file to preview, per-row new/rename/move/delete + toolbar. Move via a "pick destination" mode.
- **`WorkspaceLive`** (`/workspace`) — tree + preview pane, plus free navigation: **Up** button,
  clickable **breadcrumb**, and **Home**, so you can browse up to the Desktop and anywhere else.
  **"Set as workspace"** on the current folder applies **immediately** (`Application.put_env` +
  scaffold dirs; reads are call-time) and persists to the Tauri boot file — **no restart**.
- Retired the native picker: removed `workspace_pick`/`choose_parent`/`create` Tauri commands, the
  `tauri-plugin-dialog` dep, and the create/pick branches of the JS hook (`workspace_relaunch`
  remains but is now unused). Setup wizard's workspace step simplified to a confirm + a link to the
  Workspace tab.

### Footer dock reorg

- **Workspace** replaced **Documents** in the dock (Library is still reached via the library tab row).
- **Memory**, **Scheduler**, and **Security** moved out of the dock into the **Advanced** tab row
  (each page now renders `AdvancedTabs.tabs`); tab-strip labels preserved.
- Removed the **"BC"** logo from the dock's left corner.
- Dock is now: Home · Chat · Workspace · Browser · Terminal · Calendar · GWS · Advanced · Settings.

## Verification

- `mix compile --warnings-as-errors`: clean.
- New tests across the day: `vault_test`, `url_guard_test`,
  `security_hardening_test`, `browser/reader_test`, `browse_live_test`,
  `split_live_test`, `terminal_live_test`, `runtime_live_test`, plus extended
  `documents_live_test`, `automation_routes_test`, `status_live_test`.
- `mix ecto.migrate` (dev): secret-encryption backfill applied and verified.
- Terminal: `cargo build` clean with `portable-pty`; `cargo tauri dev` launches
  the desktop app with the PTY backend (verified running); `/terminal` serves;
  xterm.js bundled into `app.js` and `.xterm` styles in the built CSS.
- `mix precommit`: passed mid-day with **300 tests, 0 failures**.
- Live app verified (tabbed shell, browser tabs, split view, url-carry, join /
  separate / swap menu, terminal in split, runtime at `/runtime`, recent-emails
  panel on home) against the dev server + Tauri.
- **Setup/Settings work:** `mix compile --warnings-as-errors` clean; full suite
  **331 tests, 0 failures** (new `settings_test`, `library_artifact_workspace_test`,
  `setup_live_test`); `mix ecto.migrate` applied `app_settings`. Tauri shell compiles
  and runs with `tauri-plugin-dialog` + the workspace commands; `/`, `/setup`,
  `/settings` all serve 200 and the home CTA toggles on onboarding state; the
  `WorkspacePicker`/`choose_and_create` hooks are bundled into the served `app.js`.
- **Derived progress + identity:** full suite **343 tests, 0 failures** (new `setup_test`,
  expanded `setup_live_test` incl. a full-completion CTA-hide test). Dev server shows the
  home CTA as "Finish setup · 2 of 4 complete", the "You" identity step, and the Settings
  Profile + Setup-progress panels — `/`, `/setup`, `/settings` all 200.
- **Workspace file manager + dock reorg:** full suite **351 tests, 0 failures** (new
  `file_manager_test`, `workspace_live_test`; updated setup/routes/status tests).
  `mix compile --warnings-as-errors` clean; Rust shell builds clean after dropping
  `tauri-plugin-dialog`. Dev server: `/workspace` browses/creates/deletes/previews and navigates
  up to the Desktop with no Tauri needed; dock shows Workspace (not Documents) and no
  Memory/Scheduler/Security/BC; those three render the Advanced tab row.

## Where we left off

- Security review C1/C2/H1/H2 fixed, tested, and reflected in `Leftovers.md`;
  secrets encrypted at rest via `BusterClaw.Vault` + `BusterClaw.Encrypted`.
- `docs/UML.md` documents the current structure and functional flows.
- The UI is now a browser-style tabbed shell: bottom dock nav, top tab strip
  (name + ×), multiple independent browser tabs ("+"), and drag-to-join split
  view (Alt+drop) with swap/unjoin and url-carry. Plain drag reorders tabs.
- Library surfaces (Library/Sources/Analysis) are grouped under one tab row.
- Tabs support right-click menu (join/separate/swap), drag-reorder, Alt+drop
  join; joining consumes the source tabs; Browser/Terminal tabs are chrome-free.
- An in-app **Terminal** tab (xterm.js + Rust PTY) runs in the desktop app and
  is embeddable in split panes.
- **Runtime control** now lives at **/runtime** (a Runtime Advanced tab), off
  the home page; the home GWS panel shows **recent emails** (live Gmail).
- **Agent mode is on by default** at app launch.
- The **Industrial Claw** visual identity shipped this session: theme rebuilt,
  self-hosted Archivo/IBM Plex fonts, `ic-*` utilities, shell chrome + all page
  headings + flagship page bodies (Home/Chat/Documents/Terminal) restyled, and
  the terminal now reads live theme tokens. Non-flagship page bodies still have
  stock cards under the new headings. All uncommitted working-tree changes.
- A **cybersecurity defense layer** was researched and fully planned (5 roadmap
  docs in `daily-growth/roadmaps/`, 6 phases, order 0→1→5→2→3→4→6) — **planning
  only, nothing built**. Two verified critical findings: the MCP endpoint
  bypasses the command tier system, and the Tauri webview (`csp:null` +
  `withGlobalTauri` + `terminal_*` PTY) is an RCE-class path. Phase 0 decided:
  scoped MCP token (A+B) + pending stub.
- **BusterClawCLI data root** is decided and captured in memory; build deferred
  until the contents settle and we test the `.dmg` install.
- **First-run Setup + Settings shipped (working-tree):** new `app_settings` store +
  `Settings` context; a `workspace_root` model (`library/sources/analysis/memory`) wired
  through `Artifact`, config, and a Tauri-owned boot file; `/setup` wizard (intro →
  workspace → GWS → AI provider → done) and `/settings` hub; Settings dock entry + a
  home "Set up Buster Claw" CTA gated on onboarding state. The workspace step **creates a
  new named folder at a chosen location** (native dialog via new `workspace_*` Tauri
  commands + `tauri-plugin-dialog`). Folder create/relocate is desktop-only and applies on
  **restart**; in `mix phx.server` dev it's read-only with a note. Existing data is **not**
  auto-migrated on relocation (future "import existing library" action).
- **Superseded later this session:** the native folder picker was replaced by an **in-app,
  server-side file manager** (`FileManager` + `FileTree` + `WorkspaceLive` at `/workspace`) — a
  full IDE-style tree (browse/preview/create/rename/move/delete) with Up/breadcrumb/Home
  navigation. **"Set as workspace" now applies live (no restart)** and persists to the boot file;
  `tauri-plugin-dialog` was removed. Workspace is a top-level **dock** item (replaced Documents);
  Memory/Scheduler/Security moved into the **Advanced** tab row; the BC logo was removed.
- Open follow-ups:
  - The README advertises a `/browse <url>` chat slash command that does not
    exist — wire chat's `/browse` to the view or correct the README.
  - True multi-view tab state (kept-alive views per tab) remains deferred;
    split panes start fresh except for the carried Browse url.
  - UX polish: choice of which drag gesture is join vs reorder (currently
    Alt+drop = join); split→unsplit shortcuts; nested splits.
  - Architecture/quality refactors from the review (catalog drift guard,
    `finalize_run/3`, route changeset errors through `ErrorFormatter`, break up
    `status_live.ex`, decide on chat streaming).
  - Remaining `Leftovers.md` items: provider tool adapters (OpenAI/Gemini/Codex),
    MCP SSE/streaming + external `tools/call`, OS keychain for the vault key,
    and packaging/distribution work.
  - Verify workspace create/relocate in a **packaged** build (`cargo tauri build`):
    the `BUSTER_CLAW_WORKSPACE_ROOT` boot wiring lives only in the release branch of
    `main.rs`, so `cargo tauri dev` can't exercise the actual relocation. Also wire the
    same create-folder option into the `/settings` "Change folder" control (currently
    pick-existing only).
