# Agent Web Automation — our own driver, no Playwright

**Date:** 2026-07-18 · **Status:** ACTIVE — the ambitious path, chosen by operator decision.

Two operator calls on 07-18, made together:

1. **Lose Playwright.** The sidecar (module, 17MB priv tree, config, tests, docs)
   is deleted — same commit as this roadmap. The native WKWebView is the only JS
   engine, and that's the point, not a compromise.
2. **Build our own web automation for the agent.** Grow the co-presence surface
   (`browser_read` / `browser_find_elements` / `browser_click` / `browser_fill` /
   `browser_render_page`) into a real automation capability: waiting, stable
   targeting, assertions, multi-step flows. **App-E2E self-testing is explicitly
   out of scope** — the operator chose the agent-facing product, not a test
   harness for Buster Claw itself.

**Why this is a product, not plumbing:** every headless-automation competitor
drives a puppet Chromium with an empty cookie jar. Ours drives **the user's real
logged-in WebKit** — sessions, extensions-free honesty, and the co-presence badge
— or a hidden ephemeral sandbox view when the user's session shouldn't be
touched. "Buster, test my signup flow" against the real site, with every step on
the Sentinel feed, is a pitch none of the puppet-browser tools can make.

---

## What we already have (the embryo)

- **Render:** `browser_render_page` (hidden ephemeral webview, wait budget) and
  the `fetch/2` live-render upgrade — thin/failed HTTP results re-render in real
  WebKit, and the render only wins when it yields more text (`pick_thicker`,
  07-18).
- **Act:** `browser_find_elements_active` (indexed snapshot of actionable
  elements) + `browser_click_active` / `browser_fill_active` on the visible tab.
- **Observe:** `browser_read_active`, `browser_screenshot` (in-process
  `takeSnapshot`, no Screen-Recording prompt).
- **Safety rails:** all act-on-page commands are `:restricted` tier; every fetch
  and action is Sentinel-observed; `URLGuard` pins SSRF-vetted connections;
  sandbox tabs exist that don't ride user cookies unless opted in.

## What Playwright had that we don't (the honest gap list)

- **Auto-waiting** — the single biggest one. Ours acts on a snapshot and hopes.
- **Stable targeting** — our click/fill take an *index into a previous snapshot*;
  a re-render between find and act misfires silently (stale-index hazard).
- **Assertions** and structured extraction with a schema.
- **Multi-step flows** with per-step timeouts, retries, and an honest failure
  report.

**Deliberately NOT rebuilding:** CDP, cross-browser engines, trace viewer,
video, parallel contexts, a test runner. One engine (the user's WebKit) is the
product. If a site "only works in Chrome," that's a finding, not our bug.

## Constraints (paid for already — don't relitigate)

- **The WKUIDelegate ceiling is ACCEPTED** (07-04 operator decision):
  `window.open` returns `null`. Flows cannot automate popup-based OAuth logins;
  document it per-flow, don't re-propose the delegate swap.
- **Threading contract:** every Tauri command that evals JS or snapshots must be
  an `async` command — a sync command runs on the main thread and deadlocks the
  run loop that delivers its completion (diagnosed live 07-18, contract
  documented on `eval_with_result` / `capture_webview` in `browser.rs`).
- **Page content is untrusted, always.** Flow steps come only from the caller;
  extraction results are data; nothing from the DOM is ever eval'd or allowed to
  steer a flow beyond its declared steps. Prompt-injection posture identical to
  email: fenced, observed, tiered.
- **Sandbox by default for flows.** Multi-step automation runs on an ephemeral
  sandbox surface unless the caller explicitly opts into the user's live session
  (co-presence badge on, `:restricted` tier as today).

## Phases

### Phase 0 — Lose Playwright ✅ DONE 07-18 (this commit)
Sidecar module + priv tree + config gates + supervision child + tests + doc
references deleted; `fetch/2` is HTTP + live-render upgrade only. The DMG gets
~17MB (≈19%) smaller and the future signing pass has one less Mach-O forest.

### Phase 1 — The wait primitive
`browser_wait` (safe tier, read-only): wait for selector-exists /
selector-visible / text-present / navigation-settled (readyState + a quiet-DOM
window), bounded by an explicit timeout budget. Built on polled `eval` in the
target webview — no new machinery, just discipline.
**Exit test:** the agent navigates an SPA login redirect and waits it out
without a single guessed sleep.

### Phase 2 — Selector-first acting
Targets re-resolve **at act time**: CSS selector, visible-text, or label match —
index mode stays as a fallback. Click/fill return the post-action element state
so the agent sees what happened.
**Exit test:** fill + click on a page that re-rendered between find and act, no
stale-index misfire.

### Phase 3 — Flows
`browser_flow` (`:restricted`): a declarative JSON step list — navigate → wait →
fill → click → extract → assert — executed atomically with one Sentinel event
per step and one result document at the end. Sandbox surface by default.
**Exit test:** a five-step login → navigate → extract flow runs headless and
files its result in the Library.

### Phase 4 — Assert + extract
`browser_assert` (selector/text/url predicates) and schema'd extraction
(page → validated JSON). A failing flow reports the failing step + a screenshot
— honest failure, not garbage output.
**Exit test:** a broken selector produces "step 3 failed: #signup-btn not found
[screenshot]", never a silent empty extract.

### Phase 5 — The testing product ("build our own testing")
Saved flows become **re-runnable site checks**: "test my signup flow" → a named
flow in the workspace (markdown-defined, like skills), run on demand by the
operator or the agent, pass/fail history in the Library. This is the prize: the
agent tests *websites* in a real logged-in browser, with receipts.
**Exit test:** the operator asks Buster to test a real form flow on their own
site twice; the second run reports pass/fail *against the first* without
re-explaining anything.

## Risks & honest notes

- **Actionability is genuinely hard** — Playwright spent years on hit-target
  math. We ship the 80%: exists/visible/enabled + scroll-into-view. The 20% tail
  (overlapped elements, animation races) is a documented limitation, not a
  promise.
- **One engine.** WebKit-only results can differ from Chrome. Feature, stated
  loudly, but it will generate "works in Chrome" reports.
- **Flows spend agent turns.** A flow is cheap; the agent *authoring* one isn't.
  The saved-flow library (Phase 5) is what amortizes it.
- **The live-session mode is the sharpest tool in the app** — acting inside the
  user's logged-in session, scripted. The tier gate and per-step Sentinel events
  are load-bearing; ship no flow capability without them.
