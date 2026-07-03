# Quality Refactor Roadmap

## Purpose

Tighten the five concrete issues surfaced by the 05-17-26 multi-lens code review
before Gmail/OAuth work starts. The refactor is small, isolated, and intentionally
ordered so that the cleanups Gmail will lean on land first — specifically the
`inspect(reason)` purge, which prevents OAuth client secrets from being stringified
into HTTP responses the moment the Google integration touches Req errors.

This is a hygiene pass, not a feature pass. Every item is a known defect with a
known fix; success means a clean review against the same lenses with no regression
in test count or behavior.

## Non-Goals

- [ ] Do not start Gmail integration work in this pass — that lives in
      `05-17-26-gmail-integration-roadmap.md`. This is its prerequisite.
- [ ] Do not introduce at-rest encryption for `providers.api_key` or other secrets.
      Acceptable for the single-user loopback threat model; revisit when the threat
      model changes.
- [ ] Do not change behavior. Every change is a refactor or a defense-in-depth
      tightening. Test count must not drop.
- [ ] Do not rewrite `commands.ex` from scratch. The macro-deduplication trick
      already used in `automation.ex` / `workflow.ex` is enough.
- [ ] Do not chase test coverage % — close the specific gaps named below and stop.

## Findings (locked, from 05-17-26 code review)

| #   | Severity | Location                                              | Issue                                                                 |
| --- | -------- | ----------------------------------------------------- | --------------------------------------------------------------------- |
| 1   | Medium   | 7 call sites across controllers + LiveViews           | `inspect(reason)` leaks unknown error terms into HTTP/UI responses    |
| 2   | Medium   | `lib/buster_claw/api_token.ex:40`                     | Token file written with default umask (likely `0644`)                 |
| 3   | Low      | `lib/buster_claw_web/live/status_live.ex:113`         | Direct `Repo.update` bypassing `Providers.set_active_provider/1`      |
| 4   | Low      | `lib/buster_claw/commands.ex` (1,251 LOC)             | Repetitive CRUD wrappers ripe for the same macro pattern used elsewhere |
| 5   | Low      | `Provider` / `Providers` / `Providers.Provider`       | Naming triad imposes a cognitive tax on every reader                  |

Plus three test-gap items:

| #     | Location                                                  | Issue                                                              |
| ----- | --------------------------------------------------------- | ------------------------------------------------------------------ |
| T1    | `lib/buster_claw/api_token.ex` (no test file)             | Zero direct tests on the module that authorizes every API call     |
| T2    | `api_controller_test.exs:60`, `mcp_controller_test.exs:31`| `>= 70 commands` assertions ratchet with every command addition    |
| T3    | `webhook_controller_test.exs`                             | Happy-path + wrong-secret only; missing empty/missing-header cases |

## Phases

### Phase 1 — Error-formatting helper (item #1)

Build the foundation the other phases will use:

- Add `lib/buster_claw_web/error_formatter.ex` with `format/1` that pattern-matches
  known error shapes (`%Ecto.Changeset{}`, `{:http_error, status, body}`,
  `%Req.TransportError{}`, atoms, `{:missing_config, key}`, etc.) and returns a
  short, redacted, user-safe string.
- Unknown shapes return a generic `"unexpected error"` and log the full term under
  a request id at `:warning` level.
- Add `lib/buster_claw_web/error_logger.ex` (or extend an existing log helper) that
  produces the request-correlated log line. Use `Logger.metadata(request_id: …)`.
- Migrate the seven existing call sites:
  - `lib/buster_claw_web/controllers/api_controller.ex:60`
  - `lib/buster_claw_web/controllers/mcp_controller.ex:151`
  - `lib/buster_claw_web/live/scheduler_live.ex:47`
  - `lib/buster_claw_web/live/analysis_live.ex:26`
  - `lib/buster_claw_web/live/sources_live.ex:194`
  - `lib/buster_claw_web/live/documents_live.ex:34`
  - `lib/buster_claw_web/live/intelligence_live.ex:66`
- Tests: round-trip each known shape through `ErrorFormatter.format/1`; assert that
  a synthetic `Req.Request` containing a token in headers is **not** present in the
  formatted output.

### Phase 2 — Token file hardening (item #2, T1)

- `lib/buster_claw/api_token.ex`:
  - After `File.write!(path, token)`, call `File.chmod!(path, 0o600)`.
  - When ensuring the parent directory exists, call `File.chmod!(dir, 0o700)`.
  - Guard both with `os_type/0` so Windows (no POSIX modes) is a no-op rather than
    a crash if/when we get there.
- Add `test/buster_claw/api_token_test.exs`:
  - Generates on missing.
  - Idempotent re-load (same token returned across calls).
  - Honors `config :buster_claw, :api_token, "..."` override.
  - On POSIX, persisted file is mode `0o600` and parent dir `0o700`.
  - Uses a per-test `tmp_dir` fixture so it doesn't touch real `~/Library`.

### Phase 3 — Context boundary fix (item #3)

- `lib/buster_claw_web/live/status_live.ex:113` — replace the inline
  `provider |> Provider.changeset(%{active: false}) |> BusterClaw.Repo.update()`
  with a call to `Providers.set_active_provider/1` (the path already used on
  lines 124 and 448).
- Verify the existing `Providers.set_active_provider/1` correctly deactivates the
  previously active provider as part of its contract. If not, fold the deactivate
  step into the context, not the LiveView.
- Test: extend `test/buster_claw_web/live/status_live_test.exs` with a case that
  activates provider B while A is active and asserts A is deactivated via the
  context API (currently uncovered).

### Phase 4 — Commands CRUD deduplication (item #4)

- Identify the repeating `*_list / *_get / *_create / *_update / *_delete` blocks
  in `lib/buster_claw/commands.ex` (sources, providers, documents, hooks, webhooks,
  delivery destinations, etc.).
- Define a `defcrud :resource, context: Context, schema: Schema` macro that emits
  the same five wrappers with identical `{:ok, _} | {:error, reason}` semantics,
  modeled on the `for` macros already used in `lib/buster_claw/automation.ex` and
  `lib/buster_claw/workflow.ex`.
- Replace the duplicated handlers with macro invocations.
- Catalog functions (`list_commands/0`) must still emit the same names + arg
  schemas — verify via the existing dispatcher test.
- Target: ~30% LOC reduction in `commands.ex` with zero behavior change.

### Phase 5 — Catalog test stability (T2)

- `test/buster_claw_web/controllers/api_controller_test.exs:60` and
  `test/buster_claw_web/controllers/mcp_controller_test.exs:31`:
  - Replace `>= 70` count assertions with `> 0` plus an explicit `assert "runtime_status" in command_names` (or another command that is structurally load-bearing).
  - Keep the assertion that a couple of representative commands are present.

### Phase 6 — Webhook test depth (T3)

- `test/buster_claw_web/controllers/webhook_controller_test.exs` — add cases:
  - Webhook with **missing** signature header (currently only tests wrong value).
  - Webhook with **empty body** + signature.
  - Webhook with valid signature but unknown hook name → 404.
  - Confirm constant-time compare path exists (read-only test against
    `BusterClaw.Webhooks.verify_signature/3`).
- Same lens on `integration_webhook_controller_test.exs` for the integrations-side
  webhook handler.

### Phase 7 — Naming triad cleanup (item #5, optional this pass)

- Rename `BusterClaw.Provider` (behaviour) → `BusterClaw.Providers.Backend`.
- Update all `@behaviour BusterClaw.Provider` references in
  `lib/buster_claw/provider/*.ex` and the dispatcher in `lib/buster_claw/providers.ex`.
- This is grep-and-replace work; no behavior change. Run `mix compile
  --warnings-as-errors` after to catch any miss.
- Mark this phase **optional** — if scope expands, skip and revisit on its own.

## Tradeoffs accepted

- **Generic `"unexpected error"` over informative messages** for unrecognized
  shapes. We lose a debugging convenience on the user-facing surface in exchange
  for closing a known leak vector. The full term still goes to the log with a
  request id, so debugging is a `grep <request_id>` away.
- **Macro-based CRUD generation cuts grep-ability slightly** — but the same
  tradeoff is already accepted in `automation.ex` and `workflow.ex`, so we're not
  introducing a new pattern.
- **No symlink-attack hardening on the token file beyond chmod.** Single-user
  desktop app, attacker would need an existing local account; out of scope.

## Out of scope (revisit later)

- At-rest encryption for `providers.api_key`. Reasonable, but requires a vault
  module and key-derivation strategy that should ride alongside the Gmail
  encrypted-token work, not before it.
- Rate limiting / dedup on webhook endpoints. Handlers are idempotent by design;
  the threat model doesn't currently require it.
- Coverage % targets. Closing T1–T3 is enough for this pass.
- Splitting `commands.ex` into per-domain submodules. The macro pass shrinks the
  file enough; further fragmentation is premature.

## Success criteria

- `mix compile --warnings-as-errors`: clean.
- `mix test`: no decrease in test count; ideally +6–10 from new api_token,
  webhook, and StatusLive cases.
- `mix format --check-formatted`: clean.
- `inspect/1` no longer appears in any controller error-response or LiveView
  error-flash path (grep `inspect(reason)` returns zero hits under
  `lib/buster_claw_web/`).
- `lib/buster_claw/api_token.ex` persists at mode `0o600` on POSIX; verified by
  test.
- `lib/buster_claw/commands.ex` LOC drops by ≥250 lines with no behavior change.
- `status_live.ex` no longer imports or references `BusterClaw.Repo`.
- Smoke script `scripts/smoke_command_surface.sh` still 9/9.

## Dependencies

None. No new hex packages, no schema migrations, no UI changes that need design
review. This is a pure cleanup pass.

## Estimated scope

One focused session. Phases 1–3 are the highest-value and should land together;
4–7 are independent and can be sliced if time runs short.
