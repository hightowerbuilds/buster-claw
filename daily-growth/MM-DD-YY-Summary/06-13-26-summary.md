# 06-13-2026 Summary

## Recent days

- **Pull-queue rewrite (06-10):** Completed and merged Phases 1–7 to `main` — the
  terminal-first pull model where a human's Claude Code session reads the fridge
  and writes back through the audited `buster-claw dispatch` CLI. (Full detail in
  `06-10-26-summary.md`.)
- **User Guide tab (06-10):** Added an in-app User Guide with
  Introduction / Setup / Daily Loop sub-tabs.
- **Terminal tab system (06-11):** Built out the multi-tab terminal — `Cmd+T` /
  `Cmd+W` shortcuts, resizable + swappable split panes, joined tabs with per-pane
  close buttons (every tab joinable), a manual tab in the dock, continuous
  terminal background across joined/split panes, and double-click tab rename.
  Trimmed the chrome along the way: dropped the redundant split-pane header
  (flush toolbar) and removed the close-shell button.

## Today

Plan: `daily-growth/roadmaps/06-13-26-on-shift-and-email-reply-roadmap.md`.
Two objectives (decisions locked with operator):

1. **"On shift until told otherwise"** — remove the shift duration concept
   entirely. Shifts end only via `shift_stop` / kill-switch (no `ends_at`, no
   12h auto-complete window).
2. **Auto-reply to trusted contacts (full auto-send)** — add RFC `Message-ID`
   capture + thread-aware Gmail send + a restricted `dispatch_reply` command, and
   point the mail-triage job at the claim → read → reply → done loop.

### Objective 1 — "On shift until told otherwise" — DONE

Removed the shift duration concept entirely. A shift now runs until `shift_stop`
or the kill-switch; there is no `ends_at` and no auto-complete window.

- **Migration** `20260613120000_remove_shift_duration` — drops `shifts.ends_at`
  and `shifts.duration_hours`.
- **`Shift` schema** — removed both fields + the duration validation; only
  `started_at`/`status`/`job_*` are required now.
- **`Orchestration`** — dropped `@default_shift_hours`, per-job `default_hours`,
  the `positive_integer/2` helper, and the `ends_at` calc in `start_shift`.
- **`Orchestrator.run_shift_tick`** — deleted the `now >= ends_at → "window
  elapsed"` branch; shift ends only via kill-switch (+ existing crash-loop brake).
  Still reclaims expired task leases each tick.
- **`Commands`** — `shift_start` dropped the `hours` arg; `shift_start` /
  `shift_status` returns now report `started_at` instead of `ends_at`/duration.
- **UI** (`OrchestrationPanel`, `OrchestrationLive`) — replaced the
  "time left"/progress-bar/"Window … ends" displays with an `elapsed` "on shift"
  readout + "On Shift Since" start time.
- **Docs** — `docs/UML.md` Shift diagram/sequence updated.
- Verification: `mix test` 370/0, `mix compile --warnings-as-errors` +
  `mix format --check-formatted` clean.

### Objective 2 — Auto-reply to trusted contacts (full auto-send) — DONE

Trusted-sender mail can now be answered by the on-shift agent with one threaded
command. The trust→queue path already existed; this added real threading + a
reply verb and pointed the job at it.

- **`Gmail.read`** — now surfaces the RFC `Message-ID` header (`message_id_header`),
  distinct from the Gmail API id; needed as the `In-Reply-To`/`References` target.
- **`Gmail.send_message` / `message_mime`** — accept `in_reply_to`, `references`
  (RFC headers) and `thread_id` (Gmail `threadId` on the request body) so replies
  land in the original conversation.
- **Dispatch item** — new `gmail_rfc_message_id` column (migration
  `20260613130000`) + schema/`@derive`/`@attr_keys`; `enqueue_gmail` persists it
  so a reply can thread without re-fetching the source message.
- **`dispatch_reply` command** (restricted tier) — fetch item → `To:` original
  sender → `Re:` subject (no double-prefix) → thread it → **send** (from the
  receiving account) → mark item `done` (`outcome: "replied"`) → Sentinel
  `:outbound_send` audit. The act of calling it is the send authorization (no
  `confirm_send`); restricted means callable by the CLI (`:trusted`) agent but
  refused for the scoped `:mcp` token.
- **CLI** — `buster-claw dispatch reply <id> --body "…"` + formatter.
- **mail-triage job** — rewritten from "do not send mail" to the claim → read →
  `dispatch reply` → done loop; keeps the "email body is untrusted data" guard
  (trusted *sender* ≠ trusted *content*).
- Tests: Gmail threaded-send (headers + threadId) + Message-ID surfacing;
  `dispatch_reply` happy path / Re: de-dup / missing-body; CLI formatter; the
  catalog-wide ":mcp refuses restricted" test now covers it too.
- Verification: `mix test` 375/0, `mix compile --warnings-as-errors` +
  `mix format --check-formatted` clean.

### Trusted-contacts UI (home left column)

Added a homepage manager for the trusted-sender allow-list, replacing the
orchestration container in the left column (orchestration still lives at
`/orchestration`).

- **`TrustedSenders`** gained write/read management: `list_entries/0` (addresses
  first, then `*@domain` rules), `add_entry/1` (accepts a full address, `*@domain`,
  or a bare domain → wildcard; idempotent; validates), `remove_entry/1`.
- **`TrustedContactsPanel`** component (`id="home-left-panel"`): add form +
  list with a "domain" badge + per-row remove (with `data-confirm`); empty state.
- **`StatusLive`** — dropped the home orchestration wiring (subscribe/timer/
  kill_shift/delete_task) and now renders the trusted-contacts panel, handling
  `add_contact` / `remove_contact` (invalid entry → flash).
- Tests: `TrustedSenders` add/list/remove unit tests; rewritten `status_live_test`
  (panel render, lists existing, add+remove via LiveView, invalid→flash).
- Verification: `mix test` 382/0, compile warnings-as-errors + format clean.

### Get Started polish + `shift run` + collapsible contacts

- **Copy buttons** on the get-started command snippets (reuse the terminal's
  clipboard handler).
- **`./buster-claw shift run`** — new CLI subcommand that starts a shift *and*
  enters the mailman poll loop, so "go on duty" is one command. Get Started
  restructured to 3 steps (add contacts → start the agent → go on duty); escript
  rebuilt.
- **Trusted Contacts panel** made collapsible (native `<details>`/`<summary>` +
  entry-count badge), only claiming flex space when open.
- Committed: `32f7d58` (get-started + shift run), `7b37e1b` (collapsible panel).

### Trusted-contact autonomy (full follow-through)

Supersedes Objective 2's "email body is untrusted data" guard — the operator
chose full autonomy for trusted senders.

- Flipped the **mail-triage job prompt** + **INTRODUCTION.md**: a trusted-sender
  email is now an **authorized instruction** to act on; the agent acts and replies
  without asking permission.
- **`Jobs.ensure`** seeds `.claude/settings.json` (`bypassPermissions`) into every
  workspace so the on-shift Claude Code agent doesn't stall on tool prompts.
- **Lookout job description** rewritten so "poll the GWS pipeline every 3 minutes"
  is the loud primary duty.

### Workspace folder delete (webview fix)

- `FileTree` delete converted from the native `data-confirm` dialog (silently
  no-ops in the Tauri webview) to an **inline confirm step**.

### Whole-app performance & quality pass — `f9ae1ae`

- 5-agent parallel review (DB / filesystem / external IO / web / command surface),
  then implemented:
  - **Hot-path:** command catalog built once + cached (O(1) lookups); dispatch
    fridge not rebuilt on heartbeats; calendar reads date-scoped in SQL;
    OrchestrationLive 30s refresh split.
  - **Growth/IO:** trusted-sender policy cached; poll dedupe via `content_hash` +
    SQL window; `save_raw_document` stops re-reading its own write; new
    `agent_runs` indexes; Gmail search parallelized + label-only history skipped;
    GitHub's 6 calls concurrent; Security/Memory feeds → LiveView streams;
    Sentinel audit offloaded off the command path in prod.
  - **3 correctness bugs fixed:** `dispatch_reply` post-send finish crash;
    `integration_document?/1` nil-tags crash; `relative_to_root/1` absolute-path bug.
- Verification: `mix test` 401/0, warnings-as-errors + format clean.

### Multi-agent terminal roadmap — `49d9fb6`

- Plan for terminal engines beyond Claude Code (Codex, Gemini, opencode, …): an
  `AgentProfile` abstraction, per-engine autonomy + context-file seeding,
  side-by-side selection. `daily-growth/roadmaps/06-13-26-multi-agent-terminal-roadmap.md`.

### Financial Advisor — Phase 1 (read surface + UI) — `6c4680a`, `ee94484`, `50816bb`

Turned the `projects/financial-advisor/` research briefs into a phased build
(plan: `projects/financial-advisor/build-roadmap.md`, in the DataZone).

- **`finance_filings` + `finance_fundamentals`** via SEC EDGAR (no key): cached
  ticker→CIK, recent filings, curated XBRL fundamentals.
- **`finance_quote` + `finance_news`** via Finnhub (key-gated; degrades to
  "not configured" without a key). All four are safe-tier reads.
- **`/finance` dashboard** (`FinanceLive`): ticker lookup → Quote / Fundamentals /
  Filings / News cards, each stamped **source + as-of**, labeled "not financial
  advice," missing facts shown "unavailable" (never fabricated). Linked from the
  Get Started container.
- **Secrets wiring:** gitignored `.env` (sourced by `scripts/dev.sh`) holds
  `FINNHUB_API_KEY` + `FINANCE_USER_AGENT`; `runtime.exs` reads both.
- **EDGAR 403 fix:** SEC Fair Access rejects a User-Agent without a contact email —
  wired `FINANCE_USER_AGENT`.
- Verified live: AAPL quote $291.13, 10 news articles, 10 filings.

### `dev.sh` — stale-server error handling

- Root-caused a recurring "finance not configured / EDGAR 403" symptom to a
  **six-day-old dev server** holding `:4000`: Phoenix hot-reloads *code* but
  `config/runtime.exs` only reads env at *boot*, so the process never picked up the
  `.env` vars added today, and `dev.sh` kept *reusing* it.
- `scripts/dev.sh` now detects this — when a server is already running it checks the
  process env for every variable `.env` defines; if any are missing it reports which,
  restarts the server, and boots fresh so `runtime.exs` re-runs. Otherwise it reuses
  as before. (Quotes in `.env` were a red herring — bash `source` strips them.)

### Financial Informant — ticker/company-name search + rename

- **Renamed** "Financial Advisor" → **Financial Informant** (page title, header, the
  `/finance` tab label so the tab shows a friendly name, and the home Get Started link).
- **Search by ticker *or* company name with as-you-type suggestions:** `Edgar.search/2`
  ranks matches over the cached SEC ticker list (exact ticker → ticker prefix → name
  prefix → substring); `Edgar.resolve/2` maps free text → ticker. The LiveView shows a
  suggestion dropdown (`phx-change`, 200ms debounce); a clicked suggestion or a submit
  resolves to a ticker, with a "no company found" state. Local + no-key (reuses the
  `company_tickers.json` map already cached in `:persistent_term`).
- Tests: search ranking + name→ticker resolve; the dashboard render asserts the rename
  + suggest wiring.

### Financial Informant — multiple in-page stock tabs

- The page now holds **several open stocks as in-page tabs** (not browser tabs, not
  app-shell tabs). A lookup opens the stock in its own tab — or switches to it if
  already open; the in-page tab strip shows each open stock with an active highlight
  and a close (×), and switching tabs swaps the Quote / Fundamentals / Filings / News
  view. Per-tab results are fetched once on open and held in socket state. Empty state
  when nothing's open; a "no company found" notice on an unresolved search.

### Removed the Orchestration tab

- `/orchestration` was vestigial: its task wizard created tasks nothing ran (no
  dispatcher, no run-now; `list_due_tasks`/`claim_task` had no callers) — residue of
  the pre-pull-queue design. Removed the route, the dock nav item, the `@views`
  (status) and `@panes` (split) entries + the split test reference, and deleted
  `OrchestrationLive` + the now-dead `OrchestrationPanel` + its test.
- **Kept intact:** the `Orchestration` domain and the `Orchestrator` janitor
  (kill-switch + lease reclaim during a shift) — shifts still power `shift run` and the
  dispatch queue. The pull queue and `/scheduler` are untouched.
- Full suite green (403).

### Pruned the dead orchestrator task/run engine

- Removed the headless-dispatch scheduling machinery the deleted page drove (no
  production callers remained): the `Task` (`orchestrator_tasks`) and `AgentRun`
  (`agent_runs`) schemas/tables, their CRUD/lease/scheduling/run functions in
  `Orchestration`, and `snapshot/0` / `vitals/0`. Migration `20260613150000` drops both
  tables, the FK index, and the vestigial `dispatch_items.orchestrator_task_id` column
  (never set by any production path).
- Simplified the `Orchestrator` janitor to a pure **kill-switch watcher** (dropped the
  lease-reclaim branch). Removed the Dispatch→Task `belongs_to`. **Kept** Shifts /
  ShiftAssignments and the Dispatch shift/role-session linkage intact.
- Tests trimmed to match (dropped the task/run + vitals tests). Full suite green (393).

### Home — collapsible Get Started container

- Converted the home **Get Started** panel to the same native `<details>`/`<summary>`
  pattern as Trusted Contacts (open by default, rotating chevron, `open:` flex/min-h
  variants so collapsing it lets the Trusted Contacts panel grow). Body stays in the
  DOM, so existing render assertions hold. Status tests green.

### Browser — workspace HTML/MD viewer (Part 1 of webview rework)

- New `GET /ws/file?path=` (`WorkspaceFileController`): serves a workspace file for
  the in-app browser — Markdown → HTML, `.html`/`.htm` as-is, other text in a `<pre>`.
  Path-guarded to the workspace via `FileManager.read_file/2` (traversal/size/binary
  rejected); raw HTML response (no LiveView shell). Tests: md render, raw html,
  outside-workspace 403, missing-path 400.
- **Next (Part 2):** an embedded Tauri webview (operator chose B) for live HTTPS +
  wiring the browser UI to this route — native (`unstable` multi-webview + JS↔Rust
  position sync), needs in-app iteration.

### Browser — embedded-webview Rust foundation (Part 2a)

- New `desktop/tauri/src/browser.rs`: commands `browser_open` / `browser_set_bounds` /
  `browser_navigate` / `browser_back` / `browser_forward` / `browser_reload` /
  `browser_close`. Uses Tauri's **`unstable` multi-webview** API (`window.add_child`,
  `get_webview`, `set_position`/`set_size`, `navigate`, `eval`, `close`) to host a
  child webview ("embedded-browser") over a placeholder in `/browse` — a real webview
  ignores `X-Frame-Options`, so it loads any HTTPS. Not in any capability → the pages
  it loads have no Tauri access (external content stays sandboxed).
- Wiring: `mod browser` + commands registered in `main.rs`; `tauri` gains the
  `unstable` feature; 7 `allow-browser-*` permission files + capability entries.
  Validated with `cargo check` (clean).
- **Next (Part 2b):** the `EmbeddedBrowser` JS hook (open + position-sync via
  ResizeObserver, drive nav commands) and the BrowseLive shell rework + non-Tauri
  fallback. Runtime-only-testable in the Tauri app → build-and-iterate.

### Browser — embedded-webview wiring (Part 2b)

- **`EmbeddedBrowser` JS hook** (`app.js`): in the desktop app it opens the native
  child webview over the surface element and keeps it glued via a `ResizeObserver` +
  window resize/scroll (rAF-debounced `browser_set_bounds`); the toolbar
  (back/forward/reload + address form) drives the `browser_*` commands client-side
  (no server round-trip); `destroyed()` closes the webview. Outside the desktop app
  it reveals a fallback notice. The address bar resolves a URL (`https://…`, scheme
  optional) or an absolute workspace path (`/…` → `/ws/file`).
- **`BrowseLive` rewritten** from the server-side reader into the shell (toolbar +
  surface + fallback); deep-link `?url=` / split-pane `session["url"]` seed the
  address. Old reader handlers/state removed.
- Tests rewritten for the shell; `browse_live_test` + `split_live_test` updated
  (reader assertions → shell assertions). Full suite green (395); `cargo check` +
  `mix assets.build` clean.
- **Not yet runtime-verified:** native positioning / live loads need the Tauri app
  (`./scripts/dev.sh`) — expect to iterate on overlay alignment and lifecycle.

### Browser — two native webviews; chrome is native too (Part 2c, verified in-app)

In-app testing showed the single content webview (with an HTML toolbar) covered the
toolbar (native webviews always paint on top) and couldn't be aligned reliably. Per
operator direction, moved the **entire browser chrome into the native layer**:

- **Two stacked child webviews** (`browser.rs`): `browser-chrome` (thin top strip,
  our toolbar) + `browser-content` (the site), positioned together by the hook. The
  toolbar is now a webview, so it can never be covered. `browser_open(chrome_url,
  content_url, …)`; `browser_set_bounds` moves both; nav commands act on the content
  webview; `browser_hide`/`browser_close` affect both.
- **Native chrome page** — `BrowserChromeController` at `/browser/chrome`: address bar
  + ◀▶⟳, served from the Phoenix origin so it can call the `browser_*` commands;
  granted them via a new **`browser-chrome` capability** (`webviews: ["browser-chrome"]`).
  The content webview is in no capability (sandboxed).
- **`BrowseLive`** reduced to a bare surface + fallback (HTML toolbar removed). The
  **hook** positions both webviews (with an `outer−inner` chrome offset), passes both
  URLs, and **hides** on tab switch (persist) — while **tab close** (`closeTab` in the
  TabStrip hook) calls `browser_close` so the webviews are destroyed, not left lingering.
- Verified in-app: aligned, navigable, persists across tab switches, closes with the
  tab. `cargo check` + full suite green (397).

### Browser — webview security (in progress)

- **Sandboxed ✅:** the content webview is in no capability → loaded pages get zero
  Tauri command access; the chrome webview holds only the 4 nav commands.
- **Navigation guard ✅** (`browser.rs`): the content webview's `on_navigation` allows
  only `http`/`https` (+ `about:blank`) — blocks `file://`, `tauri://`, `javascript:`,
  `data:`, so a page can't read local files or jump into app/IPC schemes.
- **Popup/new-window guard ✅** (`browser.rs` `initialization_script`): overrides
  `window.open` and rewrites `target=_blank` links to navigate **in-place**, so pages
  can't spawn uncontrolled OS windows.
- **Deferred (operator opted out for now):** device-permission denial (geo/cam/mic),
  download policy, and restricting the content webview's loopback reach to `/ws/file`.

### Browser — homepage with recent URLs

- The content webview now defaults to a Phoenix-served **`/browser/home`** (dark-themed
  to match) instead of `about:blank` — it server-renders a **recent-URL list** from
  `BusterClaw.BrowserHistory` (per-workspace, file-backed `.browser-history.json`,
  newest-first, deduped, capped 50). Entries link straight into the content webview.
- The native chrome toolbar gained a **Home** button and **records each navigation**
  via `POST /browser/history` — so external URLs *and* workspace HTML/MD files opened
  from the address bar (`/path` → `/ws/file`) show up in Recent.
- All Phoenix/JS (no Rust): `BrowserHistory`, `BrowserHomeController`,
  `BrowserHistoryController`, chrome toolbar + hook tweaks. Tests for the store, the
  homepage render, and recording. Full suite green (403).

### Browser — workspace file browser from the address bar

- Typing an address starting with **`/`** browses the workspace: the chrome toolbar
  (debounced) navigates the content webview to **`/browser/workspace?q=…`**
  (`BrowserWorkspaceController`) — a dark-themed listing of folders/files under that
  workspace-relative path, filtered by the trailing name. Folders drill in (with a
  `..` parent); files open via `/ws/file` and are recorded to history (`sendBeacon`).
  (Dropdown-in-chrome was avoided — the 46px chrome webview would clip it.)
- **`/ws/file` now accepts workspace-relative paths** (leading `/` = workspace root),
  resolved safely: absolute-in-workspace kept as-is, else joined under the root;
  traversal still blocked by `within?` (→ 403). `/etc/hosts` → `<ws>/etc/hosts` (404),
  never the real file.
- All Phoenix/JS (no Rust). Tests: workspace listing + prefix filter + parent link +
  relative-path resolution. Full suite green (407).

### Browser — address bar tracks the current page

- The content webview's `on_navigation` (Rust) now pushes each destination URL to the
  chrome bar via `chrome.eval(window.__setAddress(...))`, so clicking folders/files or
  in-page links updates the address. `__setAddress` shows a friendly form (workspace
  path for `/ws/file` & `/browser/workspace`, empty for `/browser/home`, the URL for
  external sites) and **skips while the input is focused** so it never clobbers typing.
  `cargo check` clean. (Rust change → needs a Tauri rebuild.)

### First-run onboarding — hyper-minimal 4-step flow

- Rebuilt `/setup` (`SetupLive`) into a welcome explainer + **4 progress dots**
  (Workspace → Tools → Google → Go live), each filled from real state via
  `Setup.status/0`. Dropped the old intro/identity/done steps; reframed as a
  **personal assistant your trusted contacts reach by email while a shift is
  open** (no Slack/Discord framing, no emojis).
- **Auto-launch on first run:** new `RequireOnboarding` on_mount hook + a router
  `live_session` redirect main routes to `/setup` until onboarding is complete
  (lets `SetupLive`/`TerminalLive` through; "Skip for now" exits). Behind an
  `:onboarding_gate` flag — off in the test env so the LiveView suite isn't
  forced through setup; the first-run tests flip it on.
- **`Setup` context** → 4 derived steps: `tools_complete?` (launcher on disk +
  `claude`/`codex` detected, incl. `~/.local/bin/claude`), `live_complete?` +
  `mark_went_live`.
- **Tools step:** `buster-claw` launcher auto-placed; Claude Code detected with an
  **Install Claude Code** button that opens a terminal pre-typed with
  `curl -fsSL https://claude.ai/install.sh | bash`, plus Re-check.
- **Terminal pre-type:** `TerminalWorkspace.request_open*` + a new
  `startup_submit: false` path threaded to the xterm JS hook → the go-live step
  drops the user into a terminal with `./buster-claw mailman poll` typed but not
  run (press enter). Added an `agent-setup` install role; generalized the startup
  profile whitelist to the catalog (still no arbitrary shell).
- **Google step:** auto-trusts the connected address (`TrustedSenders.add_entry`)
  so an email to yourself queues a Dispatch item the moment you go live. The OAuth
  client_id/secret paste stays the one accepted bit of friction (Google owns it).
- Plan/roadmap: `daily-growth/roadmaps/06-13-26-first-run-onboarding-roadmap.md`
  (incl. the end-to-end smoke test). Built via 4 parallel agents + integration.
- Tests: `setup_test` (4-step status), `setup_live_test` (flow + first-run gate),
  `terminal_commands_test` (install role). `mix precommit` green (400).

### Docs — pull-queue accuracy pass

- `README.md` + `INTRODUCTION.md` (`introduction.ex`): removed stale `POST /mcp`
  MCP-server + headless-agent-dispatch references (both deleted in the pull-queue
  cut) and reframed the agent surface as CLI/HTTP + the Dispatch pull-queue.
  `docs/LOCAL_TRUST.md` still carries the same MCP staleness (flagged, not yet
  fixed).

## Notes

- Both objectives add migrations. They auto-apply on next `mix phx.server` boot
  (Ecto.Migrator in the supervision tree); the dev DB wasn't manually migrated to
  avoid stepping on a running dev server.
- The mail-triage seed rewrite only affects **fresh** workspaces — `Jobs.ensure`
  never overwrites an operator's existing `job-descriptions/mail-triage.md`.
- Earlier objectives (1, 2, trusted-contacts UI) committed in prior commits; the
  session work above is committed/pushed through `50816bb`. Open dev items: restart
  the dev server to pick up `.env`; add EDGAR backoff/retry; build the `finance`
  integration adapter + `watchlist_research` cron (needs operator watchlist symbols).
