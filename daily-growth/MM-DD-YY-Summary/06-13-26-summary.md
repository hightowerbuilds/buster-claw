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

## Notes

- Both objectives add migrations. They auto-apply on next `mix phx.server` boot
  (Ecto.Migrator in the supervision tree); the dev DB wasn't manually migrated to
  avoid stepping on a running dev server.
- The mail-triage seed rewrite only affects **fresh** workspaces — `Jobs.ensure`
  never overwrites an operator's existing `job-descriptions/mail-triage.md`.
- Nothing committed yet.

## Verification

-

## Notes

-
