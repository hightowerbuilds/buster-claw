# 06-14-2026 Summary

A navigation + surface-area cleanup day: bundled HTML pages in the DataZone, a
Featured Pages homepage container, the Financial Informant rewritten as a live
HTML page, the footer/settings nav reworked, and the Advanced tab retired with a
full follow-through removal of five unused subsystems.

## Bundled HTML pages in the DataZone (`pages/`)

- **Manual → HTML.** New `BusterClaw.Manual` renders the in-app User Guide
  (`UserGuide` sections) into one self-contained, dark-themed `MANUAL.html`.
- **`pages/` folder.** New `BusterClaw.Pages` installer seeds the bundled pages
  into `<workspace>/pages/` (skip-if-identical) and cleans up the legacy
  root-level `MANUAL.html`. Wired into boot + workspace-switch (replacing the old
  `Manual.ensure`). `Manual` is now pure content generation.
- Openable in the in-app browser via the address bar (`/pages/MANUAL.html`).

## Bookmarks (in-app browser)

- **`BusterClaw.Bookmarks`** — file-backed per workspace
  (`.browser-bookmarks.json`), newest-first, deduped; `add/2`, `list/0`,
  `remove/1`.
- **Browser home** now renders a **Bookmarks** section above **Recent**, each
  with an inline remove form.
- **`+ Bookmark` button** added to the native chrome toolbar (tracks the current
  page, POSTs to a new `/browser/bookmarks`); a remove route redirects home.
  Controller: `BrowserBookmarkController`.

## Homepage

- **Featured Pages** container added to the left column (between Get Started and
  Trusted Contacts), linking to the Manual and the Financial Informant pages
  (opened in the in-app browser via `/browse?url=/pages/…`).
- **Calendar panel** given `self-start` so it sizes to its own content instead of
  stretching the full grid-row height.
- Removed the "Open the Financial Informant" link from Get Started (moved to
  Featured Pages).

## Financial Informant — rewritten as a live HTML page

- Replaced the `FinanceLive` LiveView with **`pages/financial-informant.html`**
  (`BusterClaw.FinancialInformant`): self-contained HTML+CSS+JS that replicates
  the dashboard — typeahead search, per-stock in-page tabs, and
  Quote / Fundamentals / Filings / News cards with provenance + "not advice."
- Stays live via new **token-free, loopback-only** JSON endpoints
  (`GET /finance/api/search`, `/finance/api/lookup`) backed by the unchanged
  `BusterClaw.Finance` (EDGAR + Finnhub) — necessary because the browser's
  sandboxed content webview can't carry the API token. Controller:
  `FinanceApiController`.
- Removed the `/finance` route, `FinanceLive`, its test, and the tab label.

## Footer / Settings navigation rework

- **Removed the Manual button** from the footer dock (the page stays reachable at
  `/manual`).
- **Settings dock wordmark.** Pointed the Settings dock button at
  `settings-icon.png` (operator-provided, brand folder). Dock fallback for
  image-less items is now **text-only** (no hero icon).
- **Moved GWS, Security, and Integrations** subtabs from Advanced → Settings;
  `SettingsTabs` gained a Settings wordmark header so all settings pages are
  consistent. Settings is now: Configuration · Appearance · GWS · Integrations ·
  Security.

## Retired the Advanced tab + five unused subsystems

Checked actual usage (live DB row inspection): Delivery, Hooks, Webhooks,
Scheduler, and DB-backed Memory had **no real use** — only smoke-test artifacts
(including a scheduler job erroring every minute). Integrations was the only
genuinely-used feature (a real Umami integration), so it was kept and relocated.

- **Deleted modules:** `Delivery`, `Hooks`, `Webhooks`, `Scheduler` (+ cron,
  runner), `Memory` (+ schema), `Automation` (+ 4 schemas), `Workflow` (+ 3
  schemas) — all generic wrappers existing only for these features.
- **Deleted web:** the 5 LiveViews, `WebhookController`, `AdvancedTabs`, the
  Advanced dock button, and routes `/delivery`, `/advanced`, `/hooks`,
  `/webhooks`, `/scheduler`, `/memory`, `POST /hooks/:name`.
- **Command surface:** removed `memory_*`, `webhook_*`, `hook_*`,
  `delivery_destination_*`, `scheduler_job_*` (catalog, CRUD loop, functions,
  aliases, unused helpers).
- **Supervision:** dropped the `Scheduler.Runner` child + config keys.
- **DB:** migration `20260614120000_drop_retired_automation_tables` drops the 8
  orphaned tables (keeps `integrations` / `integration_runs`).
- **Status / split / settings:** trimmed `runtime/status.ex`, `split_live`
  panes, and the `settings_live` config-checklist.
- **Consequence:** Integrations is now manual- or webhook-poll-only (the
  Scheduler was its only auto-poll driver; no such job was configured).

## Docs

- Rewrote `docs/UML.md` (it predated the pull-queue cut): all diagrams now match
  reality — no MCP frontend, no headless agents, the Dispatch pull-queue
  sequence, the current supervision tree and schema set, corrected routing/auth.
- Updated `docs/ARCHITECTURE.md`, `docs/COMMAND_SURFACE.md`, `docs/LOCAL_TRUST.md`
  and `README.md` to drop the removed features and add Finance / Dispatch.
- Removed the orphaned `advanced-icon.png`.

## Tests repointed (not just deleted)

- `commands_test`, `commands_audit_test`, `api_controller_test` repointed off the
  deleted `memory_*` onto the surviving `event_*` resource.
- Dropped the `hook_test` security check; split `library_workflow_test` into a
  clean `library_document_test`; deleted the 10 feature-specific test files.

## Verification

- `mix test` — 388 tests, 0 failures.
- `mix compile --warnings-as-errors` + `mix format --check-formatted` clean.
- Net change: 68 files, ~412 insertions / ~4,099 deletions.

## Notes

- The `pages/` install + the migration apply on the next dev-server boot
  (Ecto.Migrator in the supervision tree); the migration also removes the
  smoke-test rows and stops the every-minute erroring scheduler job.
- Financial Informant's in-app behavior (native webview + live fetches) is
  runtime-only-testable in the Tauri app — verify with `./scripts/dev.sh`.

---

## Later 06-14 — `dev.sh` auto-migrate

- In dev the `Ecto.Migrator` child runs with `skip: true` (migrations only
  auto-run in releases), so the new drop migration halted startup on Phoenix's
  pending-migration guard. `scripts/dev.sh` now runs `mix ecto.migrate` in
  `start_phoenix()` before serving (fresh start + stale-restart; skipped when
  reusing a healthy server); aborts loudly on failure. (`8c849cd`)

## Later 06-14 — BEAM/concurrency assessment

Reviewed how the app uses Elixir concurrency: 7 supervised GenServers
(Orchestrator janitor, DispatchProjector, TerminalWorkspace, Sentinel.Pending,
Uptime, Browser.Sidecar, Telemetry), `Task.async_stream` in the genuinely
parallel IO paths (Gmail message fan-out + search, GitHub multi-endpoint),
`Task.start` to offload Sentinel audit off the command path, PubSub fan-out to 15
LiveViews, and SQLite (WAL, pool 5 — single-writer, not a bottleneck for one
user). **Verdict: keep BEAM** — its payoff here is OTP supervision (durable,
crash-isolated background work) + LiveView (collapses the frontend/backend
boundary, no API surface), not raw throughput. Concurrency is used
appropriately, not gratuitously.

## Later 06-14 — Browser tab system

The in-app browser now holds **multiple addresses open at once as native tabs**.

- **`desktop/tauri/src/browser.rs`** — reworked from two singleton webviews to
  one chrome + **N content webviews** (`browser-content-<id>`). New commands
  `browser_new_tab` / `browser_switch_tab` / `browser_close_tab`; a managed
  `BrowserState` tracks the active tab. Only the active content webview is shown
  (others hidden but alive → instant switch, preserved state). Each tab keeps the
  http(s) nav guard + popup guard and reports navigation back per-tab via
  `__onContentNavigated(id, url)`.
- **`browser_chrome_controller.ex`** — chrome grew to an 80px strip: a **tab bar**
  (titles + per-tab `×`, plus a `+` new-tab button) over the toolbar. Chrome JS
  owns the tab strip + lifecycle; nav/back/forward/reload now pass the chrome's
  active tab id to Rust (with a fallback) so navigation can't no-op on a state
  mismatch. All `browser_*` calls go through an `inv()` helper that logs failures
  to the console.
- **`main.rs`** registers the 3 new commands + `BrowserState`; 3 permission files
  + the `browser-chrome` capability grant them (Tauri `gen/schemas` regenerated).
- Verified in-app: open/Go, `/` workspace browse, new tab, switch, close all work.

### Known issue (open)

- **Blank-screen-on-restart:** on a cold app boot the main webview sometimes loads
  the dead render but LiveSocket doesn't connect (black screen); reload doesn't
  reliably clear it (native browser webviews persist across a main-webview
  reload). Planned fix: guard the native webviews so a restored/inactive `/browse`
  tab can't paint over the app, plus a one-shot LiveSocket reconnect in `app.js`.

---

## Later 06-14 — Distribution roadmap (review critique → two-channel plan)

- Read an outside "senior assessment" review and **fact-checked it** rather than
  accepting it: its "claw agent genre / 100+ reviews" landscape is fabricated, and
  two load-bearing claims were wrong against the code — "70+ commands" (actually
  33 in `build_catalog`) and "no LiveView interaction testing" (12 live test files
  use `render_click`/`render_submit`/`render_hook`). Kept its grounded
  architecture observations, discarded the grade/ranking.
- Built **`daily-growth/roadmaps/06-14-26-distribution-roadmap.md`**, then reworked
  it around **two delivery channels for the same `.dmg`**: **A** — developers
  `git clone` + build locally (unsigned OK); **B** — end users download a
  signed/notarized `.dmg` from a website.
- **Locked decisions:** public audience; macOS **Keychain** key storage; bundled
  Google OAuth with **deep GWS scopes** (CASA assessment accepted, not minimized);
  **reveal** recovery key; **manual re-download** (no auto-updater in v1);
  **GitHub Releases + simple page** hosting. Bundle id / domain still parked.

## Later 06-14 — Phase 0: single-source version + dev-token boot guard (`7ad5d55`)

- Root **`VERSION`** is the single source: `mix.exs` reads it; `scripts/sync_version.sh`
  propagates it into `tauri.conf.json` + `Cargo.toml` (wired into `build_desktop.sh`).
- **`BusterClaw.Application.verify_release_token_safety!/0`** refuses to boot a
  release (`RELEASE_NAME` set) that carries a dev/test API-token sentinel — closes
  the "built with `MIX_ENV=dev`" leak. `build_desktop.sh` also `export MIX_ENV=prod`.

## Later 06-14 — Phase 1: Keychain-backed secrets + recovery (`d5bfdb9`)

- The Tauri shell now sources `SECRET_KEY_BASE` + the loopback API tokens from the
  **macOS Keychain** (`keyring` crate) instead of plaintext files in the data dir;
  `ensure_secret` migrates legacy plaintext files into the Keychain and adopts a
  user-dropped `RESTORE_SECRET_KEY` recovery file. Shell injects
  `BUSTER_CLAW_API_TOKEN`/`BUSTER_CLAW_MCP_API_TOKEN`; prod `runtime.exs` adopts them.
- **`BusterClaw.Recovery`** + a Settings **"Recovery key"** reveal panel (CSP-safe).
  Tests: `recovery_test.exs`, `settings_live_test.exs`.

## Later 06-14 — Channel A: reproducible clone-and-build (`cb3231d`, `47d6532`)

- **Fixed the clean-clone blocker:** the build never installed JS deps, so esbuild
  couldn't resolve `@xterm/*` and `assets.deploy` would die on a fresh clone. Added
  `npm ci` (from the tracked lockfile) + a **toolchain preflight** to
  `build_desktop.sh`, pinned `.tool-versions` (erlang 28.4.2 / elixir 1.19.5-otp-28
  / nodejs 26.0.0), wrote **`BUILD.md`**, and corrected the now-stale
  `docs/DESKTOP_PACKAGING.md` (Keychain, not a `secret_key_base` file).
- **Headless-safe DMG:** `build_desktop.sh` auto-sets `CI=true` when run without a
  TTY, so the DMG window-styling step (Finder/AppleScript, GUI-only) is skipped
  instead of failing in agent/CI builds. Interactive runs still get the styled DMG.
- **Verified end-to-end:** `build_desktop.sh` → `Buster Claw_0.1.0_x64.dmg` (26 MB),
  mounted and confirmed it carries current code (`Recovery.beam`, "Recovery key"
  panel, `RESTORE_SECRET_KEY`).

## Later 06-14 — Environment: iCloud Drive was corrupting builds (repo relocated)

- **Root cause of repeated "old/stale build" symptoms:** the repo lived under
  `~/Desktop`, which is **iCloud-synced**. iCloud was evicting the multi-GB build
  dirs (`desktop/tauri/target` = 6.4 GB), so a freshly built `.app`/`.dmg` had its
  `Contents/` offloaded to placeholders — the app that opened was stale/empty
  (looked "3000 commits behind", though the repo has ~116 commits). Tell-tale: a
  binary `file` sees one moment and `ls` reports gone the next.
- **Fix:** `rsync`'d the repo to **`~/Developer/buster-claw`** (local), excluding
  regenerable heavy dirs, preserving `.git` (+ GitHub remote) and `.env`. Builds and
  dev should run there now. **Lesson: never build a heavy Tauri/Elixir/Rust project
  inside iCloud Desktop/Documents.**

## Later 06-14 — "Old UI from /Applications" = shared webview cache (resolves the blank-screen issue above)

- **Symptom:** identical `.dmg` bits showed the **current** UI when run from the
  read-only DMG but an **old** UI when copied to `/Applications` and launched.
  Confirmed the `/Applications` binary was byte-identical to the verified build
  (same SHA-256), so it was never stale bits.
- **Root cause:** every build — dev, old, new — shares the bundle id
  `com.hightowerbuilds.busterclaw`, so they share **one** WebKit cache
  (`~/Library/WebKit/<id>`, `~/Library/Caches/<id>`). A **May-26** cache was serving
  a stale front-end; the read-only/translocated DMG launch happened to bypass it.
- **Fix:** quit instances, clear those two cache dirs (app data in
  `~/Library/Application Support/BusterClaw/` left untouched), relaunch — current UI.
  Documented in `BUILD.md` troubleshooting.
- **This is the same mechanism as the open "Blank-screen-on-restart" known issue
  above** — a stale shared webview cache, not a code bug. Permanent cures are on the
  distribution roadmap: a **locked/unique bundle id** (clean cache namespace) and
  **code signing** (stable app identity).

## Verification (this session)

- Rust: `cargo check` + full `cargo tauri build` clean (compiles the Keychain
  stack). Elixir: new tests pass; full suite green aside from a known flaky
  `settings_test` "Database busy" (SQLite write contention, passes in isolation).
- Full `build_desktop.sh` → signed-nothing-yet `.dmg`, mounted-and-verified current,
  copied to `~/Desktop` with a matching SHA-256, installed to `/Applications`,
  launches the current UI after the cache clear.

## Notes / open

- **Repo is now canonical at `~/Developer/buster-claw`** (HEAD `47d6532`). The old
  `~/Desktop/websites/buster-claw` iCloud copy is stale and should be retired; dev
  processes are still running from it (PIDs from this session) and should be moved.
- **Not pushed** — per plan, push happens at the end of the whole distribution effort.
- Remaining roadmap: F2 (bundled Google OAuth + PKCE; start Google verification
  early), then Channel B (sign/notarize → publish to GitHub Releases → download page).

## Later 06-14 — Settings page cleanup (dev work, in `~/Developer`)

Switched back to feature work and tidied the Settings surface.

- **Removed the redundant "Configure" cards** (GWS / Integrations / Security links)
  at the bottom of `SettingsLive` — those surfaces are already the Settings
  sub-tabs, so the cards were duplicate navigation. Also dropped the now-orphaned
  `@config_links`, its assign, the `config_links_with_status/0` + `config_done?/1`
  helpers, and the unused `Google` / `Integrations` aliases.
- **Reordered the settings sub-tabs** to **Appearance · GWS · Integrations ·
  Configuration · Security** (Configuration is now 4th), and **made Appearance the
  default**: the Settings dock button now opens `/appearance` instead of
  `/settings`. Added a `/settings → "Settings"` tab-strip label so the
  Configuration sub-page's top tab still reads "Settings."
- **Killed the leftover "Advanced" top tab.** The Advanced tab/routes/`AdvancedTabs`
  were removed from Elixir earlier on 06-14, but the **TabStrip JS** (`assets/js/app.js`)
  still had an `/advanced` tab-group collapsing `/integrations`, `/gws`, `/security`
  (plus the deleted `/hooks`, `/mcp`, `/scheduler`, …) into one "Advanced" top tab —
  so opening Integrations spawned an "Advanced" tab. Removed that group and folded
  the settings routes into the existing `/settings` group, so the whole Settings
  family now collapses into a single **"Settings"** top tab.
- **Verified:** `mix compile --warnings-as-errors` clean, `settings_live_test` 2/2,
  `mix esbuild buster_claw` bundles clean. (Stale "Advanced" top tabs persisted in
  `localStorage` clear by closing the tab once.)
