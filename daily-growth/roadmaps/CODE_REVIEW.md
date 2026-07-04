# Code Quality Review — Buster Claw, whole codebase

*2026-07-04. A whole-codebase quality + security review run by 7 parallel domain
reviewers over ~34k LOC Elixir, ~3k LOC Rust (Tauri), and ~4.7k LOC JS. Each
finding is a real defect tied to a concrete `file:line` and failure scenario, not
a style nit. This doc is the durable record: it tracks what was found and what's
fixed.*

**STATUS: all findings resolved.** The top tier (1 CRITICAL + 6 HIGH) was fixed
first (commits `e88c7aa`, `b88f42c`); the Medium/Low tail was then cleared in a
single 8-agent parallel sweep, partitioned by disjoint files and verified
centrally. A few fixes involved judgment calls — see *Flagged for review* at the
end.

## Verdict up front

The architecture and the security **primitives** are strong — SSRF coverage,
AES-256-GCM vaulting, a fail-closed policy engine, timing-safe token compares, a
careful objc/WKWebView retain/release bridge, integer-cents money math. The real
risks clustered where **untrusted email meets trusted authority** and where a
**designed defense was left inert** (a CSP that never enforced). Both classes are
now closed.

## Verification (post-sweep)

- ✅ `mix compile --warnings-as-errors` — clean
- ✅ `mix format --check-formatted` — clean
- ✅ `mix test` — **826 tests, 0 failures**
- ✅ `cargo check` — clean (pre-existing objc `msg_send!` cfg warnings only)
- ✅ `mix assets.build` — clean

## Status legend

- ✅ **FIXED** — resolved + regression-tested (Elixir) or manually reasoned (Rust/JS)

---

## 🔴 CRITICAL

| # | Finding | Location | Status |
|---|---------|----------|--------|
| 1 | **Sender-spoofing auth bypass** — first-match `From` parse trusted a spoofed display name. | `trusted_senders.ex:47` | ✅ `e88c7aa` |

---

## 🟠 HIGH

| # | Finding | Location | Status |
|---|---------|----------|--------|
| 2 | **CSP was Report-Only in every env** — the RCE defense blocked nothing. | `plugs/content_security_policy.ex` | ✅ `e88c7aa` |
| 3 | **Agent-SVG XSS** — regex sanitizer bypasses + inert CSP backstop. | `svg_viewer.ex:53` | ✅ `e88c7aa` |
| 4 | **Download OOM** — whole body buffered before the size check. | `browser.ex:74` | ✅ `b88f42c` |
| 5 | **Runtime orphan-reclaim gap** — crashed run stranded items in `running`. | `dispatch.ex` + `dispatcher.ex` | ✅ `b88f42c` |
| 6 | **Encrypted fields fail open** — decrypt error returned ciphertext-as-secret. | `encrypted.ex:43` | ✅ `b88f42c` |
| 7 | **Rust release-monitor orphaned the BEAM on quit.** | `main.rs` | ✅ `b88f42c` |

---

## 🟡 MEDIUM — all ✅ FIXED (8-agent sweep)

### Autonomous loop / dispatch
- ✅ **Provenance sampling bypass** (`dispatcher.ex` + `dispatch.ex`) — replaced the 50-item newest-first sample with a `Dispatch.any_untrusted_open?/0` EXISTS probe over the whole open pool.
- ✅ **Soft budget overshoot** (`dispatcher.ex`) — a swarm now reserves its worst-case fan-out (planner + `swarm_max_subtasks`) against the cap before starting; if it wouldn't fit, the shift stops cleanly.
- ✅ **`tick_now` forks perpetual timer chains** (`dispatcher.ex`) — a single stored `tick_ref` is cancelled/replaced, so exactly one periodic timer exists regardless of nudges.
- ✅ **Timeout leaks grandchild processes** (`agent_runner.ex`) — runs launch as their own process-group leader (`setpgrp`), and a timeout kills the whole group (agent + Bash/MCP subprocesses).

### Integrations / browser
- ✅ **Browserbase head-of-line blocking** (`session_manager.ex`) — blocking HTTP moved onto a per-manager `Task.Supervisor`; `open` replies async, `sweep`/`close` release on tasks; state stays GenServer-owned. In-flight opens count toward the concurrency cap.
- ✅ **Brutal-kill orphans paid sessions** (`session_manager.ex` + `application.ex`) — `terminate/2` releases concurrently (20s per-session cap) inside a 25s supervisor shutdown window.
- ✅ **UTC datetimes parsed as wall-clock** (`google/calendar.ex`) — full RFC3339 parse → shift to OS-local wall time; offset-less strings keep the naive fallback.
- ✅ **Token-refresh stampede** (`google/client.ex`, `gmail.ex`, `gmail_sync.ex`) — a single up-front `ensure_fresh_token/2` before the fan-out (verified 1 refresh across a 3-message fan-out).

### Security / data
- ✅ **Webhooks fail open + unauthenticated** (`integrations/github.ex`, `sentry.ex`) — missing/empty secret now returns `:webhook_secret_not_configured` (fails closed).
- ✅ **Sentinel redacts by key name only** (`sentinel.ex`) — added value-shape redaction (token prefixes, 40+ char high-entropy runs, Luhn-valid cards) regardless of key.
- ✅ **Skills YAML frontmatter injection** (`skills.ex`) — `description`/`tier` are now quoted/escaped to match `Frontmatter.split`.
- ✅ **Wallet balance can bypass recompute** (`wallets/wallet.ex`) — `:balance_cents` dropped from the public `cast`; only the recompute path writes it.
- ✅ **EDGAR O(n²) column zip** (`finance/edgar.ex`) — columns sliced to `limit` before zip (O(columns × limit)).

### Web / native
- ✅ **Home LiveView assigns grow O(n²)** (`status_live.ex`) — `chat_messages`/`chat_svgs` capped at 200 (drop oldest).
- ✅ **Rust `browser_close_tab` doesn't advance the active pointer** (`browser.rs`) — close now advances to a sibling or unsets.
- ✅ **WebGPU render has no device-loss guard** (`smoke.js`) — `deviceLost` flag + try/catch, frames no-op after loss.

---

## 🟢 LOW — all ✅ FIXED

**Path safety:** `file_manager.ex` `within?` resolves one symlink hop per component ·
`terminal_workspace.ex` `label` sanitized (control chars/whitespace/cap) ·
`appearance.ex` `slot`/`home_image` paths guarded to their dir ·
`browser_home_controller.ex` hrefs pass an http(s)-scheme allowlist.
**Robustness:** `phx-value` handlers guarded in appearance/calendar/wallets LiveViews ·
catch-all `handle_info` added to wallets/integrations/gws LiveViews ·
`agent/chat.ex` timeout timer carries a per-run token (no false kill of the next run) ·
`dispatch.ex` `mark_running` — (covered by the DOWN-reclaim + provenance work) ·
`status_live.ex` `close_chat` unsubscribes PubSub.
**Error masking:** `settings.ex` and `wallets.ex` delete paths return proper `:ok`/`{:error, _}`.
**Growth / perf:** `dispatch_projector.ex` diary is append-only (no full re-read) ·
`browser_history.ex` prunes to a 10k row cap · `wallets.ex list_transactions` paginates (500 default) ·
`finance/edgar.ex` ticker cache has a 24h TTL · `endpoint.ex` raw-body copy scoped to the webhook path only ·
`chrome.js` deletes `zoomLevels` on tab close.
**Concurrency / dup:** `wallets.ex upsert_budget` resolves the unique-constraint race cleanly ·
429/Retry-After surfaced across github/sentry/umami/google adapters ·
`browser.rs` locks de-poison via `unwrap_or_else(|e| e.into_inner())` ·
js-literal encoder unified crate-wide (`browser::js_str`) + `escapeHtml` extracted to `assets/js/lib/html.js` ·
`chat.js` restores body styles if destroyed mid-drag · `terminal.rs` inserts the session before spawning its reader.

---

## Flagged for review (judgment calls the agents made)

These are shipped and green, but were choices worth a second look:

1. **Swarm budget → stops the shift** (not skip-past) when a swarm's worst case
   wouldn't fit the remaining cap. Consistent with existing cap-breach semantics;
   the alternative (skip) would busy-stall on the un-startable item. Change if you
   prefer skip-to-single-items.
2. **Browserbase 20s per-session release cap / 25s shutdown window** — a release
   exceeding 20s at quit is killed and relies on Browserbase's own idle-timeout
   backstop. Numbers are a judgment call; confirm they fit the infra. Also a
   narrow new orphan window: a session created in the exact shutdown instant
   (before its open task reports back) isn't recorded to release.
3. **Sentinel value-shape redaction** could over-redact a genuinely random 40+
   char alphanumeric identifier; thresholds were set conservatively (>36 to spare
   UUIDs) and prose is untouched in tests.
4. **`browser_history` retention = hard 10k-row cap** (newest by id), not
   time-based expiry.
5. **`agent_runner` process-group kill** relies on `perl` (universal on macOS);
   if absent, the group-kill no-ops and the direct-pid kill is the fallback
   (old best-effort behavior). This spawn change also applies to the streaming
   chat `open/2` path (a strict superset benefit).
6. **Google 429** now surfaces `{:google_api_rate_limited, ...}`; an
   `error_formatter.ex` clause was added so it formats cleanly. No automatic
   retry loop was wired (scheduler-level concern).

Everything above is regression-tested (Elixir) or manually reasoned (Rust/JS);
826 tests green.
