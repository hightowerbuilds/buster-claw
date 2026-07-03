# Agentic Web (Browserbase) Build-Out Roadmap

*2026-07-03. Governing principle: **the agent gets a real pair of hands on the
web, and the user never loses sight of them.** Every capability ships with a
Sentinel event and a live picture; anything that spends money or touches a
credential stops for a human. We drive Browserbase with **primitives the agent
composes**, not an embedded automation-LLM — the intelligence stays remote
(Claude in the terminal), exactly as the rest of BusterClaw is built.*

Effort tags: **S** = a sitting, **M** = a day-ish, **L** = multi-day / has unknowns.

---

## Where this sits vs. the native browser

`BROWSER_ROADMAP.md` Phase 3 (co-presence) is the agent driving the **user's
own local WKWebView session** — reading and acting on the *logged-in pages the
user is already looking at*, on this machine, riding the user's cookies. This
roadmap is the complement: a **cloud browser** (Browserbase) the agent drives as
its *own* sessions for open-ended web work — filling forms, running multi-step
flows, and (gated) transacting — with the live session mirrored back into the
BusterClaw browser so the user watches and can take the wheel.

Two surfaces, one mental model (small audited verbs, visible agent). They do not
compete: local co-presence is "act as me, here"; Browserbase is "go do this
out there, where I can see you." Naming keeps them distinct — native commands
are `browser_*`, cloud commands are `web_*`.

## Already de-risked (spikes, 07-03 — not yet in the tree)

Throwaway spikes against the real key proved the mechanism before any roadmap
was written:

- Key valid; `POST /v1/sessions` returns a session in **~380 ms**;
  `chromium.connectOverCDP(session.connectUrl)` on our **already-vendored
  Playwright** works — no new browser to ship.
- Primitives exercised end-to-end on a live site: navigate, **fill + read-back**,
  **structured extraction** (table rows → JSON), **dropdown select**,
  **screenshot** (returned a valid PNG of the live cloud page).
- Live view: `GET /v1/sessions/{id}/debug` → `debuggerFullscreenUrl` on
  `www.browserbase.com`; **interactive** (watch + click/type/scroll, human
  takeover for credential delegation), and **no `X-Frame-Options` / CSP framing
  header** on the entry URL. *Open caveat:* the entry answered `308`; final-page
  framing headers still to be confirmed against a live session (Phase 3.1).

Guiding constraint from those spikes: **cost is per browser-minute.** Session
lifetime discipline is a first-class design concern, not an afterthought (see
Cross-cutting §A).

---

## Phase 0 — Backbone (no agent-visible capability; unblocks everything)

*Build the plumbing and prove it with the safest possible payload.*

1. **`BusterClaw.Browserbase` API client.** (M)
   Req-based client (per house rule — no httpoison/tesla) for the endpoints we
   need: `create/1`, `debug/1` (live-view URLs), `retrieve/1`, `list/0`,
   `release/1` (end a session — the cost lever). Header `X-BB-API-Key`; project
   inferred from key, `PROJECT_ID` sent when present. Config in `runtime.exs`
   (`browserbase_api_key`, `browserbase_project_id`, `browserbase_enabled`),
   mirroring the `browser_sidecar_*` pattern. Secrets from env in dev; **OS
   keychain in a packaged build** (ties to `distribution_roadmap`, reuse
   `vault.ex`/`encrypted.ex`). Never logged.
   *Done when:* client is covered by `Req.Test` stubs (mirror
   `browser_test.exs`'s `BrowserSidecarHTTP` stub), and a **live smoke test**
   exists behind a `@tag :browserbase_live` + env guard so CI never spends money.

2. **Pick and build the CDP driving seam.** (L — the load-bearing decision)
   There is no mature Elixir CDP client; Playwright is. **Decision: extend the
   sandboxed Node sidecar we just shipped into a stateful session driver.** It
   already has Playwright vendored and now runs under Seatbelt; it gains
   `/session/*` endpoints (open/act/read/close) that Elixir calls over the
   existing loopback HTTP boundary. Rejected alternative: hand-rolling CDP in
   Elixir (immature, and we'd reimplement Playwright's selector/wait engine).
   *Done when:* the sidecar can hold a Browserbase-backed session open across
   multiple HTTP calls and drive it, proven by a sidecar-level test.

3. **`BusterClaw.Browserbase.SessionManager` GenServer.** (M)
   Owns session lifecycle in the BEAM: `session_id → {bb_session, live_view_url,
   sidecar_ref, opened_at, last_used_at, owner_tier}`. Enforces **idle timeout**
   and **max lifetime** (reaps and `release/1`s — the cost guardrail). Survives
   OTP restart the way the rest of the app does: durable session records so a
   crash mid-flow doesn't orphan a paid cloud browser (also lets us `release/1`
   strays on boot). Registered in `application.ex` behind `browserbase_enabled`.
   *Done when:* opening N sessions, killing the manager, and restarting reaps or
   re-adopts every session with no cloud leak (asserted in a test with a stubbed
   client).

**Exit criteria:** an internal-only session can be opened, driven once, and
reliably torn down; `mix precommit` green; zero new agent-facing surface.

## Phase 1 — Cloud fetch parity (exercise the whole path, add no new risk)

*Prove the backbone on the capability we already have before adding new verbs.*

1. **Optional Browserbase backend for `browser_fetch`.** (M)
   The sidecar's `engine.launch()` gains a `connectOverCDP(session.connectUrl)`
   branch when a Browserbase session is requested; the existing `/fetch`
   contract and all downstream markdown/Sentinel handling are unchanged. Gated
   per-call and by config; **local sandboxed Playwright stays the default.** Buys
   proxies/stealth for the read path and runs the full session lifecycle under
   real load with no new action surface.
   *Done when:* `browser_fetch` returns identical shape whether the page rendered
   locally or in Browserbase, selectable by option, both covered by tests.
2. **Fallback + health.** (S)
   Browserbase unreachable/over-quota → fall back to the local sidecar with a
   Sentinel note; surface backend + session health in `Browser.status/0` (it
   already reports sidecar health/sandbox — extend it).

**Exit criteria:** the read path can transparently run in the cloud, degrade to
local, and the user can see which backend served a fetch.

## Phase 2 — Session primitives (the core capability — read & fill, **no submit**)

*The verbs the agent composes. All restricted-tier, all Sentinel-logged with
selector/value provenance. Deliberately small and narratable — not a raw CDP
surface. This phase cannot spend money or submit anything, by construction.*

1. **Lifecycle verbs.** (M) `web_session_open` → `{session_id, live_view_url}`;
   `web_session_close`; `web_session_list`. Session id is what the **stateless
   CLI** threads through every later call (the agent holds it; the BEAM holds the
   browser). Idle-timeout semantics documented for the agent.
2. **`web_navigate(session_id, url)`.** (S) SSRF/allowlist posture reused from
   `url_guard.ex`; Sentinel `:untrusted_ingest` on the resulting page.
3. **`web_read(session_id)`.** (S) Rendered DOM → markdown/text + links, 200 KB
   cap — the cloud sibling of native `browser_read`. This is how the agent *sees*
   without a screenshot round-trip.
4. **`web_find_elements(session_id, query)`.** (M) Return candidate selectors +
   roles/labels so the agent can target `fill`/`click` without guessing DOM. The
   quiet keystone — primitives are only usable if the agent can find handles.
5. **`web_fill(session_id, selector, value)`** and **`web_select(...)`.** (S)
   Value provenance in the Sentinel event (with redaction hooks for anything
   secret-shaped).
6. **`web_click(session_id, selector)` — non-submit only.** (M) Guard: refuse
   elements that look like a payment/submit/checkout affordance in this phase
   (heuristic + explicit denylist); those unlock in Phase 4 behind confirmation.
   *Honest caveat:* the heuristic will have false negatives — Phase 4's hard gate
   is the real safety net, this is defense-in-depth.
7. **`web_screenshot(session_id)` → Library artifact.** (S) Reuse the
   fetch→artifact pipeline; visual observation for the agent and an audit record.
8. **`web_extract(session_id, spec)`.** (M) Structured extraction (selector map
   or schema) → JSON, so multi-item scrapes don't cost a `web_read` + parse each
   step.

**Exit criteria:** from the terminal, the agent can open a cloud session, find
its way around a real multi-field form, fill it, extract results, and close —
end-to-end, audited, and demonstrably unable to submit or pay.

## Phase 3 — Live view in the BusterClaw browser (the "watch it work" request)

*The cloud session becomes a native tab the user watches and can seize.*

1. **Confirm embeddability for real, then render it.** (M)
   Resolve the 308 caveat: fetch the *final* live-view page's headers from a live
   session and confirm no `frame-ancestors`/`X-Frame-Options` block. Then, on
   `web_session_open`, open a browser tab at `debuggerFullscreenUrl` via the
   existing chrome/`browser_navigate` seam. If top-level nav is blocked, fall
   back to a Phoenix panel that `<iframe>`s it (docs bless the iframe with
   `sandbox="allow-same-origin allow-scripts"`).
   *Done when:* opening a session makes the live cloud browser appear as a tab
   and track the agent's actions in real time.
2. **"Agent session — live" chrome indicator.** (S) A visible, unmistakable
   marker while a cloud session is open (trust is the product — same stance as
   native co-presence's "agent is reading" indicator). Distinct styling from
   user tabs (hazard-orange, per the design identity).
3. **Human takeover.** (M) Interactive live view (drop `pointer-events:none`) so
   the user can click/type — the credential-delegation path: agent drives to the
   login/card step, hands off, user completes it, agent resumes. The agent
   **never receives the secret**. This is the safety story for Phase 4.
4. **Tab ↔ session lifecycle.** (S) Closing the tab prompts/soft-closes the
   session (cost); session death (timeout/crash) reflects in the tab, not a dead
   frame.

**Exit criteria:** a user opening an agent session sees it live in their own
browser, can take the wheel for a login, and hand it back.

## Phase 4 — Guarded actions: submit, purchase, account changes (the money tier)

*Nothing here proceeds without an explicit human yes. This is where "purchase
things" and "set up mailing" get their teeth — carefully.*

1. **Confirmation gateway on `web_submit` / `web_purchase`.** (L)
   Route through `Sentinel.Pending` (the pending-confirmation seam already
   exists): the agent *prepares* the action (fills the cart, stages the form),
   BusterClaw emits a pending event with full provenance (target domain, fields,
   amount), and the action fires only on human approval. No approval → it never
   executes.
   *Done when:* a staged purchase on a test store blocks, surfaces a confirmation
   with the real amount + domain, and only completes after approval.
2. **Spending policy.** (M) Per-transaction and rolling caps, plus a domain
   allowlist, enforced in `policy_engine.ex`. Over-cap = auto-deny with a clear
   reason, even if a human clicks yes (a second brake on the biggest risk).
3. **Where confirmation appears.** (M — needs a UX decision, see Open questions)
   Sentinel feed, a modal, and/or the terminal. Must be visible whether the user
   is in the app or the terminal when the agent hits the gate.
4. **Redaction + audit completeness.** (S) Card/PII-shaped values redacted in
   events and logs; every gated action leaves a complete, replayable audit trail
   (pairs with Browserbase session recording — Phase 6).
5. **Credential-delegation as the default for secrets.** (S) Policy: agent
   requests a human takeover (Phase 3.3) rather than handling passwords/cards
   directly wherever possible; direct entry is the exception, always gated.

**Exit criteria:** the agent can complete a real transaction *only* through a
human-approved, capped, fully-audited path — and is structurally prevented from
doing so any other way.

## Phase 5 — Product-selling workflows (the actual goal)

*Compose the primitives + gates into the flows Luke wants, as reusable recipes.*

1. **Persistent contexts / logged-in sessions.** (M) Browserbase persistent
   contexts to stay authed into seller/mailing platforms across sessions.
   **Honest caveat + a required decision:** persistent contexts store cookies/
   auth **in Browserbase's cloud** — your logged-in sessions live on a third
   party. Document the exposure; make it opt-in per platform; prefer takeover
   login over stored credentials where the platform allows.
2. **"Set up mailing to sell a product" recipe.** (M) A documented Skill (fits
   `skills.ex`) that sequences the primitives for the concrete workflow, with the
   money/credential steps landing on Phase 4 gates.
3. **Templated multi-step flows.** (M) Parameterized recipes (list a product,
   configure a campaign) the agent can invoke with arguments rather than
   re-deriving every click.

**Exit criteria:** Luke can ask the agent to run a real product-listing/mailing
setup and watch it happen, stopping only to approve spend and enter secrets.

## Phase 6 — Opportunistic / stretch

- **Session recording → Library.** (M) Pull Browserbase's recording per session
  into an artifact — the definitive audit companion to the live event feed.
- **Proxies / geolocation / CAPTCHA handling.** (M) Expose Browserbase's
  stealth/proxy knobs where a flow needs them; off by default.
- **Concurrency.** (M) Multiple simultaneous sessions (a swarm shift running
  parallel web tasks) — SessionManager already keys by id; needs cost ceilings
  and live-view multiplexing in the chrome.
- **Cost dashboard.** (S–M) Session-minutes + spend surfaced in the app; the
  usage-based-billing feedback loop the user needs to trust autonomy.
- **Downloads from cloud sessions** into the workspace ingest path.

---

## Cross-cutting concerns (apply to every phase)

- **A. Cost control (billing is per browser-minute).** Idle timeout + max
  lifetime in SessionManager; reap on crash/boot; a hard concurrent-session cap;
  surface live spend (Phase 6). No path may open a session it can't guarantee to
  close.
- **B. Secrets.** `BROWSERBASE_API_KEY`/`PROJECT_ID` from env in dev, OS keychain
  in a packaged build (`vault.ex`); never logged, never in Sentinel event
  bodies. User-account credentials: prefer human takeover over storage.
- **C. Data-egress posture (the local-first concession).** Browserbase means URLs
  and page content transit a third party — a real departure from BusterClaw's
  "local, no keys" story. It is **opt-in and off by default**; the README/security
  docs must state plainly what leaves the machine and when. This is the honest
  cost of the capability.
- **D. Security & audit.** Every verb is Sentinel-logged; acting verbs are
  restricted-tier; money/credential verbs are pending-confirmation. Reuse
  `policy_engine.ex`, `url_guard.ex`, `api_token.ex` tiers — no new bypasses.
- **E. Failure modes.** Session death, Browserbase downtime, network loss → fall
  back to local sidecar for reads, fail-closed (never fail-open to an
  unconfirmed action) for writes. Surfaced in status, not swallowed.
- **F. Testing.** `Req.Test` stubs for the client + sidecar (the pattern already
  in `browser_test.exs`); one `:browserbase_live` smoke test gated by env so CI
  never spends. Every phase ends `mix precommit` + `bun test` green.

## Open questions (need Luke)

1. **Confirmation UX (Phase 4.3):** where does a spend/submit approval surface
   when the user might be in the terminal, the app, or away — modal, Sentinel
   feed, terminal prompt, push? Blocks Phase 4.
2. **Persistent-context storage (Phase 5.1):** accept cloud-stored logged-in
   sessions for convenience, or hold the line and require takeover login every
   time? A privacy-vs-friction call only you can make.
3. **Live-view placement (Phase 3.1):** native tab (preferred) vs. a dedicated
   Phoenix panel — decide if the framing-header check forces the iframe path.
4. **Default spending cap (Phase 4.2):** the number that auto-denies regardless
   of approval.
5. **Which seller/mailing platforms first (Phase 5):** scopes the recipes and
   the persistent-context work.

## Non-goals (on purpose, revisit only with cause)

- **Stagehand / any embedded automation-LLM.** Decided: primitives only. An
  in-app LLM would need its own key and break the "intelligence is remote"
  design. Revisit only if primitives prove insufficient *and* the principle is
  reconsidered.
- **Replacing the native WKWebView browser.** Browserbase is the cloud-sandbox
  complement to local co-presence, not a substitute. The native browser roadmap
  stands.
- **Autonomous unattended purchasing** (no human in the loop). Not on this
  roadmap at any phase. The confirm gate is the product, not a temporary
  scaffold.
- **A generic multi-provider browser-infra abstraction.** Build for Browserbase;
  don't pre-factor a vendor-neutral adapter for a second provider we don't have.
- **Driving the user's *local* authed session via Browserbase.** That's what
  native co-presence is for; keep the surfaces distinct.

## Sequencing notes

- Phase 0 is strict prerequisite for everything (client + seam + manager).
- Phase 1 before Phase 2: prove the session lifecycle on the *existing* read
  capability before adding verbs — smallest blast radius.
- Phase 2 before Phase 3: the primitives must work headless before we invest in
  showing them; but 3.1's embeddability check is cheap and can be spiked early to
  de-risk the "watch it" promise.
- **Phase 4 gates before any real transaction, full stop.** No Phase 5 workflow
  touches money until Phase 4's confirmation + caps are in and tested.
- Phase 3.3 (human takeover) is a hard dependency of Phase 4/5's
  credential-delegation story — sequence it before 5.1.
- Each phase ends with a dated dev summary and this file's items marked
  **SHIPPED** inline, same convention as `BROWSER_ROADMAP.md`.
