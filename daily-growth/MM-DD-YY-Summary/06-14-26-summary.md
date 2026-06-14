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
