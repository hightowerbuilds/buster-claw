# Critical Path to First Revenue

*Synthesized 2026-07-20 from the seven active roadmaps (Distribution, Go-to-Market,
BusterPhone, First-Look Critical Review, First-User Review, Home-Chat Agent
Selection, Leftovers). This document is the ordered, costed to-do list that falls
out of them — not new strategy, just the convergent path the others already point
at.*

---

## The short version

The software is built; the business around it is not. Every roadmap converges on
the same three blockers — the app cannot yet be **opened** by a stranger (unsigned,
Intel-only), **paid for** (no purchase flow exists), or **fully used** (Google
OAuth stuck in Testing, five surfaces with no front door). None of those are
features. They are distribution, monetization, and focus.

**Ordering principle:** start the slow clocks you *don't* control on day one, do the
free high-leverage work while they tick, then spend real engineering on the two
things that gate a sale — *openable* (Apple) and *purchasable* (billing).

**Punchline:** roughly **$99 in cash** and **~2–3 focused weeks** gets a stranger to
*download → trust → pay for BusterPhone voice*. Google verification + CASA is a
separate, longer, pricier pole that **only the autonomous-email pitch needs** — and
can be deferred if voice is the first paid product.

## A note on the cost estimates

The time/money figures in Stages 0–3 and 5 come from the roadmaps themselves
(Distribution §10, First-User Part XIII, Go-to-Market). The **Stage 4
purchase-flow estimate is not roadmap-sourced** — the BusterPhone roadmap
explicitly says that work "is not in the phases yet," so treat Stage 4 as a rougher
guess than the rest.

---

## Stage 0 — Start the external clocks (Day 1; then you wait)

These have lead times you can't compress, so they go first even though the work
itself is minutes.

| # | Task | Cost | Notes |
|---|---|---|---|
| 0a | Enroll in Apple Developer Program (individual, no D-U-N-S) | **$99/yr**, ~1–2 day wait | Unlocks all of Stage 3. Apple publishes no SLA. |
| 0b | Start Google OAuth verification — move the app out of "Testing" | $0 for basic verification; weeks | Gmail refresh tokens die every 7 days in Testing today (First-Look #3), so even the *free* on-duty loop is broken until this clears. |
| 0c | **Decide:** does launch need restricted Gmail scopes (→ CASA)? | CASA = **thousands/yr + months** | If you lead with BusterPhone voice, you can **defer CASA entirely** and launch without it. The single biggest cost you can choose not to pay yet. |

## Stage 1 — The story, for free (same day, parallel with Stage 0's waiting)

First-User's #1 priority and the cheapest thing you'll ever buy — words, not
architecture.

| # | Task | Cost |
|---|---|---|
| 1a | Pick one front door; make README + onboarding wizard + home primary action all say the same sentence | Hours |
| 1b | Delete retired features from `introduction.md` / user guide (Scheduler, Webhooks, Delivery — they don't exist) | Hours |
| 1c | Move the half-built / decorative surfaces (Phone showcase, Voice dead-end, Wallets, SVG viewer) out of main nav or behind a labs toggle | Small diffs (First-User #20–24) |

## Stage 2 — The trust story (a day or two)

Non-negotiable because the product is sold on *auditability*, and two reviews
independently found the pitch currently hollow.

| # | Task | Cost |
|---|---|---|
| 2a | Either build the approval gate or stop implying it exists — `Sentinel.Pending` is an in-memory stub with no approve/deny/UI | ~1 day to be honest; more to build it (First-Look #12) |
| 2b | Surface the audit feed + kill switch prominently (move Security up, add a refusal badge, a visible "shift running / STOP") | A day or two (First-User #2) |
| 2c | Close the unauthenticated localhost POST endpoints (`/browser/*`, `/finance/api/*`, `/ws/file`) and remove the in-app plaintext master-key reveal | ~1 day (First-Look #11) |

## Stage 3 — Make it openable (≈1 week; gated on 0a clearing)

Distribution §10's "real work." The only thing blocking a stranger's first ninety
seconds.

| # | Task | Cost |
|---|---|---|
| 3a | Run `build_desktop.sh` end-to-end once (never been done) | Hours + debugging |
| 3b | Two-arch native CI build (arm64 + x86_64) — arm64 is a prerequisite, not a follow-up (Rosetta sunsets 2027) | Part of the ~1 week |
| 3c | Trim the bundle | Small |
| 3d | Sign + notarize (Developer ID, hardened runtime, all Mach-O objects signed) | The bulk of the week |
| 3e | Add the auto-updater (in the same breath as signing) | Part of the ~1 week |

## Stage 4 — Make it purchasable (≈1 week+, parallel with Stage 3 — *estimate*)

Independent of Apple/Google. This is the actual revenue unlock, and the gap every
review flagged: *a customer literally cannot pay today.*

| # | Task | Cost |
|---|---|---|
| 4a | Wire a merchant-of-record checkout (Paddle or Lemon Squeezy — already the locked GTM choice) | ~0 upfront, revenue share; days |
| 4b | Provision a Twilio number per paying account tied to subscription lifecycle (+ subaccount isolation, usage / abuse caps) | Net-new; several days |
| 4c | Add the in-app BusterPhone config / "get a number" UI (today credentials come only from boot env vars) | Several days |

## Stage 5 — Credible-beta table stakes (days each, after launch-critical work)

None block the first sale; all matter before wide distribution.

- Telemetry / crash reporting (first crash is silent today — First-User #41)
- User-facing error recovery (only a dev stderr log path exists — #43)
- A communicated macOS version floor (WebGPU/WKWebView minimum — #45)
- Agent onboarding: a seeded test dispatch item so the box isn't empty (#46)
- Update notification (#47)

---

## Off the critical path (deliberately)

- **SMS / A2P 10DLC** — code-complete but frozen on the Sole-Proprietor
  registration reset. It does not gate voice revenue; it's a later track.
- **Home-Chat agent selection** — 0% built (a plan added in the latest commit).
  A feature, not a blocker; it should not compete with any stage above.
- **Leftovers** — three small deferred items (walk the browser primitives in the
  real app, refresh out-of-repo prompt atom names, confirm the rotated DB password
  was saved). None blocking.

## The one decision that changes everything

Commit to **BusterPhone voice as the first paid product.** That lets you defer CASA
(months + thousands), turns Google verification into a background task instead of a
launch gate, and collapses the path to revenue down to
**Stage 0a → 1 → 2 → 3 → 4.**
