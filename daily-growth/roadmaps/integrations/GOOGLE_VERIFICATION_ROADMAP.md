# Google verification and CASA — a decision before it is a project

**Carved out of the launch roadmap 2026-08-09 · Status: DEFERRED, deliberately.**

> ### The one-sentence version
>
> **Reading and sending Gmail means restricted scopes, which means an annual
> third-party security assessment forever — so the first task is deciding whether
> the public download needs it at all.**

**This is the only line in the bill that could multiply.** Apple is a week of
work and $99. This is months and possibly thousands per year, recurring. It is
deferred, and the deferral is load-bearing rather than lazy.

**It has a hard dependency on the website:** OAuth brand verification needs a
homepage **and a privacy policy at a matching domain**, both of which are 404
today. See [`WEBSITE_ROADMAP`](../website/WEBSITE_ROADMAP.md), `G-22`.

---

## Part VIII — Google verification and CASA

**Deferred, and that is a deliberate, load-bearing choice.**

The app reads and sends Gmail — **restricted scopes** — which means three gates: OAuth brand
verification (needs a homepage **and a privacy policy at a matching domain** — see **G-22**),
restricted-scope review, and a **CASA security assessment**: an independent lab assessment,
**annual**, typically mid-hundreds to a few thousand dollars per year, recurring forever.

**Honest timeline: weeks to months.** An app whose pitch is "an AI autonomously reads and
answers your email" should expect extra scrutiny and at least one rejection round.

> **The beta-cap gotcha.** While the OAuth app is unverified ("Testing"), only **100
> explicitly listed test users** can connect — and **their refresh tokens expire every 7
> days.** Users must reconnect Google weekly until verification clears. The onboarding says
> "you'll do this once," which is **false for every early user**. Say it out loud, and fix
> the wizard copy.
>
> **Both halves fixed 2026-08-10** (`bc6c535`, and the runbook below). The wizard now
> derives its cadence claim from `GoogleOAuth.reconnect_sentence/0` and names the
> "Access blocked" symptom. **The operator half had never been written down at all.**

---

## The tester runbook — do this BEFORE you invite anyone

**Added 2026-08-10, because it was the gap nothing covered.** The app's own copy tells a
tester how to *request* access. Nothing anywhere told the operator how to *grant* it — so
the first trial invitation would have produced a tester stuck on a Google error page and an
operator with no idea which knob to turn.

### Why no amount of app code can rescue this

While the OAuth app is in **Testing**, an address that is not on the approved list **never
reaches our callback.** Google terminates the flow on its own screen — *"Access blocked: …
has not completed the Google verification process."* Our `GoogleOAuthController.callback/2`
is never invoked, so:

- the app cannot detect it,
- cannot log it to Sentinel,
- cannot show an error, and
- **cannot tell it apart from a user who simply wandered off.**

The wizard just sits on step 3. **This is the failure mode with the worst ratio of
"trivially preventable" to "looks like the product is broken" in the whole onboarding
path**, and the only lever available is saying it in advance — which the beta note now does.

### The steps

1. **Google Cloud Console** → the project holding the bundled OAuth client → **APIs &
   Services → OAuth consent screen → Audience** (historically *"Test users"*; Google has
   moved this page more than once — look for the tester list, not a fixed URL).
2. **+ Add users** → the tester's **exact Gmail address**. No wildcards, no domains, no
   aliases: the address they will actually pick on the consent screen.
3. **Do it before you send the invite.** A tester who tries first hits the block page, and
   the fix is invisible from their side even after you add them — **they must restart the
   consent flow**, so you have to tell them to try again.
4. **Cap: 100 test users, and removals do not free a slot retroactively in any way you
   should rely on.** For a "handful of people we can email" this is not a constraint; if a
   trial ever approaches it, that is the signal to finish verification rather than to
   economise on testers.
5. **Warn them about the weekly reconnect** even though the wizard now says it. The app's
   copy is a backstop, not an invitation — a person told in advance by a human reads a
   weekly prompt as expected; a person who only reads it on screen at the moment it happens
   often does not.

### The one thing to check when a tester says "it doesn't work"

Ask what the **last screen they saw** was, and whether it was Google's or ours.

| What they saw | What it means |
|---|---|
| Google's "Access blocked … has not completed the Google verification process" | not on the tester list — step 1 above |
| Google's consent screen, then back to Buster Claw with a failure | a real OAuth failure; `GoogleOAuthController` handled it, so there is a message and a Sentinel entry to read |
| Nothing — the wizard just sat there | almost always the first row |

**That question is the entire diagnostic**, and it works because our callback either ran or
it didn't. There is no third case.

**The fallback, and it is a good one:** GWS ships as *"developer preview — bring your own
OAuth app"* while the rest of the download is public. A dev can make their own OAuth client in
twenty minutes. The flagship feature dark for non-dev users is bad; **it is not a launch
blocker for the app as a whole**, and keeping this fallback alive permanently is the mitigation
for R2.

- [ ] **Decide explicitly and write the answer down:** does the *public download* need
      restricted Gmail scopes on day one? If no — and with BusterPhone as the paid tier, the
      answer is probably no — this entire part stays a background task.

> **Say this out loud.** The Google/CASA clock is slower, costlier, and riskier than
> everything Apple asks for. Apple is a week of work and $99. Google is months and possibly
> thousands per year, forever. **If both queues are starting, Google should have started
> yesterday — and Apple should not be what's blocking you.**


---

## The risk this map holds

**R2 — Google says no, or says slow.** Verification for an agentic email app is
genuinely uncertain territory. *Mitigation:* defer it entirely, and keep the
BYO-OAuth developer-preview fallback alive **permanently**.
