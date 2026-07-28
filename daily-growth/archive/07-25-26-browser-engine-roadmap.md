# Browser Engine Roadmap

**Our own Browserbase, in-process — and a browser that switches into a watchable agent-at-work mode**

> Scoped 2026-07-22 against the shipped shell (`desktop/tauri/src/browser/`, 8
> modules), the co-presence bridge (`BusterClaw.Browser.Bridge`), the flow runner,
> and the accepted WKUIDelegate ceiling.
>
> Decisions locked at scoping time:
> - **Hybrid engine.** WKWebView stays the human browsing surface. A CDP-driven
>   engine we write ourselves backs Agent Mode and headless reads.
> - **The browser changes modes.** Same app surface; it visibly becomes the agent's
>   workspace and the user watches it work.
> - **The agent fills the cart. The human always pays.** No payment credentials in
>   agent custody in this roadmap.
> - **Internal supervision tree, agent-only.** No socket, no external API, a few
>   sessions.
> - **Be the real user.** Real browser build, real profile, real residential IP,
>   human-paced actions. No fingerprint-spoofing arms race.
> - **Engine host (settled 07-22): the user's installed Chromium-family browser**,
>   launched by us with a dedicated profile, CDP over a pipe. Not bundled.

**Status 07-28 — CLOSED, phases 0–7 shipped** (archived as
`07-25-26-browser-engine-roadmap.md`; originally `BROWSER_ENGINE_ROADMAP.md`,
the name ~25 code comments still cite).

**Five items were still open at close and ALL moved to `LEFTOVERS.md`** — the
four unfinished field-test repairs (items 3–6 in the Repairs table below) plus
the deferred mirror input slice. Item 3 is **HIGH and safety-adjacent**: the
`/gp/buy/` payment funnel is gated *by test* but has never been walked in a
real signed-in session, and only the operator can do that. Archiving this
roadmap does not close that; it moves it somewhere it will be seen.

Everything in the Deferred list below was ruled out on the merits, not
postponed.

**Status 07-25 — reopened.** Phases 0–6 shipped 07-24. The first live field test
(Amazon, commerce mode) ran 07-25: **the errand succeeded and four wiring-layer
defects surfaced, one of which fails the payment gate open on Amazon.** See
[Field test 07-25](#field-test-07-25--first-real-run-and-what-it-cost-us) for
the repairs and [Phase 7](#phase-7--the-mirror-agent-mode-inside-the-app) for
the mirror that makes the run watchable without leaving the app.

---

## Outcome

A browser inside Buster Claw that the agent can genuinely operate — navigate,
click, fill, wait, extract, handle popups and dialogs, hold a logged-in session —
where the user watches every route change and every action as it happens, and
where nothing about the session transits a third party's infrastructure.

## How far we take it — and where we stop

Explicit ceiling, because "our own Browserbase" is a phrase that grows:

**We are building:** a local, supervised, few-session browser automation engine
we own end to end; a visible Agent Mode with a full action trajectory; scoped,
frozen-intent task execution; cart-building through checkout handoff.

**We are not building:** a cloud service, multi-tenant anything, an externally
reachable API (deferred, not refused), payment execution, a bot-detection
evasion program, general-purpose RPA, or app-E2E testing (ruled out 07-18 and
still out).

The engine serves *this* agent, on *this* machine, for *this* user. Every
capability that doesn't serve that is scope creep wearing a feature's clothes.

## Two things that are true and constrain everything

**1. The ceiling forced the engine; it wasn't a preference.**
The 07-04 decision to accept wry's `uiDelegate` ownership was correct for a
browsing app — replacing it risks breaking `<input type=file>` uploads and still
can't produce a real popup. But `FIRST_LOOK_CRITICAL_REVIEW.md` records the
price: `window.open` returns null, so Stripe and Plaid checkout popups silently
fail, and `window.confirm()` is a no-op. That means the *human* can't complete a
checkout in the in-app tab either. Agent Mode isn't backed by a second engine to
be clever; it's backed by one because the first cannot do the job.

**2. "Private info stays in the app" needs one honest qualifier.**
The session — cookies, credentials, 2FA, cart, card entry — never leaves the
machine, and CDP traffic is localhost-only. That claim is defensible and it is
the real differentiator against Browserbase, where your logged-in session runs on
someone else's box.

But the agent reasoning over a page sends **page content** to Claude or Codex,
because that's where the model runs. So the true claim is *"we never route your
browsing session through a third-party browser cloud"* — not *"nothing leaves
your machine."* Marketing the second version is a liability we'd be writing
ourselves. Say the first, precisely, and make the trajectory view show exactly
what content was read.

## Three surfaces

| Surface | Engine | Purpose | Can touch accounts? |
|---|---|---|---|
| **Human tabs** | WKWebView | Ordinary browsing in the app. Existing co-presence read/drive via `Bridge`. | User's own actions only |
| **Agent Mode** | CDP, **headful and visible** | Where the agent works and the user watches. Full popup/dialog/checkout capability. | Yes — within frozen scope |
| **Headless pool** | CDP, no window | Background public reads, fetch upgrades, saved site checks. | No |

**Agent Mode carries its own browser profile, and that is the security model, not
a compromise.** The user deliberately signs into the accounts the agent is
allowed to reach. "What can the agent get to?" becomes a question with a literal
answer — the contents of one profile directory — instead of an inference about
prompt behavior. It also sidesteps the unwinnable problem of sharing a cookie jar
between WKWebView and Chrome.

**Engine host — DECIDED 2026-07-22: the user's installed Chromium-family
browser, launched by us, with a dedicated `--user-data-dir`.** Not a bundled
Chromium. The distribution evidence is lopsided:

- **Size.** The app is 67MB and the DMG 27MB today. A Chromium is ~300–400MB
  unpacked per arch — a roughly 5× increase in both, riding *every* update.
  `DISTRIBUTION_ROADMAP.md` already rejected an 88MB item for precisely this
  reason ("it must never travel on the update channel"). Chromium is larger than
  the thing that rule was written about.
- **Signing, which matters more than size.** Notarization already requires 25
  Mach-O objects signed individually, inside-out, never `--deep` — and Tauri does
  not sign `bundle.resources`, so the naïve path "succeeds, runs fine on your
  machine, and then notarization comes back rejected 25 times over." A bundled
  Chromium drops ~20 more Mach-O objects (framework, Renderer/GPU/Plugin helpers,
  SwiftShader dylibs) into that exact trap, each needing V8's entitlement set —
  `allow-jit`, `allow-unsigned-executable-memory`,
  `disable-library-validation` — which is a *different* set from the BEAM's. Per
  the same doc, entitlements do not inherit across process boundaries, so getting
  it wrong fails nowhere in our pipeline and everywhere in the user's.
- **Order of operations.** The 25-object pass has not shipped once yet. Making it
  a 45-object pass with two distinct entitlement profiles before it has ever
  worked is the wrong sequence.
- **Fingerprint.** A real Chrome build beats Chrome-for-Testing on exactly the
  commerce sites this roadmap targets, which is what "be the real user" asked
  for.

**Transport: `--remote-debugging-pipe`, never `--remote-debugging-port`.**
A loopback-bound debug port is still reachable by *any* local process, and what
sits behind it is a browser holding the user's logged-in sessions — a
session-theft hole, not a theoretical one. Because we launch the browser
ourselves (which the dedicated profile requires anyway), we own the pipe's file
descriptors and no socket exists at all. This supersedes the earlier
"debug port bound to loopback" framing in Phase 0.

**Detection order:** Chrome → Brave → Edge → Chromium. All are Chromium-family
and speak the same CDP surface, which widens coverage well past Chrome alone —
and this user base skews heavily toward having at least one.

**Do not pass `--enable-automation`.** It sets the automation infobar and trips
detection for no benefit; a CDP connection alone does not set
`navigator.webdriver`.

**Accepted cost:** a prerequisite. Mitigated by loudness, not by fallback — no
Chromium found means Agent Mode is visibly unavailable with install guidance,
per the product contract. That is survivable in a way Browserbase's silent
degrade was not.

**Revisit trigger:** flip to bundled Chromium if the "no Chromium found" rate
turns out to be material in real use, or if CDP surface drift from Chrome's
auto-updates breaks us twice. Both are observable; neither is speculative enough
to pay 5× distribution weight against today.

**Download-on-first-use was considered and rejected.** It trades bundle weight
for a `com.apple.quarantine` fight over an executable we fetched at runtime —
strip-quarantine-then-exec is both fragile and the exact shape of behavior that
gets an app flagged.

## Product contract

| Situation | Required behavior |
|---|---|
| Engine binary absent | Agent Mode is visibly unavailable with install guidance. Never a silent fallback to a weaker path. |
| Agent Mode entered | The frame changes unmistakably — hazard accent border, mode banner, "the agent has the wheel." |
| Any moment during a task | A always-available Stop. One key, one button. Halts before the next action, not after. |
| Agent needs a human (2FA, CAPTCHA, checkout) | Mode flips to "your turn," the exact field is highlighted, and the agent stops acting entirely. |
| Human finishes the handoff | Explicit resume. The agent never auto-resumes off a page change. |
| Page content tries to redirect the task | Refused. Intent is frozen at task start; page text can never expand it. |
| Navigation outside frozen scope | Halt and ask. Not a warning that scrolls past. |
| Fill into a password/card/secret field | Recorded as "filled ⟨field⟩ (redacted)". The value is never logged, never screenshotted, never sent to the model. |
| Task completes | Full trajectory persists — every route, action, and screenshot — and is replayable. |
| Reaching a payment page | The agent stops. Always. It does not read card fields and does not click Pay. |

---

## Phase 0 — Prove the engine in the packaged app — **DEV-PROVEN 07-22**

This is first because of our own history, not out of caution. Browserbase was
2158 lines that never ran for a real user because its driver depended on
something prod never bundled.

Launch the engine, connect our CDP client over the pipe, navigate, read the DOM
back — **from the signed, packaged app, on both architectures.** Reuse the
packaged-app smoke harness from the shell rebuild (07-22).

Specifically prove: process launch survives hardened runtime and the packaged
app's entitlements; **the CDP pipe works and no debug socket is opened at all**;
profile directory creation works under the packaged app's file access; a
Chromium-family browser is detected across the Chrome/Brave/Edge/Chromium order;
teardown leaves no orphan process.

**Status:** `BrowserControl.probe/1` proves the full path (detect → launch →
getVersion → createTarget → attach → navigate → loadEventFired → read title →
Browser.close → confirm OS exit). Exposed as the `browser_control_probe` command
and wired into `scripts/smoke_desktop.sh`. Green in dev against real Chrome, and
the tagged live suite (`--include browser_engine`) asserts `lsof` sees **no
listening socket** while the engine runs. Packaged x86_64 smoke: run via
`smoke_desktop.sh`. **arm64 packaged run is pending the Apple Silicon build
machine** (same hardware gate as `DISTRIBUTION_ROADMAP.md`) — the one remaining
"both architectures" item, and the only thing between here and Phase 0 fully
closed.

If Phase 0 doesn't pass, the roadmap stops here and we say so. Everything below
assumes it did.

## Phase 1 — Our CDP client — **SHIPPED 07-22**

`BusterClaw.BrowserControl.CDP` — connect, command, subscribe, dispatch.

CDP is JSON documents, `{id, method, params}` out and `{id, result}` /
`{method, params}` events back. Owning it is the whole point — every byte on the
wire is ours, which is what makes the privacy claim inspectable rather than
promised. **Transport is the pipe, not a WebSocket** (settled with the engine
host, 07-22): fd3/fd4 NUL-delimited frames, so there is no socket to reach.

"No outside library" means **no Playwright, Puppeteer, or Selenium** — no
third-party automation framework interposing on the session. The line is: nobody
else's code decides what our browser does.

Domains we actually need, and no more: `Page`, `Runtime`, `DOM`, `Input`,
`Network` (read-only for the trajectory), `Target`, `Browser`. Resist enabling
domains we don't consume — every enabled domain is event volume and surface.

Launch flags matter for the privacy claim: disable background networking, sync,
component update, default-browser checks, and metrics. The engine should phone
home to nobody, and that's a flag list we can point at.

**Status:** landed as four modules — `Detect` (browser discovery + override),
`Launch` (pure argv, the fd-wiring shim, pinned hygiene flags),
`Frames` (pure NUL framing), and `CDP` (the GenServer: id correlation, flat-mode
`sessionId` scoping, event subscription, graceful-then-armed stop that reaps the
real engine pid). 24 always-on tests + 2 live-engine tests, all green.

## Phase 2 — Session pool — **SHIPPED 07-22**

A `DynamicSupervisor` over session processes. Each session owns one target, one
profile scope, a lease, and an idle reaper. Default a small N — this is
agent-only, and a few sessions is the chosen shape.

No socket. No external API. The command surface reaches sessions through the
supervision tree, which keeps "private info never leaves" true by construction
rather than by policy.

Crash semantics: a dead engine process must fail sessions loudly and reap the OS
process. A leaked headless Chrome is the kind of bug users find via their fan.

**Status:** three modules, wired into the app tree (both free at rest — no
engine launches until the first checkout):

- `Session` (`restart: :temporary`) — one `CDP` engine + one flat-attached
  target + one ephemeral profile. Owns its idle reaper (armed while idle,
  cancelled while leased); subscribes to its engine and stops **loudly** the
  instant the engine exits; reaps the engine on every terminate path.
  `command/3` auto-scopes the `sessionId`; `navigate/2` awaits the load event.
- `SessionSupervisor` — one-for-one `DynamicSupervisor`; sessions never
  auto-respawn (a failed headless read shouldn't silently retry).
- `Pool` — the single door: hard cap (`{:error, :pool_exhausted}`), lazy start +
  reuse, leases bound to the caller (owner death auto-releases), session death
  purged from every structure so a leak can't masquerade as capacity, and a loud
  `{:error, :no_browser}` — never a silent degrade. `with_session/2` brackets
  checkout/checkin across raises.

11 stub-driven pool tests (cap, reuse, owner-death, session-death, error
passthrough — no browser) + 3 live-engine tests (navigate/evaluate, reuse,
idle-reap, and **kill the OS engine → session dies → pool frees the slot**).
35 BrowserControl tests green.

## Phase 3 — Frozen scope and injection defense — **SHIPPED 07-22**

**Before the agent can act broadly, not after.** This property is cheap to design
in and effectively impossible to retrofit.

The agent reads untrusted web content and can click and type in logged-in
sessions. A page that says "ignore your instructions and go transfer money" is
the entire threat model, and it costs an attacker nothing to try.

- **Task intent and its allowlisted domains are frozen when the task starts.**
  Page content can never widen them.
- **Page text enters as data, structurally separated from instructions.** Never
  concatenated into the instruction channel.
- **Navigation outside frozen scope halts and asks.** A domain not on the list is
  a stop, not a log line.
- **Payment pages are a hard stop** regardless of scope.
- Sentinel already tags `untrusted_ingest`; extend it so every action carries the
  origin that motivated it, which makes an injected action visible in the
  trajectory as an action with no legitimate cause.

**Status:** `BusterClaw.BrowserControl.Scope` — an immutable value minted once
from `intent` + an allowlist, with **no mutator** (no `add_domain`, no `widen`),
so page content cannot expand it because there is no function through which it
could. `authorize/2` is **pure** — page text is never a parameter, which is what
makes "page content can't widen scope" true by construction; a test asserts the
API exposes no widening function so a future one can't slip in unreviewed. The
gate fires in order: malformed URL → payment page (hard stop *regardless of
allowlist* — the Phase 5 handoff) → domain off the frozen allowlist (subdomains
in, suffix lookalikes like `example.com.evil.com` out) → allow, tagged with the
scope's origin for the trajectory. `guard/2` records a **critical**
`:security_block` Sentinel event on every halt, so an injected action shows up as
an action with no legitimate cause. Made load-bearing via
`BrowserControl.navigate/3`, which guards before the URL reaches the engine — a
live test confirms an off-scope/payment URL never changes the session's page.
SSRF stays with `URLGuard` at the network boundary; this layer is pure policy,
no DNS. 31 always-on tests + 1 live gate test.

**Deferred to Phase 4 (the action loop):** the structural separation of page
text from instructions is a prompt-construction contract the agent loop enforces
when it exists; Phase 3 provides the gate it will call.

## Phase 3.5 — Model egress: earning the consent — **CORE SHIPPED 07-22**

Sits here because its enforcement point and Phase 4's "what the model saw" view
are the same plumbing, and because both must exist before the agent reads
anything that matters.

**Status — the pure, enforceable core landed** (four modules under
`BrowserControl.Egress`, 30 always-on tests):

- **`SecretRef`** (part 1) — the model emits `$secret.<name>`; `resolve/2` swaps
  it for the real value in the executor, `mask/1` renders the log-safe
  `⟨secret:name⟩`. The value passes through the executor, never the reasoner or
  the trajectory; an unknown name fails the whole resolution rather than
  half-filling a form.
- **`Redactor`** (part 2) — typed placeholders (`⟨redacted:card⟩`, not a
  collapsed `[redacted]`) for Luhn-valid cards, SSNs, IBANs, and
  credential-prefixed tokens, with per-type counts. Deliberately parallel to
  Sentinel's audit masker — different consumer, so not shared.
- **`Policy`** (part 4) — per-host `:full | :structure_only | :never`; operator
  overrides win most-specific (stricter breaks ties), banking/health/gov
  sensitive by default, unknown → `:full`. Redaction runs at every level.
- **`Egress`** (parts 3 + 5) — `prepare/3` takes the structure-first `Snapshot`,
  applies the level, redacts at capture, and returns the payload plus a
  falsifiable **`Report`** (bytes in/out, redaction counts, level, secrets
  resolved). `summarize/1` folds a run into the *"17 steps, 41KB, 6 redacted, 3
  resolved"* line.

**Deferred to Phase 4:** the real DOM→`Snapshot` extractor (needs the live page),
the trajectory's "what the model saw" rendering (parts 3/5's UI), and wiring the
egress level into `policy.md`'s literal grammar. Part 6 (retention/training copy)
is a verification task, not code. The `Snapshot`/`Report` contracts are fixed
here so Phase 4 fills them rather than redesigning them.

The problem this solves is the qualifier from the top of this document: the
session never leaves the machine, but page content the agent reasons over goes to
Claude or Codex. Users have no way to evaluate a privacy promise. So we don't
make one — we send less, make secrets structurally unsendable, and show them the
exact bytes that left.

**1. Never send the secret — send a reference.** The highest-leverage mitigation
and the most buildable. The model never emits a value; it emits
`fill(field, $secret.shipping_address)` and Buster Claw resolves the reference
locally at execution time. Credentials, addresses, phone numbers, and card data
pass through the **executor**, never the **reasoner**. The model can drive a
checkout it is constitutionally incapable of reading. The same inversion works on
reads: `balance: ⟨redacted:currency⟩` tells the model a balance exists without
telling it the number, and any comparison happens locally.

**2. Redact at capture, not at send.** Field-level — `type=password`,
`autocomplete="cc-number" / "cc-csc" / "one-time-code"` — plus text-node scanning
for Luhn-valid digit runs, SSN shapes, and IBANs. Substitute **typed**
placeholders so page structure survives and the model still knows a card field is
present. The enforcement point must be the extraction layer, before text ever
enters a prompt buffer. A redaction pass applied on the way out is one bug away
from not running, which is the same reason Phase 4 redacts screenshots at capture.

**3. Send a fraction of the page.** Most steps need only: what is interactive
here, what is the heading, did my last action work. That is an
accessibility-tree-shaped summary, not 200KB of DOM. `find_elements` is already
most of the way there and the flow runner's 20k cap is the right instinct.
Structure-first extraction cuts egress by an order of magnitude and improves
agent accuracy as a side effect.

**4. Per-domain egress policy, defaulting conservative.** Not one blanket
consent: `full` / `structure-only` / `never`, per site, with banking, health, and
government sensitive by default. `policy.md` already parses allow/deny rules with
most-specific-pattern-wins — an egress dimension extends that grammar instead of
introducing a second permission mechanism.

**5. Show them the payload.** Phase 4's trajectory rail gets a per-step "what the
model saw" view: the literal post-redaction bytes, inspectable. Plus a run
summary — *17 steps, 41KB sent to Claude, 6 fields redacted, 3 secrets resolved
locally.* This earns more consent than everything above it combined, because it
is falsifiable rather than promised, and it turns users into redaction-bug
reporters.

**6. Point at the structural fact, not a promise.** BYO-Claude means there is no
Buster Claw server in the path — the data relationship is directly between the
user and a model provider they already have a relationship with. That is an
architectural property rather than a policy claim. **Before any of it goes in
user-facing copy, confirm the current retention and training terms for the
specific tier Claude Code runs under**; consumer and commercial terms differ and
this document is not the place to guess.

**The residual, stated plainly.** The model must see something to be useful, so
which sites the agent visited and roughly what it did there remains inferable
from what is sent, and prompt caching may hold content in a provider cache for a
TTL. That cannot be fully closed while reasoning happens remotely. The only true
fix is a local model for the element-selection step — named here as the ceiling,
deliberately not built now.

**Default posture:** structure and task-relevant text go; identifiers and secrets
never do; the user can loosen it per site and can always see what left.

## Phase 4 — Agent Mode: the watchable surface — **BRAIN SHIPPED 07-22**

The mode switch is the product. A user who can watch will trust it; a user who
can't, won't, and shouldn't.

- **Mode state machine:** `idle → agent_working → awaiting_human → agent_working
  → done`, with the frame changing at every transition. Use the hazard accent
  (`#FF4D1C`) — this is precisely the signal that identity was designed for.
- **The trajectory rail** beside the viewport: each step as it happens —
  navigation with URL and the reason for it, interaction with a redacted target
  descriptor, extraction with a size, timestamp, thumbnail. The chat harness's
  rail concept is the right shape.
- **Scrub-back.** Replay the run. Both a trust feature and the debugging tool
  we'll want the first time a flow misbehaves.
- **Take the wheel.** Always available, halts before the next action.
- **Redaction is enforced at capture**, not at render. A screenshot of a filled
  card field must never exist on disk, because a redaction applied at display
  time is one bug away from not being applied.

**Status — the orchestration brain landed** (three modules, 22 always-on tests +
1 live). The UI (headful window + rail) is the deferred slice and renders this;
it adds no authority of its own.

- **`Mode`** — the pure state machine. `agent_working` is the *only* state that
  permits acting, so take-the-wheel and stop actually stop the agent by
  construction; terminal states (`done/stopped/halted`) take no transition; every
  unlisted pair is an explicit error.
- **`Trajectory`** — pure, append-only, replayable. The single
  **redaction-at-capture** point: a fill's secret is masked when the step is
  *formed*, so a value that was never stored cannot leak no matter what renders
  it. Each step carries its motivating `Scope` origin — a step that can't be tied
  to the intent is what an injected action looks like on scrub-back. `summary/1`
  folds in the `Egress` roll-up.
- **`AgentMode`** (GenServer) — ties a leased `Session` + frozen `Scope` +
  `Egress` + `Trajectory`, serializes actions, and broadcasts every transition so
  the rail is a projection, not a second source of truth. Enforced here, not
  hoped for: only `agent_working` acts; **stop halts before the next action**
  (the next `act` sees a non-acting mode and does nothing); the scope gate halts
  the run and records the halt with its origin; **secrets resolve in the executor
  and the trajectory stores only `⟨secret:name⟩`** — proven by a test where the
  stub browser receives the resolved card while the trajectory never sees the
  digits.

**Deferred (the UI slice):** the headful Tauri window, the LiveView trajectory
rail with the hazard-accent mode banner, scrub-back rendering, and pixel-layer
screenshot redaction at capture. All of it consumes `subscribe/1` +
`trajectory/1`; the contracts are fixed here.

## Phase 5 — Commerce: cart in, human pays

- Frozen merchant allowlist — the "trusted websites" boundary, and the same
  mechanism as Phase 3's scope.
- The agent searches, compares, and builds the cart in Agent Mode, in view.
- **At the payment step it hands off.** Mode flips to `awaiting_human`, the total
  and full cart are shown, and the agent stops acting.
- **The handoff must land somewhere checkout actually works** — Agent Mode's CDP
  surface, with real popups. Handing off into the WKWebView tab would drop the
  user onto the exact broken path that motivated the hybrid.
- After the human confirms, capture the confirmation page and finish the run.
  The confirmation receipt stays attached to that interaction rather than
  creating a separate financial ledger.

Honest note on the chosen model: cart-building with human payment is a real V1
and it removes the entire payment-credential threat surface. It is not
"autonomous purchasing," and the roadmap shouldn't imply it is. If that changes
later, virtual single-use cards with hard limits are the right primitive —
bounded loss by construction — not a stored real card.

## Phase 6 — Migrate the existing surface

Move `FlowRunner` (25-step cap, 7 actions), saved site checks, and the
`Browser.fetch` live-render upgrade onto the new engine where it's better, and
leave them on WKWebView co-presence where that's genuinely the right surface —
reading the tab the user is already looking at is a feature, not a limitation.

Expand the action vocabulary only where a real flow needed it: `select`, `hover`,
`scroll`, `upload`, `dialog`, `wait_for_navigation`.

---

## Field test 07-25 — first real run, and what it cost us

First exercise of the Phase 0–6 stack against a live, adversarial, logged-in
commercial site instead of a fixture. Full report:
[`07-25-26-browser-control-field-test.md`](07-25-26-browser-control-field-test.md)
(archived alongside this file; originally `BROWSER_CONTROL_FIELD_TEST_07-25.md`).

**The errand succeeded.** Amazon, commerce mode, scope `["amazon.com"]`: the
agent searched, compared, selected a size variant, added two items to the
operator's real cart, froze a cart matching Amazon's subtotal to the cent, and
handed off. Operator paid. 66 steps, 65 ok, 89.8 KB egressed.

The pure layers — `Scope`, `Trajectory`, `Cart`, `Egress` — behaved exactly as
designed. **Every defect was at the wiring layer**: capabilities that exist, are
tested, and are correct in isolation but are not connected to the surface the
agent actually calls. That is a specific and fixable class of failure, and it is
the predictable cost of shipping six phases without a live walk.

Two things are worth carrying forward as judgments, not just tasks:

**The payment gate failed open on the largest retailer on the internet.** Not
subtly — `@payment_path_re` has no `buy` token and anchors to whole path
segments, so Amazon's entire `/gp/buy/` funnel and its literal `payselect` page
both sail through. The gate that exists specifically to guarantee "the agent
cannot act on a payment page" did nothing. Phase 3's own note says this gate is
"intentionally conservative — over-halting is safe; under-halting is the failure
that matters." It under-halted. The lesson is that the test table used idealized
paths (`/checkout/`), and a gate tested only against its own idea of the world
is not tested.

**The run nearly bought the wrong product, and no gate would have caught it.**
The size selector defaulted to 54"; correcting it via `click text: "45 inches"`
matched a *customer review's variant byline* and navigated to the reviews page.
Had it matched a different valid swatch instead, the wrong size would have gone
into the cart silently, and every downstream receipt would have been perfectly
accurate about the wrong thing. It was caught by verifying against the cart line
— which renders the resolved variant — not by anything in the stack.

**And the thing that actually saved the run was that a human could see it.** The
report's own conclusion: the single most effective safety property in this run
was not a gate, it was that the run is headful and supervised. That is the
argument for Phase 7.

### Repairs

| # | Item | Where | Size | Priority | Status |
|---|---|---|---|---|---|
| 1 | Add `buy` to the token list; substring-within-segment matching for the `pay*` family; test table of **real** checkout URLs (Amazon `/gp/buy/`, Shopify `/checkouts/`, Stripe, PayPal) | `scope.ex:56` | S | **High** | **DONE 07-25** |
| 2 | `text` targeting errors on ambiguous multi-match instead of silently taking the first | `page.ex:245` | S | **High** | **DONE 07-25** |
| 3 | Walk a live checkout and confirm the gate fires post-fix | — | S | **High** | **PARTIAL 07-25** |
| 4 | Give `find_elements` a real `selector` parameter | `page.ex:61` | S | Low | open |
| 5 | Keychain-backed `secret_resolver` wired into `agent_run_start` | `commands/agent_runs.ex` | M | Medium | open |
| 6 | Per-host egress levels with a config surface; `amazon.com` → `:structure_only` | `egress.ex:51` | M | Low | open |
| 7 | **Re-check the landed URL after navigation** — see Finding 6 below | `browser_control.ex:35` | M | **High** | **DONE 07-25** |

### What landed, 07-25

**1 — the gate.** `@payment_path_re` is gone, replaced by segment-wise matching
over two lists: `@payment_fragments` (segment *contains* — `checkout`, `pay`,
`billing`, `purchase`, which is what finally sees `payselect`) and
`@payment_words` (segment *equals* — `buy`, `place-order`, …, so `buy` catches
Amazon's funnel without halting `/buyers-guide`). Four payment hosts added.
Test table is real URLs only, with a stated rule: *if you cannot name where a
path came from, it does not belong in that test.*

**2 — text targeting.** Two-tier resolution: exact match first, substring
second, refuse when the winning tier has more than one member
(`{:error, {:ambiguous_text, count}}`). Exact-first is what makes the field
test's own case *resolve correctly* rather than merely fail safely — the swatch
reads exactly `45 inches`, the review byline only contains it. The refusal
carries the count and deliberately **not** the labels: labels are page content
and an error path is not egress-accounted, so shipping them would be untracked
egress that criterion 12 could not reconcile. There is a test asserting their
absence, so a later "helpful" patch fails loudly.

**3 — the walk, and exactly how far it got.** Two new test files run the *real*
gate rather than a stand-in: `commerce_payment_gate_test.exs` (real
`BrowserControl.navigate/3`, real Sentinel record, and a commerce run that hands
off at Amazon checkout with a cent-exact frozen cart) and
`page_targeting_live_test.exs` (six tests against a real Chromium on the exact
DOM shape that defeated targeting — the stub suite could only assert the JS we
*generate*, which is how the defect survived in the first place).

Then a live anonymous probe: throwaway Chrome profile, no account, no purchase —
search → product → add to cart → read what the real checkout control points at.
It is **`https://www.amazon.com/checkout/entry/cart`**, and the gate halts it.

**Be precise about what that does and does not prove.** `/checkout/entry/cart`
would have been caught by the *old* regex too — `checkout` is a whole segment
there. It was never the gap. The gap is the `/gp/buy/` funnel, which is only
reachable from a **logged-in** session, and the field-test agent only reached it
by constructing the URL itself (hence its "Page Not Found"). So: the live entry
point is confirmed gated, and the logged-in funnel is confirmed gated *by test*
but still not *by walk*. Closing that last mile needs the operator's own signed-in
session and is the one remaining piece of item 3.

### Finding 6 — the gate authorizes the requested URL, not the landed one — **HIGH**

**Where:** `lib/buster_claw/browser_control.ex:35`

Surfaced while walking item 3. `navigate/3` runs `Scope.guard` on the URL it is
*asked* for, then calls `Session.navigate`, which waits for the load event — and
nothing re-checks where the browser actually ended up. A 302 therefore carries a
run from an allowed URL onto a payment page or an off-scope host with the mode
still `agent_working`, which is the only state that permits acting.

This is Finding 1's failure mode reached by a different road, and it is the more
general one: Finding 1 was a bad pattern, this is a missing check.

**Second-order consequence, and it is not small.** `AgentMode` sets
`current_host` from the pre-navigation origin (`agent_mode.ex:329`) and
`Egress.prepare/2` selects the redaction level from that host
(`agent_mode.ex:419`). After a cross-host redirect, page content is prepared at
the *original* host's level — so a domain the operator set to `:structure_only`
can be read at `:full` by being redirected to.

**FIXED 07-25.** `navigate/3` became `navigate/4` and the gate now fires twice:
once on the requested URL before the engine sees it, once on the landed URL
after the load event. The returned origin always describes the **landing**, so
`current_host` — and therefore the egress level — tracks reality. A redirect
adds `:redirected_from` to the origin or halt meta, and the trajectory renders
it as `navigate A → B (redirect)` rather than as an ordinary visit, because on
scrub-back "went somewhere I was not sent" is the signature of a hijacked
navigation and must not read like a normal step.

On the open question — what a failed re-check *does* — the answer turned out to
be that the mode machine already had it right. A halt flips the mode, and
`agent_working` is the only state that permits acting, so the agent cannot read,
click, or navigate from the page it was redirected onto. Nothing needed to
navigate away; the run simply loses the wheel. Payment redirects on a commerce
run take the normal handoff.

**Fails closed:** an unreadable landing is `{:halt, :unverified_location, meta}`.
Not knowing where the browser is, is not a reason to let the agent act there.

**Known limit, written into the docstring:** the check runs once, at the load
event. A JS redirect fired afterwards (`setTimeout`, meta-refresh) is not
caught; catching those needs CDP frame-navigation events rather than a
point-in-time read.

**Two things fell out of the fix.**

*`Session.info/1` was lying the same way.* It reported the URL navigation was
*requested* for, while calling it "current url (best-effort)". Same defect, one
layer down. `Session` now stores the landed URL. Caught by the live redirect
test asserting the origin agreed with the session — it did not.

*The `session_mod` contract widened.* It now stands in for `Session` proper —
`navigate/2` **and** `command/3` — because the landing read is threaded through
it. A stub implementing only the command half fails on the first navigation, so
this is documented on `AgentMode.start_link/1`.

**And `guarded_navigate_test` stopped re-implementing the thing it tests.** It
previously copied the guard/navigate composition into the test file and asserted
against the copy — the same "correct in isolation, not wired to the surface that
runs" shape as the original field-test defects. With `session_mod` injectable it
now drives the real function.

**Two corrections to the report's recommendations, made deliberately:**

- **Finding 2 is already closed the right way.** `Commerce.confirm_purchase/2`
  is unreachable from `/api/run`, and it should stay that way. The report
  recommends exposing `agent_run_confirm_purchase`; we are not going to. A
  `:restricted` command is runnable by `agent_untrusted` — an agent that has
  been reading Amazon page content — which would let the agent attest that a
  purchase happened. Confirming is the *human's* act. The LiveView button is the
  correct and complete surface. If it is ever put on the API it must be
  `gated: true`.
- **Ordering.** Item 2 is promoted to High. The report rates it Medium, but a
  silent wrong-variant purchase backed by a cent-exact cart is the worst failure
  this system can produce: every receipt agrees, and the ledger is confidently
  wrong.

---

## Phase 7 — The mirror: Agent Mode inside the app — **VIEW SHIPPED 07-25**

**Status.** The watchable half is built, walked end to end against a real
headful run, and green (`Screencast`, `AgentViewController`, the browse-tab
panel, 6 live engine tests). **Input forwarding is deliberately NOT shipped** —
see "Why the mirror is view-only" below; it is the next slice, and it needs a
state-machine change first.

### What the walk found that the tests could not

Three defects survived a green unit suite and only appeared when the whole path
ran for real. Recording them because the pattern is now familiar:

1. **A static page produces no frames at all.** A screencast emits on *new
   compositor frames*, so a page that has finished painting sends nothing — and
   the agent usually pauses on a settled page. The mirror opened black and
   stayed black, which reads as a broken feature rather than a still page. Fixed
   with a `Page.captureScreenshot` seed at startup, which renders on demand
   instead of waiting for the compositor.
2. **The caster was a `:permanent` child.** It stops normally whenever the last
   watcher leaves; the supervisor read that as failure and restarted it, which
   stopped again for the same reason. The loop tripped max_restarts, took the
   DynamicSupervisor down, and cascaded into the application supervisor — *the
   whole app died because somebody closed a tab*. Now `:temporary`, like
   `Session`. This one failed 30 unrelated tests as collateral, which is how it
   was caught.
3. **A missing supervisor surfaced as a 500.** Found by driving a dev node that
   predated the tree change (code reload recompiles modules; it never adds
   supervision children). Now a legible `:screencast_unavailable`.

Also worth writing down because it cost real time: `URI.encode/1` does not
escape `#`, so a `data:text/html,` fixture silently truncates at the first CSS
colour. The page arrives without its script, paints once, and the symptom is
indistinguishable from "screencast only ever sends one frame". Test fixtures now
use `data:text/html;base64,`.

### Why the mirror is view-only

The roadmap's rule was: input refused while `agent_working`, read-only at
`awaiting_human` on a payment page. Implementing that revealed the state machine
cannot express it. `awaiting_human` is reached by **two** routes —
`Mode.transition(:agent_working, :take_wheel)` and
`(:agent_working, :need_human)` — and the resulting state is identical. A
deliberate take-the-wheel and a payment handoff are indistinguishable, so
"allow input when the human took the wheel, never when they are paying" is not
expressible today.

Given the choice between shipping input with a rule that cannot be enforced, and
shipping the watchable mirror without input, the second is obviously right: the
field test's whole finding was that *watching* is what made the run safe. A
"Real window" button (`Page.bringToFront`) gives take-the-wheel a real
destination in the meantime.

**Prerequisite for the input slice:** carry an `awaiting_reason`
(`:take_wheel | :payment`) on the run so the payment case is distinguishable by
construction rather than by inspecting the URL at input time.

---

## Phase 7 — design notes

**The problem, stated from the field test:** the agent works in a Chromium window
and the user works in Buster Claw, so watching the agent means alt-tabbing. The
supervision that saved this run was *available* but not *practical*. Phase 4
promised "the user watches it work"; today they watch it work somewhere else.

### What we are not building, and why

**We are not embedding the Chromium window itself.** macOS provides no supported
cross-process view reparenting — there is no `SetParent` equivalent, and an
external process's `NSWindow` cannot become a subview of ours. The approaches
that get close (Accessibility-API window shoving, private `_NSSetWindowParent`)
produce a window that *floats above* ours rather than living inside it: it will
not clip to the pane, it loses z-order the moment the user clicks our app, it
does not follow Spaces, and it is a notarization and robustness liability. The
Tauri shell does real embedding for WKWebViews (`browser/webviews.rs`); an
external browser process is a different category of thing. Ruled out on the
merits, recorded here so it is not re-proposed.

### What we are building

**A live mirror driven by CDP screencast.** `Page.startScreencast` makes the
engine push JPEG frames of the page viewport as `Page.screencastFrame` events —
over the pipe we already own, through the `CDP` GenServer that already fans
events out to subscribers. The mirror is another subscriber. This is the same
mechanism behind Browserbase's live view and Playwright's inspector, and it
requires no new transport, no new process, and no new trust boundary.

| Piece | Approach |
|---|---|
| **Capture** | `BrowserControl.Screencast`, one per run. `Page.startScreencast` (jpeg, q≈60, `maxWidth`/`maxHeight` from the pane). **Ack every frame** with `Page.screencastFrameAck` — the engine throttles to a stall without it. Holds the latest frame only; no buffering. |
| **Transport** | `GET /browser/agent-view/:run_id`, `multipart/x-mixed-replace`, chunked from Bandit, rendered as a plain `<img>`. CSP already permits it (`img-src 'self'`). No JS decode path, no base64 inflation. |
| **Rail** | The existing `browse_live` Agent Mode panel gains the viewport beside the trajectory. The rail stays a projection of `subscribe/1` — the mirror adds no authority. |
| **Input** | *Deferred to the next slice* — hook maps client coords → viewport coords via the screencast metadata scale, forwards `Input.dispatchMouseEvent` / `dispatchKeyEvent`. Blocked on `awaiting_reason`; see above. |
| **Real window** | Run stays headful but is **stashed off-screen** at start, so it never pops up over the app. "Real window" restores its position and focuses it. **Shipped.** |

**On "make Chrome appear inside our browser."** The mirror is the answer to
that, and it is as close as the platform allows: the page appears inside the
app, the window does not. What the 07-25 pass added is that the window is also
pushed *out of the way* — `stash_window/2` at run start, `reveal_window/2`
behind the "Real window" control.

Two measured constraints, both recorded in `WindowPlacementLiveTest` because
both are easy to "tidy up" back into a broken state:

- **Minimizing does not work.** A minimized window stops compositing on macOS,
  so `Page.screencastFrame` dries up after one frame and the mirror freezes.
  Off-screen keeps rendering.
- **macOS clamps window positions** to keep a window reachable, so a requested
  `left: -32000` lands near `-1240` for a 1280-wide window. A ~40px sliver stays
  visible at the screen edge. Out of the way, not invisible — and there is no
  way to close that last gap without giving up the live view.

**The transport decision is load-bearing.** Do not push base64 frames through
`push_event` into a canvas: at 1280×900 / q60 / 15fps that is roughly 0.5–1 MB/s
of JSON contending with every other diff on the LiveView channel. MJPEG costs
nothing on loopback and the webview decodes natively.

**One change falls out of reading the code.** `CDP.handle_frame/2` broadcast
every event to every subscriber, so a running screencast would have pushed
~15 × 60 KB messages per second into `Session`'s mailbox for nothing.
`CDP.subscribe/2` now takes a `:methods` filter and `Session` asks only for
`Page.loadEventFired`. **Shipped** — it was a prerequisite, not a cleanup.

### Rules this phase must not break

- **Input forwarding is gated on mode.** Refuse while `agent_working`. The
  existing invariant is "only `agent_working` acts"; the mirror's inverse must be
  "the human only acts when the agent isn't," or take-the-wheel stops meaning
  anything.
- **No payment credential through the mirror. Ever.** At `awaiting_human` the
  mirror goes read-only and the real Chromium window comes forward for the human
  to pay in. Typing a card into the mirrored view would route the PAN through
  `Input.dispatchKeyEvent` → the pipe → the BEAM, and destroy the cleanest claim
  in `commerce.ex`: *no payment credential ever passes through the agent*. This
  is a hard constraint on the design, not a preference about UX.
- **The mirror is a mirror, not a replacement.** It shows the page viewport
  only: no tab bar, no basic-auth dialog, no file picker, no permission prompt,
  no native `<select>` popup. Those are OS widgets outside the compositor. The
  escape hatch to the real window is part of the feature, not an admission of
  failure.
- **Headless-plus-mirror is the wrong trade.** One window is nicer, but it
  forfeits popup fidelity and the payment handoff — the two things the hybrid
  engine exists to provide. Stay headful.

### Ceiling

Expect 10–20 fps at 1280×900 / q60 on loopback. That is right for watching and
wrong for anything latency-sensitive. If a run needs frame-accurate interaction,
the answer is the real window, not a better codec.

---

## Acceptance criteria

1. Phase 0 passes on both architectures from the signed packaged app.
2. A Stripe-style checkout popup opens, renders, and completes in Agent Mode.
3. No listening socket exists for CDP. Verifiable with `lsof`/`netstat` against
   the engine process while a task is running — the transport is a pipe.
4. A page instructing the agent to leave its frozen scope produces a halt, and
   the attempt is visible in the trajectory.
5. Stop halts before the next action, from every mode.
6. No screenshot or log anywhere contains a value typed into a secret field.
7. A completed run replays end to end from persisted trajectory.
8. Killing the engine mid-task fails the session loudly and leaves no orphan.
9. Engine absent → Agent Mode visibly unavailable, never a silent degrade.
10. A checkout completes with the model never having received the card number,
    the CVC, or the shipping address — proven by the run's own egress log.
11. A domain set to `never` produces zero model egress; a domain set to
    `structure-only` sends no free text beyond element labels and headings.
12. Every step's exact post-redaction payload is inspectable in the trajectory,
    and the run summary's byte count reconciles with the sum of its steps.
13. The payment gate halts on a **real** retailer checkout URL, proven against a
    table of live paths — Amazon `/gp/buy/spc/`, Amazon `/gp/buy/payselect/`,
    Shopify `/checkouts/`, Stripe, PayPal — and a live checkout is walked end to
    end to confirm it fires in the run, not only in the test. (Field test 07-25.)
14. A `click` whose `text` target matches more than one element returns an error
    naming the ambiguity. It never silently picks the first. (Field test 07-25.)
15. A run is watchable end to end from inside the app without switching windows,
    and the mirrored viewport tracks the engine within ~1s of a navigation.
16. Input forwarded from the mirror is refused while the mode is `agent_working`,
    and refused entirely while `awaiting_human` on a payment page — proven by the
    run's own egress and trajectory records.
17. A redirect from an allowed URL onto a payment or off-scope page halts the run,
    and the halt names both the landing and where it was redirected from.
    (Finding 6.)
18. After a cross-host redirect, the egress report's host and level are the
    **landed** host's — a `:structure_only` domain cannot be read at `:full` by
    being redirected to. (Finding 6, second order.)

## Deferred

- Local HTTP/WS API for other callers (build the isolation properly now so this
  is additive later).
- Payment execution and virtual-card issuance.
- Parallel/cloud fan-out — precluded by the local-only privacy claim, on purpose.
- Fingerprint and stealth work.
- Replacing WKWebView for human browsing.
- A local model for element selection — the only true fix for the Phase 3.5
  residual, named as the ceiling rather than built.
- **True OS-level embedding of the engine window.** Not deferred — ruled out on
  the merits (Phase 7). macOS has no supported cross-process view reparenting.
- Scrub-back rendering of the mirrored frames. The trajectory already replays;
  storing a frame per step is a disk-cost decision to make after Phase 7 ships.

## Risks, descending

1. **Shipping a capability that isn't there in prod.** The Browserbase failure,
   exactly. Phase 0 is the whole mitigation and it must not be reordered.
2. **The Chromium prerequisite.** Settled in favor of the system browser, so the
   residual risk is users without any Chromium-family browser. Bounded by the
   four-browser detection order and by failing loudly. Watch the real rate; the
   revisit trigger is written down.
3. **Prompt injection against a browser with hands.** Phase 3 before Phase 5,
   with no exceptions and no "we'll tighten it later."
4. **Two engines, two mental models.** Users will ask why one tab can do
   something another can't. The mode switch has to make the boundary obvious, or
   it becomes a support burden.
5. **Opportunity cost.** BusterPhone is still the money leg and arm64 still gates
   shipping. This is a large build that competes with both.
6. **Gates tested only against their own idea of the world.** Added 07-25, and
   it is now the risk with a proven instance: the payment regex passed its suite
   and failed on Amazon because the suite used `/checkout/`. Any gate whose
   fixtures we authored ourselves is unverified until it meets a real site. The
   mitigation is a live walk per gate, not a larger table of imagined paths.
7. **The mirror inviting credential entry.** A viewport embedded in our own app
   reads as "type here" — that is what makes it good UX and what makes it
   dangerous. The read-only-at-`awaiting_human` rule is the entire mitigation and
   it must not be relaxed for convenience later.
