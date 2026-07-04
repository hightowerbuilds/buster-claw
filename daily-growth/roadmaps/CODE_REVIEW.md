# Code Quality Review — Buster Claw, whole codebase

*2026-07-04. A whole-codebase quality + security review run by 7 parallel domain
reviewers over ~34k LOC Elixir, ~3k LOC Rust (Tauri), and ~4.7k LOC JS. Each
finding is a real defect tied to a concrete `file:line` and failure scenario, not
a style nit. This doc is the durable record: it tracks what was found, what's
fixed, and what's still open.*

## Verdict up front

The architecture and the security **primitives** are strong — SSRF coverage,
AES-256-GCM vaulting, a fail-closed policy engine, timing-safe token compares, a
careful objc/WKWebView retain/release bridge, integer-cents money math. The real
risks cluster in two places: where **untrusted email meets trusted authority**
(the autonomous loop acting on attacker-controlled content) and where a **designed
defense was left inert** (a CSP that never enforced). The top-tier chain there is
now fixed; the remainder is a Medium/Low tail of robustness, resource, and
fail-open cleanups.

## Mechanical baseline

- ✅ `mix compile --warnings-as-errors` — clean
- ✅ `mix format --check-formatted` — clean
- ✅ `mix test` — **796 tests, 0 failures**
- ✅ `cargo check` — clean (pre-existing objc `msg_send!` cfg warnings only)
- Credo `--strict` — style-only (complexity/nesting, alias suggestions); no defects

## Status legend

- ✅ **FIXED** — resolved + regression-tested, with the commit noted
- ⬜ **OPEN** — verified real, not yet fixed

---

## 🔴 CRITICAL

| # | Finding | Location | Status |
|---|---------|----------|--------|
| 1 | **Sender-spoofing auth bypass.** `extract_address/1` took the *first* email-looking token in the raw `From` header, so `From: "alice@trusted.com" <evil@attacker.com>` was trusted as alice and drove the autonomous loop on attacker content. | `trusted_senders.ex:47` | ✅ FIXED `e88c7aa` |

**Fix:** prefer the *last* angle-bracketed addr-spec (RFC 5322), falling back to a
whole-header scan only when there are no brackets — defeats bare, quoted, and
fake-bracket display-name spoofs.

---

## 🟠 HIGH

| # | Finding | Location | Status |
|---|---------|----------|--------|
| 2 | **CSP was Report-Only in every env.** `:csp_mode` never set to `:enforce`, so the `script-src` RCE defense (webview → `window.__TAURI__` → shell) blocked nothing. | `plugs/content_security_policy.ex:52` | ✅ FIXED `e88c7aa` |
| 3 | **Agent-SVG XSS.** The regex sanitizer had bypasses (`javascript:` href, `<rect/onload=…>`, unclosed `<script>`) and its claimed CSP backstop was #2 (inert). | `svg_viewer.ex:53` → `raw/1` | ✅ FIXED `e88c7aa` |
| 4 | **Download OOM.** `do_download` buffered the whole response body into memory before the `byte_size > max_bytes` check → a hostile/unbounded stream OOMs the BEAM first. | `browser.ex:74` | ✅ FIXED `b88f42c` |
| 5 | **Runtime orphan-reclaim gap.** A swarm run crashing after `mark_running` (or CLI-claimed single items) stranded the item in `"running"` forever — reclaim was boot-only. | `dispatch.ex:85` + `dispatcher.ex:109` | ✅ FIXED `b88f42c` |
| 6 | **Encrypted fields fail open.** `load/1` returned raw bytes as "plaintext" on *any* decrypt error, conflating legacy plaintext with a key-mismatch / tampered ciphertext (ciphertext-as-secret). | `encrypted.ex:43` | ✅ FIXED `b88f42c` |
| 7 | **Rust release-monitor orphaned the BEAM on quit.** The monitor `take()`-ed the Phoenix `Child` out of the mutex, so `shutdown_release` saw `None` and returned without SIGTERM (port bound / DB locked next launch). | `main.rs` (monitor + `shutdown_release`) | ✅ FIXED `b88f42c` |

**Fixes:** #2 enforce CSP in prod (dev/test stay Report-Only for LiveReload). #3
hardened strips + href limited to bare `#fragment`, with enforced CSP as the real
backstop. #4 stream via Req `into:` collector with a running byte cap that halts on
exceed (peak memory ~`max_bytes`). #5 `:DOWN` handler reclaims immediately (the
normal `:run_done` path demonitors with `:flush`, so this fires only on a real
crash). #6 new `Vault.ciphertext?/1` frame check → framed-but-undecryptable fails
closed (log + `nil`). #7 poll the child in place (`try_wait` is non-blocking) so
`shutdown_release` always reaps it.

---

## 🟡 MEDIUM (all OPEN)

### Autonomous loop / dispatch
- ⬜ **Provenance sampling bypass** — `dispatcher.ex:252`. The fail-closed trust gate samples only `list_queued(limit: 50)` newest-first, but the agent claims oldest-first; with >50 queued, an older untrusted item runs under a `:trusted` token.
- ⬜ **Soft budget overshoot** — `dispatcher.ex:149,198`. Cap is pre-checked as `dispatched_count < cap`, but one tick fans out to ~7 runs (planner + subtasks) counted only on completion; a shift at `cap-1` blows past the token budget.
- ⬜ **`tick_now` forks perpetual timer chains** — `dispatcher.ex:49,85`. `:tick` unconditionally reschedules and `tick_now`/boot inject out-of-band ticks, so each nudge permanently multiplies tick frequency.
- ⬜ **Timeout leaks grandchild processes** — `agent_runner.ex:234`. On timeout only the direct agent pid is SIGKILLed; its Bash/MCP grandchildren aren't reaped (no process group).

### Integrations / browser
- ⬜ **Browserbase head-of-line blocking** — `browserbase/session_manager.ex:107`. All cloud ops serialize behind blocking HTTP in one GenServer; a slow `open`/`sweep` stalls every concurrent web command for tens of seconds.
- ⬜ **Brutal-kill orphans paid sessions** — `session_manager.ex:189` + `application.ex:138`. `terminate/2` does 30s-timeout releases but the worker has a 5s shutdown → supervisor kills it mid-release, leaking the paid sessions it promises never to leak.
- ⬜ **UTC datetimes parsed as wall-clock** — `google/calendar.ex:187`. Slices the first 19 chars and drops the offset, so `Z`/UTC events persist at the wrong local time.
- ⬜ **Token-refresh stampede** — `google/client.ex:76`. The 5-way fan-out shares one stale `Account`; an expired token triggers up to 5 simultaneous refresh POSTs + racing DB writes.

### Security / data
- ⬜ **Webhooks fail open + unauthenticated** — `router.ex:98` + `integrations/github.ex`, `sentry.ex`. `verify_webhook` returns `:ok` when the secret is `nil`/`""`, on the unauthenticated `:api` pipeline (loopback-only limits blast radius).
- ⬜ **Sentinel redacts by key name only** — `sentinel.ex:147`. Secrets under non-sensitive keys (OAuth `code`, tokens in `url`/`value`) persist cleartext to the audit log + PubSub. *(Also flagged as the Browserbase Phase-4 prereq.)*
- ⬜ **Skills YAML frontmatter injection** — `skills.ex:118`. `description`/`tier` interpolated into frontmatter unescaped; an approved skill with a `:` or newline misparses and silently fails to load.
- ⬜ **Wallet balance can bypass recompute** — `wallets/wallet.ex:27`. `changeset` casts `:balance_cents`, so generic `update_wallet/2` can overwrite the ledger-derived cache with an arbitrary value.
- ⬜ **EDGAR O(n²) column zip** — `finance/edgar.ex:203`. Materializes every filing row before `take(limit)`.

### Web / native
- ⬜ **Home LiveView assigns grow O(n²)** — `status_live.ex:346`. `chat_messages`/`chat_svgs` append via `&(&1 ++ [msg])` with no cap in the always-open home tab.
- ⬜ **Rust `browser_close_tab` doesn't advance the active pointer** — `browser.rs:431`. Co-presence commands resolve to the just-closed tab until the chrome's follow-up switch lands.
- ⬜ **WebGPU render has no device-loss guard** *(JS)* — `smoke.js:97`. Frames can fire against a lost device before `device.lost` cleanup runs.

---

## 🟢 LOW (OPEN)

**Path safety:** symlink escape in `file_manager.ex:143` (`within?` is lexical) ·
`terminal_workspace.ex:134` `label` unsanitized · `appearance.ex:344` path from
Settings (`..`) · `browser_home_controller.ex:266` `javascript:` URLs survive HTML-escape.
**Robustness:** unguarded `phx-value` → LiveView crash in `appearance_live`/`calendar_live`/`wallets_live` ·
missing catch-all `handle_info` in `wallets_live`/`integrations_live`/`gws_live` ·
`chat.ex:370` timeout race (no run token) · `dispatch.ex:187` `mark_running` no atomic guard ·
`status_live.ex:181` `close_chat` never unsubscribes PubSub.
**Error masking:** `settings.ex:50` and `wallets.ex:115` mask failed deletes.
**Growth / perf:** `dispatch_projector.ex:100` O(n²) diary writes · `browser_history.ex:57`
unbounded table · `wallets.ex:73` no pagination · `finance/edgar.ex:141` ticker cache no TTL ·
`endpoint.ex:57` duplicates every request body · `chrome.js:277` `zoomLevels` leak.
**Concurrency / dup:** `wallets.ex:188` upsert race · integrations have no 429/backoff
(`github.ex:218`, `umami`, `sentry`, `google/client.ex:162`) · `browser.rs:93` uses
`.lock().unwrap()` (poisoning propagates) · duplicated JS-literal encoders (`browser.rs`
vs `main.rs`) + `escapeHtml` (`terminal.js`/`tab_strip.js`) · `chat.js:54` leaves body
styles stuck if destroyed mid-drag · `terminal.rs:126` session-insert ordering.

---

## ✅ What's genuinely solid (reviewers volunteered these)

`URLGuard` (thorough SSRF coverage incl. 169.254.169.254, IPv6, redirect
re-validation, fails closed) · `Vault` (AES-256-GCM, per-op IV, AAD) ·
`PolicyEngine` (fail-closed, baseline-before-operator, escaped globs, no atom
injection) · `ApiAuth` / `ApiToken` (timing-safe compare, CSPRNG, `0o600`) ·
`GoogleOAuth` (signed state, 10-min max-age) · the objc/WKWebView bridge (balanced
retain/release, main-thread discipline) · HMAC webhook verification (constant-time)
· the **money layer** (integer cents, atomic recompute-from-ledger in a
transaction) · `markdown.ex` (correct `HtmlSanitizeEx` — the pattern `svg_viewer`
now mirrors) · `Browser.Bridge`/`Capture` (no pending-ref leak) · `Google.Vault`,
`voice.rs`, `workspace.rs`.

---

## Follow-up priorities

The whole top tier (1 CRITICAL + 6 HIGH) is closed. For the next pass, the
Medium items with real security or resource impact lead:

1. **Provenance sampling bypass** (`dispatcher.ex:252`) — trust hole in the same
   untrusted-email→trusted-authority class as the CRITICAL.
2. **Sentinel value-shape redaction** (`sentinel.ex:147`) — also unblocks
   Browserbase Phase 4 money-gating.
3. **Browserbase GenServer head-of-line blocking + shutdown session leak**
   (`session_manager.ex`) — the one item needing a small design change (async the
   HTTP; give `terminate/2` a real shutdown window).
4. **Webhook fail-open on empty secret** (`router.ex:98`) — small, high-confidence.

Everything else is quality/robustness cleanup that can be batched.
