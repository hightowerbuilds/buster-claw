> ## ARCHIVED 2026-08-18 — CANCELLED UNBUILT. Its subject was deleted.
>
> Scoped 08-15, three days after the path it described came into being and three
> days before the capability it described was removed. **No code was ever written
> against it, and none should be.**
>
> **What happened.** This map existed to move BusterPhone's outbound-SMS consent
> disclosure from the website into the app, and to correct seven false claims on
> `Explained.Phone` that had gone stale the night 10DLC was abandoned for
> toll-free verification. On 08-17 Twilio rejected that verification (`30484`,
> business name). On 08-18 the operator chose to delete outbound SMS entirely
> rather than resubmit — so the consent disclosure, the public opt-in page, the
> `Telephony.Disclosure` module and the cross-repo generator this document
> proposed all stopped having a subject at once. See
> [`PHONE_INTAKE`](../roadmaps/integrations/PHONE_INTAKE_ROADMAP.md).
>
> **Its own Part VI.4 predicted this**: *"Toll-free verification can be
> rejected. If it is, the blocker changes again."* It did not consider that the
> cheapest response was to stop needing the thing.
>
> ### Where the leftover went — the part archiving must not lose
>
> **Part II was consumed, not orphaned.** Its line-by-line inventory of every
> false claim on `Explained.Phone`, with the four test assertions pinning the
> stale strings, is the map that was actually used to rewrite that page on 08-18
> (701 → 591 lines). Every claim it listed is gone. The two anchors that replaced
> them — `[data-phone-no-outbound]` and `[data-phone-a2p]` — are asserted in
> `status_live_test.exs`.
>
> **Part II's one instruction survived the deletion of everything around it.**
> It said `:530` was the claim to preserve — that inbound traffic is still
> *A2P-classified*, and that rewriting the page as "A2P no longer applies" would
> replace one false claim with a worse one. That paragraph is still on the page,
> reframed, under `[data-phone-a2p]`. It was right, and it outlived its document.
>
> Nothing else here is open, because nothing else here has a subject.

# BusterPhone SMS disclosure — moving the consent story into the app

**Scoped 08-15-26 · Status: NOT STARTED. No code written.**

> ### The one-sentence version
>
> **`Explained.Phone` currently tells the operator that outbound SMS is blocked
> behind A2P 10DLC. As of tonight that is false — 10DLC was abandoned and the
> live path is toll-free verification — and the consent disclosure that the new
> path requires lives on a website rather than in the app, which is not where
> the operator wants users to read it.**

> ### The operator's ask, verbatim
>
> *"We want the explanation to be in the app, not randomly on the website."*
>
> Said after I published `busterclaw.lol/busterphone/` to satisfy toll-free
> verification's `OptInImageUrls`. Both halves are legitimate and they pull in
> opposite directions — [Part III](#part-iii--two-audiences-one-set-of-facts) is
> that tension and is the interesting part of this document.

> ### Read this before planning around it
>
> **This is a correctness bug wearing a feature request's clothes.** The page
> names the wrong blocker today. A reader following it would wait on a 10DLC
> registration that no longer exists, for a number that was released tonight.
> That is the same failure `Explained.Shaders` recorded on 08-15 — *"found the
> hour the verbs landed, by this page's own claim going false"* — and this
> codebase already treats that as a bug rather than staleness.

---

## Contents

- [Part I — What changed tonight](#part-i--what-changed-tonight)
- [Part II — Every false claim, and the tests that pin it](#part-ii--every-false-claim-and-the-tests-that-pin-it)
- [Part III — Two audiences, one set of facts](#part-iii--two-audiences-one-set-of-facts)
- [Part IV — Recommendation: one source, two renderings](#part-iv--recommendation-one-source-two-renderings)
- [Part V — The phases](#part-v--the-phases)
- [Part VI — Risks](#part-vi--risks)
- [Part VII — Open questions for the operator](#part-vii--open-questions-for-the-operator)

---

## Part I — What changed tonight

| | Before 08-15 | After |
|---|---|---|
| Outbound SMS path | A2P 10DLC | **Toll-free verification** |
| Number | +1 (360) 205-9789 (local) | **+1 (844) 484-8755** (toll-free) |
| Registration | brand + campaign | one verification, no brand, no campaign |
| Cost | $4 + $15 + $2/mo | **free** |
| Wait | days to weeks | 3–5 business days |
| Blocks an individual? | no, but slow | no — `SOLE_PROPRIETOR` is exempt from the 2026 BRN/EIN mandate |

State as of writing: verification `HH0fb442c8ebd7ae71dae79af109d94876` is
**IN_REVIEW**. The 10DLC campaign was deleted before its $15 vetting fee was
charged. Brand `BN6532532434778a9206dd275dce3d23dd` still exists, APPROVED, with
no recurring cost — dormant, not load-bearing. The local number is released.

Two facts worth carrying into the copy because they were expensive to learn:

- **`BusinessType=SOLE_PROPRIETOR` is a required parameter**, and omitting it
  returns a 400 whose message names the exemption. That is the single line that
  makes toll-free viable for a person with no EIN.
- **Toll-free verification requires `BusinessWebsite` and `OptInImageUrls` to be
  publicly fetchable.** A reviewer opens them. This is why the disclosure went
  to the website in the first place, and it does not go away.

---

## Part II — Every false claim, and the tests that pin it

`lib/buster_claw_web/components/explained/phone.ex` (701 lines):

| Line | Claim | Status |
|---|---|---|
| `:29` | outbound SMS "kill-switched behind **Twilio paperwork** (A2P 10DLC)" | **false** — blocker is now toll-free verification |
| `:35` | "A2P status is invisible to `Twilio.send_sms/3`" | still true in shape, wrong in name |
| `:475` | "Twilio's A2P 10DLC registration, filed by you in their Console" | **false twice** — not 10DLC, and it was filed by API, not Console |
| `:489` | "A2P does not apply to \[voice\]" | true, but framed against the wrong gate |
| `:499` | "A2P 10DLC is an SMS gate" | **false as the operative gate** |
| `:530` | "Twilio still classifies an individual's application traffic as A2P" | true and worth keeping — see below |
| `:623` | `needs=` "No A2P registration: that gate is SMS-only" | needs renaming, not deleting |

**`:530` is the one claim to preserve.** Toll-free traffic is still A2P — the
regime didn't stop applying, the *registration mechanism* changed. Rewriting
this page as "A2P doesn't apply anymore" would replace one false claim with a
worse one.

**Tests assert the stale strings**, so the copy cannot change alone:

- `test/buster_claw_web/live/status_live_test.exs`
  - `:1657` — `assert sms_blocker =~ "A2P 10DLC"`
  - `:1660` — `assert voice_blocker =~ "A2P does not apply to"`
  - `:1664` — `assert html =~ "A2P 10DLC is an SMS gate"`
  - `:1667` — comment restating the `send_sms/3` precondition list
- `test/buster_claw_web/live/phone_live_test.exs:272` — comment leaning on the
  A2P framing to explain why a test-mode send fails

These are doing their job: they were written so this page could not silently
drift. Updating them is part of the work, not an obstacle to it.

---

## Part III — Two audiences, one set of facts

The operator's instinct is right and the compliance requirement is also right,
because they are not the same document:

| | In-app | Public website |
|---|---|---|
| Reader | the operator, and people using BusterPhone | a Twilio/carrier reviewer, once |
| Question | "what will this send, and how do I stop it?" | "does a compliant disclosure exist at a URL?" |
| Frequency | often | approximately never |
| Can it be behind the app? | yes | **no — must be fetchable** |

So "move it into the app" cannot mean "delete the public copy." It means the
in-app version becomes the one humans actually read, and the public page stops
pretending to be a product page and becomes what it is: a citation.

**The real risk is drift.** Two hand-maintained copies of a consent disclosure
that disagree is worse than one copy in the wrong place — the mismatch is itself
a compliance finding, and it is exactly the "conflicting or duplicate policies"
condition named in Twilio error 30908. Any plan that leaves two prose copies
lying around will produce that within a month.

---

## Part IV — Recommendation: one source, two renderings

Hold the disclosure **once**, as structured data in the app, and render it twice.

```
BusterClaw.Telephony.Disclosure          # the single source
  ├─ Explained.Phone                     # in-app section, rendered from it
  └─ mix busterphone.disclosure          # emits static HTML for the website
```

- The module holds the facts: opt-in mechanism, keywords, frequency, cost
  language, the non-sharing sentence Twilio requires verbatim, contact.
- `Explained.Phone` renders them inline, in the app's voice.
- A mix task emits `public/busterphone/*.html` for the website repo, so the
  public copy is *generated*, never edited by hand.
- A test asserts the required verbatim sentence survives both renderings.

This makes drift structurally impossible rather than a discipline problem, and
it means the next compliance change is one edit rather than a hunt.

**The honest cost:** the website lives in a *different repo*
(`~/Desktop/websites/hightowerbuilds/BusterClaw-Website`), so the generated
output has to be copied across and committed there. That is a manual step
unless someone wires CI, and a generator whose output is copied by hand is only
half a guarantee. If that seems like over-engineering for two pages, [Part
VII.2](#part-vii--open-questions-for-the-operator) offers the cheaper version.

---

## Part V — The phases

### Phase 1 — Correct the false claims (do this first, independently)

Rename the blocker throughout `phone.ex` from A2P 10DLC to toll-free
verification; keep `:530`'s point that the traffic is still A2P-classified.
Update the four assertions in `status_live_test.exs` and the comment in
`phone_live_test.exs`. **This phase is worth shipping on its own** — it is a
correctness fix and does not depend on anything below.

### Phase 2 — The disclosure section in `Explained.Phone`

Add a section covering the four-step opt-in, the STOP/START/HELP table, the
frequency and rate language, and a link out to the public policy. Content is
already written and reviewed — lift it from
`busterclaw.lol/busterphone/index.html`.

### Phase 3 — Single-source it

Extract `Telephony.Disclosure`, re-point Phase 2's section at it, add the mix
task, regenerate the website pages from it, verify byte-for-byte that the
required sentence survives.

### Phase 4 — Status wiring

`Explained.Phone` currently describes the blocker in prose. It could *read* the
live verification status instead — Twilio exposes it at
`GET /v1/Tollfree/Verifications/{sid}` — and say "in review since 8/15" or
"verified, outbound live" rather than a sentence that goes stale. This is the
phase that stops the page needing a roadmap next time.

---

## Part VI — Risks

1. **Replacing a false claim with a subtler false claim.** "A2P no longer
   applies" would be wrong; the classification still applies, the registration
   route changed. `:530` is the guard against this.
2. **The public page must not be deleted before verification completes.**
   `OptInImageUrls` points at `busterclaw.lol/busterphone/opt-in.png` and a
   reviewer will fetch it during review. Removing it mid-review is a rejection.
3. **Phase 4 adds a live network dependency to a tutorial page.** It must
   degrade to static prose when the call fails; an Explained page that spins or
   errors is worse than one slightly out of date.
4. **Toll-free verification can be rejected.** If it is, the blocker changes
   again, and any copy written as though toll-free is settled becomes the next
   stale claim. Write Phase 2 so the mechanism is named in one place.

---

## Part VII — Open questions for the operator

**VII.1 — Ship Phase 1 now, separately?** The page is wrong tonight. I would fix
the claims immediately and treat the disclosure section as separate work.

**VII.2 — Is single-sourcing worth it, given the cross-repo copy?** The cheap
alternative is to keep the two copies by hand and add a test that the required
sentence appears in the in-app version, accepting that the website copy can
drift. Two pages that change once a year may not justify a generator.

**VII.3 — How much detail in-app?** The website version is written for a
compliance reviewer and reads like it. The in-app version could be much shorter
— four steps, three keywords, one link — with the legal text left on the public
page. My instinct is shorter, but it is a voice decision.

**VII.4 — Should Phase 4 exist at all?** Reading live verification status into a
tutorial is elegant and is also the kind of thing that breaks in three months.
Static prose plus a date might be the more honest surface.

---

## Appendix — Files this touches

| File | Why |
|---|---|
| `lib/buster_claw_web/components/explained/phone.ex` | `:29`, `:35`, `:475`, `:489`, `:499`, `:530`, `:623` |
| `test/buster_claw_web/live/status_live_test.exs` | `:1657`, `:1660`, `:1664`, `:1667` |
| `test/buster_claw_web/live/phone_live_test.exs` | `:272` comment |
| `lib/buster_claw/telephony/disclosure.ex` | new, Phase 3 |
| `../BusterClaw-Website/public/busterphone/*` | generated output, different repo |

**Live state referenced above** — verification
`HH0fb442c8ebd7ae71dae79af109d94876` (REJECTED 08-17, `30484`), number
`+18444848755` (`PN342dccb715b4ba1df2f28304dc00b001`), account **[Twilio Account
SID redacted 08-18 — see below]**, dormant brand
`BN6532532434778a9206dd275dce3d23dd`.

> **The Account SID was redacted when this was archived, and it is worth saying
> why rather than quietly removing it.** GitHub's push protection blocked the
> archiving commit on it — correctly. An `AC…` Account SID is not a password, but
> it is half of Twilio's basic-auth pair and it identifies the account outright,
> and **this repository is open core (MIT, public)**. It sat in a live roadmap
> from 08-15 until 08-18 and was never pushed only because that file happened to
> stay untracked for three days.
>
> The other identifiers are left as written: the verification SID is what the
> operator needs in order to **withdraw** it, the brand SID is what they need to
> delete it, and neither authenticates anything on its own. Find the Account SID
> in the Twilio console or the Clinch, which is where it belongs.
>
> `IN_REVIEW` above was true when written and is corrected here rather than
> silently — the verification was rejected on 08-17, which is what produced
> `PHONE_INTAKE` and therefore this archive.
