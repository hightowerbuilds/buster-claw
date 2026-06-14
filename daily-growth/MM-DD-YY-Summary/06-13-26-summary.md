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
