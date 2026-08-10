# Distribution — who gets it, what they pay, and how we find out

**Split out of `LAUNCH_ROADMAP.md` 2026-08-09 · Status: ACTIVE.**

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

**What it does not:** the DMG ([`APPLE_ROADMAP`](APPLE_ROADMAP.md)), the download
page ([`WEBSITE_ROADMAP`](WEBSITE_ROADMAP.md)), and the pitch itself
([`FRONT_DOOR_ROADMAP`](FRONT_DOOR_ROADMAP.md)).

---

## Locked decisions

Settled in the 07-04, 07-12 and 07-18 operator sessions. Restated, not reopened.

- **Free beta, then charge.** Not a freemium ladder, not a trial clock.
- **BYO Claude.** The user brings their own subscription. This is a
  falsifiable claim (**H4**), not an article of faith.
- **MIT open core**, with `LICENSE` + `TRADEMARK.md` landed 07-12.
- **busterclaw.lol**, chosen 07-14 (it was buster.mom).
- **Apple as an individual**, merchant of record for anything paid.
- **`on-duty` is free forever** — unpaywallable by construction, because the
  loop runs on the user's own machine against their own Claude.
- **Google Workspace is free goodwill**, not a tier.
- **Signature Feed was cut 07-14.** Do not re-propose it as a paid tier.

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

**The build behind the tier is [`BUSTERPHONE_ROADMAP`](BUSTERPHONE_ROADMAP.md),**
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
[`WEBSITE_ROADMAP`](WEBSITE_ROADMAP.md), because it ships as part of the download
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
[`APPLE_ROADMAP`](APPLE_ROADMAP.md) Stage 1. IX.1, IX.4 and IX.5 do not — they
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
[`GOOGLE_VERIFICATION_ROADMAP`](GOOGLE_VERIFICATION_ROADMAP.md) is a decision
before it is a project.

---

## Explicitly off the critical path

- **SMS / A2P 10DLC** — code-complete, frozen on the Sole-Proprietor registration
  reset. Does not gate anything here.
- **The iPhone companion and the newspaper reader** — separate products.
- **Anything paid.** Free beta first is the locked decision.
