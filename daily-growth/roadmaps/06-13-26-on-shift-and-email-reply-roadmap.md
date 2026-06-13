# 06-13-26 Roadmap — Indefinite shift + auto-reply to trusted contacts

Two objectives for the day. Decisions locked with the operator:

- **Email replies:** full auto-send to trusted contacts (no human gate; still
  Sentinel-audited).
- **Shift model:** remove the duration concept entirely. A shift runs until
  `shift_stop` or the kill-switch — no `ends_at`, no auto-complete window.

Sequence: Objective 1 first (contained), then Objective 2.

---

## Objective 1 — "On shift until told otherwise" (remove duration)

Today `Orchestration.start_shift` precomputes `ends_at` from `duration_hours`
(default 12), and `Orchestrator.run_shift_tick` auto-completes the shift when
`now >= ends_at`. Rip the duration out.

1. **Migration** — make `shifts.ends_at` nullable. Leave `duration_hours` column
   in place (harmless) or drop it; stop reading/writing it either way.
2. **`lib/buster_claw/orchestration/shift.ex`** — remove `ends_at` and
   `duration_hours` from `validate_required`; drop the `validate_number` on
   `duration_hours`.
3. **`lib/buster_claw/orchestration.ex`** — `start_shift` no longer computes
   `ends`; insert with `ends_at: nil`. Remove `@default_shift_hours` and per-job
   `default_hours`; simplify `shift_attrs` (drop duration handling).
4. **`lib/buster_claw/orchestrator.ex`** — delete the
   `DateTime.compare(now, shift.ends_at) != :lt -> complete_shift("window elapsed")`
   branch in `run_shift_tick`. Keep the kill-switch branch and `reclaim_expired`
   (per-item lease expiry — unrelated to shift length).
5. **`lib/buster_claw/commands.ex`** — `shift_start`: drop the `"hours"` arg;
   remove `ends_at`/`duration_hours` from the success map.
6. **UI sweep** — `OrchestrationPanel`, `StatusLive`, `Orchestration.Reporter`
   (morning report) for any "ends at"/countdown display → replace with
   "on shift since …".
7. **Tests** — `test/buster_claw/orchestration_test.exs` (the 12h-window assertion),
   command tests, any reporter test referencing the end time.

## Objective 2 — Auto-respond to trusted-contact emails (full auto-send)

The trust → queue path already works: `GmailSync` runs `TrustedSenders.match`
and `Dispatch.enqueue_gmail` for trusted senders, the fridge shows the agent its
plate, and the CLI claim/done loop exists. What's missing is real threading and a
reply command.

1. **Surface RFC `Message-ID`** — `lib/buster_claw/google/gmail.ex` `read/3`
   already builds a full `headers_map`; expose `message_id_header` (the RFC
   `Message-ID`, distinct from the Gmail API id). Persist it on the dispatch item
   (`Dispatch.enqueue_gmail` + `Dispatch.Item` field + migration).
2. **Thread-aware send** — extend `Gmail.send_message/3` and `message_mime/1` to
   accept `in_reply_to` + `references` (RFC headers) and `thread_id` (Gmail API
   request body `threadId`), so the reply lands in the original thread in Gmail
   and other clients.
3. **New `dispatch_reply` command** — `lib/buster_claw/commands.ex`, restricted
   tier (CLI/`:trusted` caller only, never MCP). Given an item id + body: fetch
   item → `To:` original sender → `Re: <subject>` (don't double-prefix) → set
   `in_reply_to`/`references`/`thread_id` → **send** → `Dispatch.finish(item, "done")`
   → Sentinel `:outbound_send` audit. The agent's one-shot "answer this email."
4. **mail-triage job rewrite** — `lib/buster_claw/jobs.ex` `default_mail_triage`:
   direct the on-shift agent loop: `dispatch claim --job mail-triage` →
   `gmail_read` the full body → compose → `dispatch_reply <id> --body …` → done.
5. **Tests** — Req.Test stubs for threaded send (assert `In-Reply-To`/`References`
   headers + `threadId`), `dispatch_reply` happy path (sends + marks done),
   Sentinel audit fires on send.

## Done-bar

- `mix test` green, `mix compile --warnings-as-errors` + `mix format --check-formatted`
  clean, working tree intentional.
- An email from a trusted sender, with the agent on shift, gets a threaded reply
  sent automatically and the dispatch item closed.

## Notes / open follow-ups

- CLI → `/api/run` with the full token = caller `:trusted`, so a restricted
  `dispatch_reply` is callable from the terminal agent. The MCP *endpoint* was
  deleted in the pull-queue cut, but the scoped `:mcp` token + caller tier still
  live in `api_auth`/`Commands.call` — a request authed with that scoped token is
  classified `:mcp` and refused restricted commands (`{:error,
  :requires_confirmation}` + `Sentinel.Pending`). So "restricted" remains a real
  gate: full token can send, scoped token cannot, every send is Sentinel-audited.
- Relates to [[orchestration-plan]] (shift lifecycle) and
  [[security-layer-research]] (Sentinel audit of outbound sends).
