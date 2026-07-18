# Code Quality Roadmap — Dead Code, Suppressions, Performance

> **ARCHIVED 2026-07-18 — fully executed.** Every phase landed on 07-17 (commits `ff3a564`, `e376a0a`, `27fe9aa`, `4eea94d`, `cb11844`, `c97351a`, `3c1ec1a`) or was skipped with its reason recorded inline below. The one parked item — the Playwright sidecar prune — moved to `../roadmaps/LEFTOVERS.md`.

**Whole-codebase quality review · 2026-07-17**

Post-build-streak sweep of the entire repo (lib/, assets/js/, desktop/tauri src, config/, priv/) for dead, orphaned, and suppressed code, plus performance-first refactor targets. Four parallel audits + a clean forced recompile (227 files, zero warnings).

> **Standing constraint for this entire roadmap: no visible UI changes.** Every phase below is either invisible to the user by construction (backend/plumbing) or carries an explicit "pixel-identical" acceptance bar. Nothing here redesigns, restyles, or rearranges any screen.

---

## The short version

The build streak left the codebase far cleaner than expected. Zero compiler warnings, zero skipped tests, zero TODO/FIXME markers, zero commented-out code. Every recent feature cut (Browserbase, Whisper STT, /humo, MCP endpoint) was removed at the root — the *only* confirmed dead code in the whole repo is a 3-file Whisper STT permission cluster in the Tauri shell.

The real work is **performance on the Phone tab**: a broadcast storm that can trigger 25 full re-queries + LiveView re-diffs in a 30-second window, and up to 200 simultaneous 60fps WebGPU render loops (one per voicemail row). Fixing both is entirely invisible to the eye — the tab looks identical, it just stops burning CPU/GPU.

---

## UI-impact ledger

Every item in this roadmap, classified. This is the contract:

| Item | UI impact |
|---|---|
| Batch/debounce telephony broadcasts | **None** — server-side; data still lands on screen within ~250ms |
| Gate AudioClip render loops | **None** — static waveforms render the same pixels once instead of 60×/sec; only the playing clip animates |
| Contacts triple-load dedup | **None** — pure backend |
| `Task.async_stream` for poll-tick HTTP | **None** — pure backend |
| SQL-side feed filtering | **None** — pure backend |
| Chat-history list building (prepend/reverse + cache) | **None** — same rendered output, built cheaper |
| Enqueue-result logging, silent-swallow logging | **None** — logs only |
| STT permission cleanup (Tauri) | **None** — deletes grants for commands that no longer exist |
| LiveView streams conversion | **⚠ Only item that touches templates.** Markup must stay pixel-identical — see Phase 3 acceptance bar |

---

## Phase 1 — Phone tab performance (the felt win)

The Phone tab is the money leg's face; it's also where all the waste concentrates. All three fixes are invisible.

### 1a. Kill the broadcast storm
- `Telephony.apply_cost` (`lib/buster_claw/telephony.ex:133`) broadcasts `{:telephony_event, ...}` once **per priced voicemail**; `refresh_unpriced_costs/1` prices up to 25 rows per 30s drain tick (`telephony/drain.ex:45,85`).
- Each broadcast makes `PhoneLive.load_data/1` (`phone_live.ex:263`) re-run 3 aggregate stat queries + a 200-row `list_events` reload + a thread re-query. Worst case: **25 full reloads per tick, per open Phone tab**.
- Fix: batch the cost back-fill into a single post-pass broadcast (e.g. `{:telephony_costs_updated}`), **and** debounce `:telephony_event` in `PhoneLive` (coalesce bursts within ~250ms before reloading). Belt and suspenders.

### 1b. Stop the per-row GPU loops
- Every voicemail row (`phone_live.ex:451`, `phx-hook="AudioClip"`) runs a perpetual 60fps `requestAnimationFrame` loop (`assets/js/hooks/audio_clip.js:68-73`) — playing or not, on-screen or not. Up to 200 loops at once.
- Fix: render the static waveform **once**; run the rAF loop only for the actively-playing clip; gate with `IntersectionObserver` so off-screen clips don't render at all.
- **Acceptance: the waveforms look exactly as they do today.** If there's any idle shimmer/animation in the current look, keep it for on-screen clips — the observer gating is still a win because off-screen is invisible by definition.

### 1c. Contacts triple-load
- `PhoneLive.load_contacts/1` (`phone_live.ex:227`) hits the contacts table three times per broadcast: `list_contacts/0`, then `by_phone/0` → `list_contacts/0` again (`contacts.ex:85`), then `orphan_entries/0` → a third load + two `File.read` policy scans (`contacts.ex:175,182,185`).
- Fix: load once, pass the in-memory list into `by_phone`/`orphan_entries` variants.

## Phase 2 — Ingestion-path hardening (tiny diffs, real protection)

Silent failure points on the trusted-sender / voicemail triage path. Logging only — zero behavior change on the happy path.

- `lib/buster_claw/telephony/drain.ex:228` and `lib/buster_claw/google/gmail_sync.ex:189` — `_ = Dispatch.enqueue_*(...)` discards the enqueue result. If it errors, an inbound voicemail/email silently never gets triaged. Fix: match the result, `Logger.error` on failure.
- `lib/buster_claw/introduction.ex:44-48` — intro-file write swallowed with no log. Add `Logger.warning` in the rescue.
- `desktop/tauri/src/workspace.rs:41` — `let _ = fs::write(...)` on default-workspace seeding. Log the error.
- `assets/js/hooks/browser.js:73,80` — `.catch(() => {})` on screenshot/command result POSTs; `desktop/tauri/src/browser.rs:1066,1718` — `let _ =` on reqwest telemetry sends. Add `console.warn` / `log::warn` so a broken reporting channel is diagnosable.

## Phase 3 — LiveView streams (the one template-touching phase)

Only `security_live` uses streams today. The phone log (`phone_live.ex:276`, 200 rows), chat transcript + SVGs (`status_live.ex:633,658`), and wallet ledger re-diff the whole collection on every event.

- Convert to `stream/3` + `phx-update="stream"` one surface at a time: phone log → chat transcript → wallet ledger.
- **Acceptance bar (this is the "don't mess with UIs" phase):**
  - The rendered DOM must be structurally identical except for the required stream ids on the container/items.
  - No class, layout, or ordering changes. Screenshot before/after each surface and eyeball-diff.
  - Existing LiveView tests must pass unmodified (or with only stream-id selector updates).
- If any surface fights the conversion (e.g. the chat transcript's in-place token streaming), **skip it and record why here** rather than bending the UI to fit streams.

**RESOLVED 07-17:**
- **Chat transcript: CONVERTED.** Clean fit — append-only, id'd, capped. `stream_configure` keeps the exact `chat-msg-#{"{id}"}` DOM ids; appends now send one bubble instead of re-rendering the list, and the server no longer holds 200 messages per socket. Empty state moved to the documented CSS `only:` idiom; `data-seq` on the panel guarantees the scroll-to-bottom hook still fires per insert. Covered by a new stream-insert test.
- **Phone log: SKIPPED.** Row styling depends on `@selected_event` (accent border) and heard-state, and every update path is a full re-query — a stream would be `reset: true` each time (identical wire traffic) plus re-insert bookkeeping for selection changes. Phase 1a's debounce already removed the reload storm; a conversion here adds complexity and UI risk for ~no win.
- **Wallet ledger: SKIPPED.** Same shape — `refresh_selected` re-queries wholesale on every wallet event, and `Enum.find` reads the transactions list server-side (edit flow). Reset-only streams buy nothing.
- **Chat SVG rail: SKIPPED.** Zoom prev/next navigation (`zoom_step`) needs the ordered collection server-side; a stream would force a parallel id index, defeating the memory win.

## Phase 4 — Backend poll-tick refactors

All invisible; do opportunistically.

- `Wallets.poll_due_feeds/1` (`wallets.ex:394`) and the drain's per-row recording downloads + up-to-25 sequential Twilio calls (`drain.ex:140`, `telephony.ex:105`): wrap per-item HTTP in `Task.async_stream(..., timeout:, on_timeout: :kill_task)` so one hung endpoint can't stall the batch. SQLite is single-writer — keep writes on the caller side, only parallelize the HTTP.
- `wallets.ex:398-401,483,500-503` — load-all-then-`Enum.filter` on every dispatch/integration event: push the `due?` cutoff and integration-id match into `where` clauses.
- `status_live.ex:633,658,687-705` — quadratic `list ++ [x]` appends and per-row SVG re-parse on every tab switch: build with prepend + `Enum.reverse`; cache the parsed transcript per conversation.
- `assets/js/hooks/smoke_background.js:122,127,153` — hoist per-frame object allocations and the `getElementById` out of the frame loop. GC pressure only; strictly no visual change.

**RESOLVED 07-17:**
- **DONE:** `poll_due_feeds`/`poll_wallet_feeds` and `refresh_unpriced_costs` now run their HTTP concurrently (`Task.async_stream`, concurrency 4, 15s hard timeout, kill on timeout) with all DB writes kept on the calling GenServer (SQLite single-writer). `load_chat_history` builds by prepend+reverse. `smoke_background.js` frame loop allocates nothing (scratch lens/expression objects, cached chat-panel node).
- **SKIPPED — SQL pushdown of `due?`/integration-id filters:** both queries already narrow by kind+enabled in SQL; the residual Elixir filter runs over a handful of rows, and SQLite datetime-text/`json_extract` fragments add fragility for no measurable win at personal scale.
- **SKIPPED — parallelizing the drain's per-row recording downloads:** the drain's persist-then-ack row discipline is a crash-safety invariant; reordering rows for download concurrency isn't worth touching it at voicemail volume.
- **SKIPPED — caching the parsed transcript per conversation:** tab switches are rare and the parse is bounded at 200 rows; a cache adds invalidation state for an unfelt win.

## Phase 5 — Deletions & housekeeping

- **Whisper STT cluster (the only confirmed dead code):** remove **as one atomic set** — `desktop/tauri/capabilities/default.json:27-28` (`allow-start-recording`/`allow-stop-recording`) + `permissions/autogenerated/start_recording.toml` + `stop_recording.toml`. Deleting the tomls alone breaks the Tauri build; deleting only the capability entries leaves stale grants.
- `DNSCluster` no-op child (`application.ex:30`) — Phoenix generator default, pointless in a desktop app. Remove the child + dep.
- **Decision, not dead code:** `priv/playwright_sidecar/` is intentionally retained (health/fetch still reachable via `browser_fetch` + Wallets) but default-off and never active in shipped builds; its `node_modules` is dormant bundle weight. Prune only if browser-rendered fetch is declared dead as a product. *Parked — no action without an operator call.*

---

## Explicitly NOT in scope (checked and clean — don't re-audit)

- All 150+ Elixir modules have live callers; every LiveView/controller is routed; every supervised child is real. No orphaned Elixir code exists.
- All 25 JS hooks registered *and* referenced; all shaders reachable; all vendor libs and Tauri commands used; CSS has no dead feature selectors.
- Poller/dispatcher/scheduler design is sound (single-timer discipline, cheap ticks, event-driven with backstops) — do not "optimize" it.
- Trust checks use `:persistent_term` — per-render calls are fine.
- The credo disables (6 targeted lines), the documented earmark-CVE lint ignore, and the `rescue _ -> :ok` best-effort cleanups are all defensible as-is.
- `sms_threads/0` unbounded query is documented-intentional at personal-phone scale.
- `precommit` already enforces `--warnings-as-errors` + `credo --strict` + full tests.

## Sequencing

1. **Phase 1** (one commit per sub-item, verify Phone tab visually after each)
2. **Phase 2** (single small commit)
3. **Phase 5** STT cleanup + DNSCluster (single commit, verify Tauri build)
4. **Phase 3** streams, one surface per commit, screenshot-diffed
5. **Phase 4** opportunistically

Each phase ends with the standard wrap-up: `mix precommit`, dated dev summary, commit, push.
