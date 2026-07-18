# BusterClaw — Go-To-Market Roadmap

**Date:** 2026-07-04 · **App version:** 0.1.0 · **Status:** ACTIVE — this is the live map for getting BusterClaw sold.

This document records the strategy locked in the 07-04 operator Q&A, what it will
actually take to execute, and — honestly — what could go wrong. It builds on the
June distribution work (`daily-growth/archive/06-14-26-distribution-roadmap.md`),
which solved *free public download*. This adds the *business* layer on top.

---

## Part I — The locked decisions

| Question | Decision |
|---|---|
| Pricing model | **Free core + paid tier** — but not yet: **free beta first, charge later** |
| Who pays for Claude | **BYO** — buyer brings their own Claude Code subscription/API key; we never resell tokens |
| Target buyer | **Both, dev-first** — technical users now, prosumers later |
| Future paywall line | ⚠️ **UNRESOLVED — this decision has come undone.** Was "Browserbase + GWS/on-duty". Browserbase was **cut 07-12**, and on-duty turns out to be **unpaywallable by construction** (it touches none of our infrastructure). That leaves GWS alone, which is the wrong thing to sell a dev-first buyer. **See Part V.0/V.1 — pick the money leg before pricing anything.** Everything local-only stays free, and on-duty is now permanently in that bucket |
| Domain | **https://busterclaw.lol** (changed 07-14; was busterclaw.lol) |
| Source model | **Open core** — repo stays public, Channel A (clone-and-build) intact; paid tier enforced server-side |
| Apple Developer | **Enroll as individual now** ($99/yr) — don't wait for an entity |
| Payments (when they arrive) | **Merchant of record** (Paddle or Lemon Squeezy) — they are the seller, handle global sales tax, pay us out |
| Business entity | **Deferred** — with an MoR, the LLC is about liability, not tax plumbing. Not on the critical path |
| Google verification / CASA | **Start now** — beta runs under the unverified test-user cap while it grinds |
| Beta measurement | **Opt-in telemetry** — anonymous, consent-gated; plus whatever qualitative channel emerges |

Why this hangs together: BYO Claude means zero token liability and no AI backend.
Open core is safe because the paid features are *services* — GWS needs our verified
OAuth app's secrets, which don't live in the repo. A developer who builds from
source and wires up their own OAuth app was never a lost sale; that's Channel A
working as designed.

**Browserbase was cut on 07-12.** It was half the paywall, so this is worth being
precise about. The cloud browser was never driveable from the shipped app: a
Browserbase session is driven over CDP by the *local* Playwright sidecar, and the
prod build neither enables that sidecar (`config/runtime.exs` gates it to
`config_env() == :dev`) nor bundles node/Playwright at all (`build_desktop.sh` only
runs `npm ci` in `assets/`). Making it real meant shipping a browser runtime inside
the `.app` — hundreds of MB of Mach-Os that would each need signing — landing on top
of the arm64 and notarization work that already blocks shipping. We deleted the code
rather than carry an unshippable paid dependency toward a paywall.

**And it turns out the paid tier now rests on ZERO legs, not one.** The instinct
was to say "fine, GWS + on-duty carries it" — but on-duty **cannot be paywalled at
all** (it uses none of our infrastructure and our own no-DRM rule forbids the only
mechanism that could gate it), and GWS alone is the wrong thing to sell to the
dev-first buyer we're aiming at. The whole money story needs re-answering, and
**Part V.0 states the problem precisely; V.1 is the decision.** Do not treat this
as settled just because the Browserbase row is gone from the table.

---

## Part II — Where we actually stand

### Already done (from the June distribution effort)
- **Version single-sourcing** — root `VERSION` → tauri.conf.json/Cargo.toml/mix.exs (`7ad5d55`)
- **Release token safety** — a release refuses to boot carrying dev/test tokens
- **OS-keychain secrets** — Tauri shell sources SECRET_KEY_BASE + api/mcp tokens from macOS Keychain, with legacy migration and a RESTORE_SECRET_KEY recovery path (`d5bfdb9`)
- **Channel A reproducible build** — `.tool-versions`, `BUILD.md`, npm-ci preflight in `build_desktop.sh` (`cb3231d`)
- **Secrets encrypted at rest** in SQLite (Vault/Encrypted); no personal identifiers in source
- **Sentinel audit layer + CSP**; QX review top-tier chain fixed (e88c7aa)

### Not done (and required before anyone else runs this app)
- **B1: Signing + notarization** — nothing is signed today. Blocked only on Apple enrollment
- **F2: Bundled Google OAuth app** — GWS currently assumes the developer's own OAuth credentials
- **B2/B3: Release publishing + download page** — GitHub Releases wiring and a page on busterclaw.lol
- **Full `.dmg` end-to-end build** — component steps verified, but the complete `build_desktop.sh` → installable `.dmg` run has *never* been executed
- **Bundle ID** — still `com.hightowerbuilds.busterclaw`; the domain decision unblocks it → **`lol.busterclaw.desktop`** (or similar). Must change **before** the first public build: changing it after users install orphans their app-data dir and breaks notarization continuity
- **Telemetry** — the app ships zero today (a feature for privacy, a blindfold for "did the beta work"). Needs a consent gate, a tiny ingest endpoint (new infra — a Cloudflare Worker or a $5 VPS is enough), and a privacy-policy clause
- **Website** — busterclaw.lol needs, at minimum: product page, download link, **privacy policy** (Google hard-requires it at a public URL), and terms
- ~~**License** — the public repo currently has no license…~~ ✅ **DONE 07-12: MIT** (`LICENSE`) + a trademark policy (`TRADEMARK.md`). Note the README had been *claiming* MIT for months while granting nothing — every outside PR was a legal question mark. **AGPL/BSL were rejected**, and the reasoning matters: they exist to stop a fork selling our paid tier back to us, but neither money leg is defended by copyright. The phone is defended by **owning the number** (a fork can't fork our Twilio account) and the feed by **making new things** (a fork can't fork work that doesn't exist yet). Copyleft would have bought us nothing and cost us the goodwill and the contributions. The shaders and CSS ship MIT too — they're the best advertising we have, and MIT forces every fork to carry our copyright notice, which is the attribution we actually wanted

---

## Part III — The two external clocks (start both this week)

These are the only things on the critical path we don't control. Everything else
is engineering that can proceed in parallel.

### Clock 1: Apple Developer enrollment
- Individual account, $99/yr. Usually clears in ~48h.
- Unblocks Developer ID certificate → B1 signing/notarization → the first build another human can open without right-click gymnastics.
- Honest note: the cert will read **"Developer ID Application: Luke Hightower"**, not a company. For a dev tool distributed outside the App Store this is normal and nobody will care. Migrating to an org account later is possible but is a support ticket + re-signing exercise — accepted cost.

### Clock 2: Google restricted-scope verification + CASA
The app reads and sends Gmail. Those are **restricted scopes**, which means:
1. **OAuth brand verification** (homepage + privacy policy at a matching domain — hence busterclaw.lol must be live first)
2. **Restricted-scope review** by Google
3. **CASA security assessment** — an independent lab assessment, **annual**, typically mid-hundreds to a few thousand dollars per year depending on lab and tier. Recurring forever, for as long as we touch Gmail scopes.

Honest timeline: **weeks to months**, and an app whose pitch is "an AI autonomously
reads and answers your email" should expect *extra* scrutiny, possibly a rejection
round or demands for scope justification. Budget for one rewrite of the consent
screens and justification text.

**The beta-cap gotcha nobody mentions:** while the OAuth app is unverified
("Testing" status), only **100 explicitly listed test users** can connect, and —
this is the painful part — **their refresh tokens expire every 7 days**, so beta
users must reconnect Google weekly until verification clears. This is annoying
enough that the beta messaging should say so out loud, and it is the single best
argument for starting Clock 2 immediately.

Fallback if verification stalls: GWS ships as "developer preview — bring your own
OAuth app" (Channel A style) while the rest of the beta is public. The flagship
feature dark for non-dev users is bad, but it is not a launch blocker for the app
as a whole.

---

## Part IV — Engineering workstreams for the free beta

In rough dependency order. None of these are research; all are known work.

**W0 — Identity switch.** ~~Bundle ID → `lol.busterclaw.desktop`~~ ✅ bundle ID
SHIPPED 07-18 (R5 name ratified by the same call); busterclaw.lol DNS +
static site (GitHub Pages is fine to start); privacy policy + terms drafted and
published. *Do this first — Clock 2 cannot even start without the site.*

**W1 — Sign + notarize (B1).** Developer ID cert, hardened runtime, entitlements
audit (the app spawns subprocesses — Claude Code, `say`; entitlements must allow
it), `notarytool` in the build script, stapling. Exit test: a fresh Mac that has
never seen the repo downloads the `.dmg` and it opens clean.

**W2 — Full build e2e.** Run `build_desktop.sh` clone-to-`.dmg` on a clean
machine. This has never been done and *will* surface surprises; schedule real time
for it, not an afternoon.

**W3 — Publish (B2/B3).** GitHub Release with the signed `.dmg`, download page on
busterclaw.lol, `VERSION`-driven. Updates are manual re-download in v1 (locked
decision) — see risk R4.

**W4 — Bundled Google OAuth (F2).** PKCE one-click connect against *our* OAuth
app; test-user management tooling for the 100-cap beta phase.

**W5 — Opt-in telemetry.** First-run consent screen (default OFF), anonymous
install ID, a handful of events (app-opened, feature-touched: terminal / on-duty /
browser / shaders), tiny ingest endpoint, privacy-policy clause. Nothing more —
this is a retention thermometer, not analytics.

**W6 — Beta hardening.** The parts of "someone else's Mac" we haven't felt:
first-run experience with *no* Claude Code installed (detect + explain, don't
crash), workspace picker on a clean machine, macOS version floor (WebGPU shader
backgrounds need a recent WKWebView — must be tested and stated; the graceful
blank-canvas fallback already exists), Gatekeeper/quarantine behavior.

---

## Part V — The paid tier (reopened 07-12, **resolved same day: BusterPhone**)

> **The short version.** The Browserbase cut didn't narrow the paywall — it took it
> to zero (V.0: on-duty is unpaywallable by construction, and GWS alone is the wrong
> thing to sell a developer). **V.1 resolves it: the paid tier is managed telephony —
> we are the phone company.** V.0 is kept in full because the reasoning is what stops
> the decision from drifting back.

### V.0 — The problem, stated exactly

Part I said the paywall line was **"Browserbase + GWS/on-duty — the two features
that cost *us* real money."** That principle was sound. The trouble is that when
you check each surviving leg against it, neither one survives:

**On-duty cannot be paywalled. At all.** Not "is hard to" — *cannot*. The
`Dispatcher` touches exactly one network endpoint: `127.0.0.1`, the local Phoenix
server (`lib/buster_claw/dispatcher.ex:328`). `AgentRunner` shells out to the
user's own `claude` binary, on their own Mac, paid for by their own BYO
subscription. On-duty consumes **zero** of our infrastructure and costs us **zero**
marginal dollars. Now hold that against our own locked rule — *"no license-key DRM
in the client, ever; the paid tier is enforced server-side."* On-duty has no
server-side component to enforce against, and the repo is public. A user clones
Channel A, runs `on-duty`, and there is no hook to withhold. **On-duty is free by
construction. Stop counting it as half a paid tier — it is zero.**

**That leaves GWS alone.** GWS *is* genuinely enforceable, and cleanly: the bundled
OAuth credentials are fetched from a URL we control
(`lib/buster_claw/google/bundled_client.ex:8-13`, `busterclaw.lol`). Don't pay, don't
get served the config. No DRM required. But look at what we'd actually be selling:
**"pay us so you don't have to create your own Google Cloud project."** Three things
go wrong at once:

1. **Our stated buyer is dev-first.** A developer is exactly the person who *can*
   stand up a GCP OAuth client in twenty minutes — and our public repo documents
   how. We'd be selling a convenience to the audience least in need of it.
2. **It's a one-time annoyance priced as a subscription.** The pain is on day one
   and never again. Recurring billing for a one-time setup is a churn machine.
3. **The margin is inverted.** GWS is the leg that costs *us* a recurring CASA
   assessment, forever (Part VII). We'd be paying an annual security audit for the
   privilege of selling developers something they don't need.

GWS *does* work as a paid feature — for **prosumers**, for whom a GCP project isn't
an annoyance but an impossibility. "We handle Google for you" is a real product for
them. That is our *later* audience, not the one we are about to charge.

### V.1 — DECIDED 07-12: **BusterPhone is the money leg**

**The paid tier is managed telephony. We are the phone company.**

We hold the Twilio account. We provision the number. **The user never learns Twilio
exists.** They pay us one bill; we pay the wholesaler. This is the *only* shape that
works, and the reasoning is worth keeping because the obvious alternative is a trap:

> **The trap: "user brings their own Twilio."** If the buyer signs up for Twilio,
> buys a number, and *then* pays us, we've built the worst of both worlds — they pay
> twice, and **we have zero marginal cost, which means we have nothing to enforce.**
> No Twilio bill of our own = no server of ours in the loop = the on-duty trap again
> (V.0): public repo, no hook to withhold, nothing to sell. **Never ship BYO-Twilio
> as the paid tier.**

Note this is deliberately the *opposite* of BYO Claude, and that's correct. BYO Claude
works because the expensive thing is Claude and the buyer **already has a
subscription**. Nobody already has a spare Twilio number. There is nothing to bring.

**The open-core split stays honest:**

| Tier | What you get | Our marginal cost |
|---|---|---|
| **Free / Channel A** | Bring your own Twilio + your own Supabase; wire the webhook yourself. Documented in the repo. | **$0** — so it's free. Same principle as BYO Claude; the self-hoster stays served. |
| **Paid** | We are your phone company. A number, the relay, zero setup. | **Real, recurring, per-user** — which is exactly what earns a recurring price. |

**Why this also fixes the marketing problem** (the pitch has been the weak point all
along): we currently sell *"a desktop runtime where an agent manages your web
interactivity through one auditable command surface"* — a paragraph, aimed at people
who already know they want it. The paid pitch becomes **"Buster Claw answers your
phone."** Five words, no explanation needed. And a phone number is the one thing on
earth nobody questions paying *monthly* for — telephony has been priced that way for
a century, so we never have to teach the customer why it recurs. (Contrast: justifying
a subscription for "we set up your Google Cloud project once.")

**The compliance path is much shorter than this roadmap assumed.** As shipped,
BusterPhone is a pure **inbound answering machine**: the voice function is
`<Say>` greeting → `<Record>` → transcribe (`supabase/functions/voice/index.ts:77-83`),
and there is **no outbound Twilio call anywhere in the codebase** (no `Messages.json`,
no `Calls.json`). **Inbound voice does not require A2P 10DLC** — that's the SMS
registration grind. So the paid tier can ship as "Buster answers your phone" **without
touching a campaign registration**. SMS (the threads already built into `/phone`) comes
after. See `BUSTERPHONE_ROADMAP.md` for the sequencing.

**What we are signing up for — eyes open:**

- **We become a telephony reseller.** Number provisioning, abuse controls (an agent
  with a phone is an agent that can be socially engineered into calling or recording
  something it shouldn't), carrier weirdness. Real ops, not a weekend.
- **COGS is small but real** — a US number is on the order of $1–2/mo plus usage
  (**confirm current Twilio pricing at build**). At $10–15/mo that's a healthy margin
  *and an honest one*, which is the entire point of Part V.
- **It is unfinished.** ~~No Mac-side drain~~ (drain SHIPPED 07-12 — the inbound
  path is now complete end-to-end), ~~still a trial number~~ (paid local number
  live since 07-13). This is a build, not a flip.
- **SMS will likely force the LLC early** (A2P brand registration wants an EIN),
  which cuts against Part I's "entity deferred." Voice-only may let us defer it —
  **confirm before committing to an SMS date.**

**~~The second half of the subscription: the Signature Feed.~~ CUT 07-14 (operator
decision — not the direction; nothing was ever built).** The design record moved to
`../archive/SIGNATURE_FEED.md`. The subscription now stands on **BusterPhone alone**,
which reopens the question the feed existed to answer: *why is someone still paying in
month six?* The honest answer today is "because the phone keeps answering" — retention
has to come from the phone being genuinely good, not from an asset drip. If month-six
churn says that's not enough, that's a new problem to solve then, not a reason to
resurrect the feed.

**Licensing settled 07-12 (and it does not threaten any of this).** The repo is now
**MIT** — including the shaders and the CSS design system — with the name, wordmark
and logo reserved (`LICENSE`, `TRADEMARK.md`). Giving the code away is safe precisely
because the money leg isn't defended by copyright: the phone is defended by *owning
the number*. A fork gets the engine and none of the business. (The feed — which was
defended by *making new things* — was cut 07-14; the reasoning stands for the phone.)

*The two candidates below were the options considered. Option B (paid signed binary)
is NOT dead — it's a viable second revenue line later, and it charges for a cost we're
eating anyway. Kept for the record.*

- **Option A — BusterPhone.** The natural paywall. A phone number costs real money
  every month, *per user*; minutes cost money; A2P 10DLC registration costs money.
  The relay is *our* Supabase and the number is *our* Twilio — **server-side by
  construction**, no DRM needed, and Channel A cannot route around it without the
  user provisioning their own Twilio account, which is a genuine barrier rather
  than a twenty-minute one. It is the only remaining feature with true per-user
  marginal cost. **Catch:** it is unfinished — ~~no Mac-side drain~~ (SHIPPED 07-12), no
  Twilio upgrade (see `BUSTERPHONE_ROADMAP.md`). A candidate, not a ready answer.
- **Option B — Charge for the signed binary.** We are about to eat the Apple
  $99/yr, notarization, and two-runner arm64 CI *regardless* (see
  `DISTRIBUTION_ROADMAP.md`). "Source is free — clone and build it yourself
  (Channel A); the notarized, auto-updating DMG costs money" is a proven open-core
  model (Aseprite ships exactly this way). It keeps the repo public, charges
  precisely for a cost we are already incurring, and needs **no entitlement server
  at all**. Weaker as recurring revenue — it's one-time — but an MoR handles
  one-time fine.

**Resolved 07-12 → Option A (BusterPhone).** See V.1 above. The rest of the call
stands: do **not** ship a GWS paywall to a dev audience — make GWS a free convenience
that buys goodwill while CASA grinds, and treat on-duty as free-core forever *and say
so out loud*.

### V.2 — The parts that still hold

- **Entitlement model:** whatever the paid feature turns out to be, it must be
  **server-side by nature** — **no license-key DRM in the client, ever**. The
  open-core client only ever asks "what am I entitled to?" (Note this rule is
  precisely what disqualifies on-duty.)
- **Payments:** Paddle or Lemon Squeezy checkout (≈5% + fees — the price of never
  thinking about EU VAT). Pick one when the paywall ships, not before.
- **Pricing hypothesis:** ~~free = the local app; paid ≈ $10–15/mo = on-duty email +
  cloud browser~~ — **void.** Both halves are gone: the cloud browser is deleted and
  on-duty is unpaywallable. A new hypothesis waits on V.1. What survives is the
  *free* half: the local app (terminal, agents, skills, shaders, appearance —
  everything on-device) is free, and now on-duty is permanently in that bucket too.
- **Entity:** form the LLC when real money starts flowing (liability, not tax —
  the MoR handles tax). Not before.

---

## Part VI — Honest risks, in descending order of losing sleep

- **R1 — Google says no, or says slow.** The whole prosumer story leans on
  autonomous email. Verification for an agentic email app is genuinely uncertain
  territory in 2026. *Mitigation:* start now, write scope justifications
  carefully, keep the dev-preview BYO-OAuth fallback alive permanently.
- **R2 — The market is "people who already pay for Claude."** BYO Claude was the
  right call, but it means every customer is pre-filtered by an existing $20+/mo
  Anthropic relationship. The prosumer expansion eventually collides with this;
  bundled-metered AI is a *future* fork, deliberately deferred, but it should stay
  on the map. Dev-first works *because* devs already have Claude Code.
- **R3 — Solo-dev support surface.** An autonomous agent + email + payments +
  someone else's Mac = support tickets that are genuinely hard. The Sentinel audit
  trail is the best support tool we have; beta docs should teach users to read it.
  Keep the beta small enough to answer every email personally — that's the actual
  moat at this stage.
- **R4 — No auto-update (locked v1 decision) is a security-patch liability.** An
  agentic app that can act on email *will* someday need a fix shipped fast, and
  "please re-download" is slow. Honest position: acceptable for a 100-user beta,
  not acceptable at 1.0 — revisit before charging (Tauri's updater or Sparkle).
- **R5 — busterclaw.lol.** Memorable, funny, on-brand. Also: exotic TLDs get worse
  treatment from some corporate mail filters and look unserious to a slice of
  buyers. For an indie dev tool it's fine — but it's a one-way door once it's the
  bundle ID (`lol.busterclaw.*`), printed in every keychain entry and OAuth consent
  screen. Say it out loud once before W0: *is this the name at 1.0?*
- **R6 — CASA is a forever-cost, and telephony now has to pay for it.** Annual
  assessment + $99 Apple + domain + MoR cut is the permanent bill for "free beta,"
  and CASA is specifically the recurring cost of GWS — a leg we've decided to *give
  away*. That bill is now underwritten entirely by BusterPhone subscriptions (V.1).
  So the risk has changed shape rather than gone away: **it is no longer "nothing
  pays for CASA," it is "one unfinished feature pays for CASA."** If BusterPhone
  doesn't convert, the fixed costs have no other funder. Watch the telephony
  build (`BUSTERPHONE_ROADMAP.md`) as a *business* dependency, not just a feature.
- **R7 — Unknown macOS floor.** WebGPU-in-WKWebView and the Tauri stack set a
  minimum macOS we have never actually determined. Cheap to test, embarrassing to
  discover via refunds.

---

## Part VII — The bill

| Item | Cost | Frequency |
|---|---|---|
| Apple Developer (individual) | $99 | /yr |
| CASA assessment | ~mid-$100s–$3k+ (lab/tier dependent — get quotes) | /yr |
| busterclaw.lol domain | ~$10–30 | /yr |
| Static site (GitHub Pages) | $0 | — |
| Telemetry endpoint | ~$0–5/mo | /mo |
| Merchant of record | ≈5% + ~$0.50 per sale | per sale (later) |
| **Beta total, ignoring time** | **≈ $150–3,200/yr** | dominated entirely by CASA |

---

## Part VIII — Order of operations

1. **This week:** Apple enrollment · busterclaw.lol live with privacy policy · decide R5 (name check) · start Google verification paperwork
2. **Next:** W0 bundle ID → W1 sign/notarize → W2 full e2e build
3. **Then:** W3 publish + W4 bundled OAuth + W5 telemetry (parallelizable)
4. **Then:** W6 hardening → invite trusted users under the 100-cap (weekly-reconnect caveat stated up front)
5. **When Google clears:** flip to true public beta, announce
6. **When retention says so:** paywall (Part V), MoR account, LLC, revisit auto-update — that's the "1.0, for sale" milestone

The through-line: **everything we control is weeks of work; everything slow is
someone else's queue.** Start the queues first, build while they grind.
