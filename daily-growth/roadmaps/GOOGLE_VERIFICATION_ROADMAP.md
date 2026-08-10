# Google verification and CASA — a decision before it is a project

**Split out of `LAUNCH_ROADMAP.md` 2026-08-09 · Status: DEFERRED, deliberately.**

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
today. See [`WEBSITE_ROADMAP`](WEBSITE_ROADMAP.md), `G-22`.

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
