# Distribution — who gets it, what they pay, and how we find out

**Carved out of the launch roadmap 2026-08-09 · Status: ACTIVE.**

> ### The one-sentence version
>
> **Free beta first, charge later — and the one thing worth charging for is a
> phone number, because we are the phone company.**

**Nothing here blocks a release.** That is the locked decision, restated because
it keeps getting re-litigated: nobody needs to be able to pay for either release
to be a success. This map exists so the money and audience questions have a home
that is *not* the signing pipeline, and so they stop drifting into a separate
document that disagrees with this one.

**What it covers:** the tiers and the margin, the five falsifiable claims about
whether anyone wants this, and the concept tests that settle them.

**What it does not:** the DMG ([`APPLE_ROADMAP`](../platform/APPLE_ROADMAP.md)), the download
page ([`WEBSITE_ROADMAP`](../website/WEBSITE_ROADMAP.md)), and the pitch itself
([`FRONT_DOOR_ROADMAP`](FRONT_DOOR_ROADMAP.md)).

---

## Locked decisions

Settled in the 07-04, 07-12, 07-14, 07-18 and 07-27 operator sessions. Not reopened;
restated because they are the constraints every other map inherits.

*Was the launch roadmap's Part I. Several rows are Apple's or the website's to execute;
they are decided here and cited there.*

| Question | Decision | Locked |
|---|---|---|
| Pricing model | Free core + paid tier — **free beta first, charge later** | 07-04 |
| Who pays for Claude | **BYO.** Buyer brings their own Claude subscription. We never resell tokens | 07-04 |
| Target buyer | **Dev-first**, prosumer later | 07-04 |
| The paid tier | **BusterPhone managed telephony. We are the phone company.** | 07-12 |
| Never ship | **BYO-Twilio as the paid tier** — zero marginal cost means nothing to enforce | 07-12 |
| Source model | **Source-available: PolyForm Shield 1.0.0** (`LICENSE`), name/wordmark reserved (`TRADEMARK.md`) | 07-27 · **executed 08-10** |
| Entitlement model | **Server-side by nature. No license-key DRM in the client, ever** | 07-04 |
| Domain | **busterclaw.lol** | 07-14 |
| Bundle ID | **`lol.busterclaw.desktop`** — shipped, one-way door now closed | 07-18 |
| Apple | **Enroll as an individual now** ($99/yr). Don't wait for an entity | 07-04 |
| Distribution | **Developer ID + notarization. Never the Mac App Store** (III.B) | 07-27 |
| Architectures | **Two native single-arch DMGs. Never lipo the ERTS** (III.G) | 07-27 |
| Payments | **Merchant of record** (Paddle or Lemon Squeezy) — they are the seller | 07-04 |
| Business entity | **Deferred.** With an MoR, the LLC is about liability, not tax plumbing | 07-04 |
| A2P registration | **Direct Sole Proprietor**, not a business brand | 07-18 |
| GWS | **Free forever.** Goodwill, not a paywall | 07-12 |
| on-duty | **Free forever, by construction.** It touches none of our infrastructure | 07-12 |
| Signature Feed | **CUT.** Don't re-propose | 07-14 |
| Browserbase | **DELETED.** Never shippable; don't rebuild | 07-12 |
| Whisper / local STT | **DEMOLISHED 06-28.** Don't reflex-rebuild | 06-28 |

**Why this hangs together.** BYO Claude means zero token liability and no AI backend.
Source-available is safe because the money leg isn't defended by copyright — it's defended
by *owning the phone number*. A fork gets the engine and none of the business.

> ### The source model was decided twice, and the repo only heard the first one
>
> **07-12** locked *"open core, MIT"* and the repo shipped MIT. **07-27** reversed it: the
> website commit `c8e731e` — *"Retire the open-source positioning for source-available"* —
> changed busterclaw.lol to say **"source-available, not open source"** and **"redistribution
> is not granted."** That decision never reached this map, the `LICENSE`, the README, or
> `TRADEMARK.md`.
>
> **For two weeks the public repo and the public website stated opposite legal terms about
> the same product**, and the repo's version was the more generous one — README: *"Fork it,
> sell it, build on it."* Found 08-10 while surveying the website for `G-21`/`G-22`.
>
> **Executed 08-10** as **PolyForm Shield 1.0.0** — a standard instrument rather than
> bespoke text, chosen because it matches the already-published wording (any use including
> commercial; no competing use) and because a known license is one a cautious company's
> legal team can accept without reading it twice.
>
> **The MIT grant is not retractable and was never treated as if it were.** Every commit
> published April–08-10 stays MIT for anyone who has it, permanently, including the right to
> resell. `LICENSE`, README and `TRADEMARK.md` all say so rather than quietly implying
> otherwise. **The cost of the delay is exactly that window**, and it is permanent — which
> is the argument for a decision reaching the code the day it is made, not a fortnight later.
>
> **The lesson is where the drift was, not that there was drift.** Nothing in this repo could
> have caught it: the contradicting statement lived in a different repository, on a surface no
> test here renders. The front-door problem is usually described as four surfaces telling four
> stories; this is the same failure with legal consequences attached.

---

---

## The money

**The paid tier is BusterPhone. We are the phone company.** We hold the Twilio
account, we provision the number, the user never learns Twilio exists. They pay
us one bill; we pay the wholesaler.

| Tier | What you get | Our marginal cost |
|---|---|---|
| **Free / Channel A** | Bring your own Twilio + Supabase; wire the webhook yourself | **$0** — so it's free. Same principle as BYO Claude |
| **Paid** | We are your phone company. A number, the relay, zero setup | **Real, recurring, per-user** — which is what honestly earns a recurring price |

**Why this also fixes the marketing problem.** The paid pitch is **"Buster Claw
answers your phone."** Five words. And a phone number is the one thing nobody
questions paying *monthly* for — telephony has been priced that way for a century.

**Inbound voice does not require A2P 10DLC.** That grind is an *SMS* gate.

**What must exist before anyone can pay** (none of it blocks this release): MoR checkout ·
number provisioning tied to subscription lifecycle, **releasing on cancel** or we pay forever ·
Twilio subaccount isolation · **usage caps and an abuse kill switch** (a pricing requirement,
not a nice-to-have — an abused account is unbounded minutes against a flat subscription) ·
in-app "get a number" UI · a server-side entitlement check.

**Margin, measured not guessed:** every voicemail on record costs **$0.0525**, of which
**transcription is $0.0500 — 95%.**

> **Open decision, and it shapes the price:** turn `<Record transcribe="true">` off (~one
> line; drops a voicemail to ~$0.0025), or keep Twilio transcription as COGS at ~5¢/message.
> A local-STT replacement would be a *fresh* decision — Whisper was deliberately demolished
> 06-28. **Decide before pricing anything.**

At $10–15/mo against a number (~$1–2/mo) plus usage, gross margin is roughly 80–85%.

**The build behind the tier is [`BUSTERPHONE_ROADMAP`](../integrations/BUSTERPHONE_ROADMAP.md),**
which is blocked on Clinch Phase 3. Provisioning is not worth writing until
**IX.4** below says someone wants it.

---

## Concept testing

*Everything here can start now, and the first item costs an afternoon.*

**Five falsifiable claims**, each with a way to be wrong:

| # | Hypothesis | Falsified if |
|---|---|---|
| H1 | Developers who pay for Claude want a runtime that gives it hands *plus a receipt* | Interviewees can't name a moment they wished they had an audit trail |
| H2 | **"Buster Claw answers your phone"** beats the runtime pitch | The runtime pitch converts at least as well on a landing test |
| H3 | The audit trail is the differentiator vs Open Claw / Zero Claw / Hermes | Users say "nice" and rank other features above it |
| H4 | BYO Claude is not a purchase blocker | Prospects balk at needing their own subscription |
| H5 | $10–15/mo for a managed number is acceptable | The price sits above "expensive but I'd consider it" for most of the sample |

**IX.1 — The one-sentence test (this week, free).** Show ten developers the README's first
paragraph and the home screen, **fifteen seconds each**: What does this do? Who is it for?
What would you do first? **Pass: seven of ten give the same answer to Q1, and it's the answer
you intended.** Today's likely result is a fail — that's the point, it's evidence for **VI-a**
that costs an afternoon. **Re-run after the front-door rewrite; the delta is the finding.**

**IX.2 — The landing-page test.** Lives in
[`WEBSITE_ROADMAP`](../website/WEBSITE_ROADMAP.md), because it ships as part of the download
page. It is the test for **H2**.

**IX.3 — Five moderated first-run sessions.** Five users finds most usability problems. Clean
Mac, signed DMG, screen recording, 45 minutes, you say nothing beyond "what are you thinking?"
Tasks: install and open · *without asking me, what is this for?* · get the agent to do one
useful thing · **find out what the agent did** · **stop the agent immediately** · find out what
the agent is **not allowed** to do. **Pass bar: 4/5 complete tasks 1, 3, 4, and 5 unaided.
Tasks 4 and 5 are the ones that matter — they are the product's claim.**

**IX.4 — The concierge test for BusterPhone.** The paid tier needs provisioning, lifecycle, and
abuse controls before it can be *sold*. **You do not need any of that to test whether people
want it.** Provision three to five numbers **by hand** in the Twilio console, run four weeks,
then say you're turning it off. **Do they ask for it back?** That question is the entire test,
and it costs five phone numbers instead of a month of provisioning code.

**IX.5 — Competitive teardown.** Install Open Claw, Zero Claw, and Hermes. Do the IX.3 tasks in
each. Write down, honestly, the three things each does better. **Confirm or kill H3 with
evidence:** does any of them have a per-command, redacted, trust-tiered audit log with refusal
queueing? If one does, the differentiation story needs rewriting *before* launch.

**Decision gates.** After IX.1: 7/10 same answer, or rewrite the story. After IX.2: >3–5%, or
change the pitch or the buyer. After IX.3: 4/5 complete the audit + kill tasks, or fix the
front door before inviting anyone. After IX.4: they ask for the number back, or **re-open the
paid-tier question before building provisioning.**

**IX.3's dependency:** it needs a signed DMG, so it runs after
[`APPLE_ROADMAP`](../platform/APPLE_ROADMAP.md) Stage 1. IX.1, IX.4 and IX.5 do not — they
can start today.

---

## The bill

| Item | Cost | Frequency |
|---|---|---|
| Apple Developer Program (individual) | **$99** | /yr |
| Developer ID certificate + notarization | $0 | included, unlimited |
| busterclaw.lol domain | ~$10–30 | /yr |
| Static site + download hosting (Vercel / GitHub Releases) | $0 | — |
| Telemetry endpoint (Cloudflare Worker or a $5 VPS) | ~$0–5 | /mo |
| CASA assessment (**only if we keep restricted Gmail scopes**) | ~mid-$100s–$3k+ | /yr |
| Apple's revenue cut on Developer ID | **0%** | vs 15–30% on the App Store |
| **Total to a public download** | **≈$110–130 for the first year** | CASA excluded by deferring Gmail scopes |

**$99 unlocks every Apple item.** The real currency is engineering time — and the
expensive-looking item, App Store compliance, is the one we are deliberately not
buying. **CASA is the only line here that could multiply**, which is why
[`GOOGLE_VERIFICATION_ROADMAP`](../integrations/GOOGLE_VERIFICATION_ROADMAP.md) is a decision
before it is a project.

---

## Explicitly off the critical path

- **SMS / A2P 10DLC** — code-complete, frozen on the Sole-Proprietor registration
  reset. Does not gate anything here.
- **The iPhone companion and the newspaper reader** — separate products.
- **Anything paid.** Free beta first is the locked decision.
