# 08-18-26 — A rejection letter, and the cheapest possible answer to it

Twilio rejected the toll-free verification last night. Reason code `30484` —
*Business Name Must Match Official Records*. The application had been filed as
`hightowerbuilds`, which is a GitHub handle and appears on no government record
anywhere. Seven days to resubmit into the prioritized queue.

We did not resubmit. **We deleted the reason to.**

BusterPhone is now intake-only: it answers, records, transcribes, files the
voicemail, and archives inbound text. Every outbound capability is gone —
`sms_send` and `phone_call`, the Twilio client calls behind them, both kill
switches, the caps, the dialler, the keypad, and the DTMF hook. 47 files,
**+1,161 / −2,752**, six files deleted whole.

---

## The structural fact that made it a small decision

Two functions in `telephony/twilio.ex`:

```
sms_ready/0    → kill switch + creds + Messaging Service SID
voice_ready/0  → kill switch + creds + from-number + operator-number
```

Only `sms_ready` touches the Messaging Service, and the Messaging Service is
what toll-free verification governs. **Toll-free verification, A2P, 10DLC,
`OptInImageUrls`, the consent disclosure and error `30484` are all downstream of
one function.** Delete the capability and the entire compliance stack goes with
it in one move — including `SMS_DISCLOSURE_ROADMAP`, whose Part IV had been
proposing a `Telephony.Disclosure` module, a mix task and a cross-repo generator
to keep two hand-written copies of a consent document in sync. That document
stops needing to exist.

> ### The rejection was the occasion, not the argument
>
> A *successful* resubmit would have bought outbound SMS at the price of a
> permanent consent disclosure, a public page that must stay fetchable, a
> business identity on file with a carrier, and a reputation to defend — for a
> capability the product had never used. The email made the price legible. It
> did not create it.

**Outbound calling was never blocked by any of this.** `voice_ready` names four
preconditions and not one is a registration; that is why `phone_call` shipped
08-15 while SMS sat stuck. It was cut anyway, on product grounds, and the
roadmap says so in Part I specifically so that a future reader cannot mistake
this for a paperwork decision and re-add the dialler the moment paperwork
clears. **It was not paperwork.**

---

## Why deletion rather than leaving two kill switches off

Both capabilities were already fail-closed. The argument for deleting them is
the one this codebase keeps relearning:

**A feature that exists must be described, and a description can go false.**

`Explained.Phone` was 701 lines and, as of 08-15, wrong about the SMS blocker in
seven places. It went wrong because a built-but-off feature changed its blocker
while nobody was editing the page. Correcting the prose and keeping the code
buys that same bug again on the next regulatory change. Deletion is the only fix
that holds without discipline.

---

## Seven agents, and what parallelism actually bought

The work was fanned out across seven agents. The obvious split — Phase 1 (SMS)
and Phase 2 (calling) — would have put every agent in the same six files, since
both phases delete from `telephony.ex`, `twilio.ex`, `explained/phone.ex` and
the catalog. **Splitting by file scope instead gave genuinely disjoint writes.**
The cost is that the commits cannot cleanly separate the two phases; the commit
message carries the distinction instead.

One constraint shaped the whole run: **four concurrent `mix compile` runs would
race on the shared `_build`.** So every agent edited from reading only, and the
single compile-and-test pass happened centrally. That worked — the tree compiled
clean with `--warnings-as-errors` on the first attempt, and the full suite came
back with exactly one failure.

The return was not speed. It was **three defects that reading the code had
missed**, each invisible to a different guard.

### 1. The one that would have silently starved the voicemail back-fill

`unpriced_events/1` was listed in the roadmap as surviving untouched. It would
have broken.

Its `where` selected `kind == "voicemail" OR (kind == "call" AND direction ==
"outbound")`. Legacy outbound rows **stay in the database** — deliberately, they
are a true record. But once the outbound `cost_for` clause is deleted, those
rows route to the catch-all and return `{:error, :missing_sids}` *forever*, so
`cost_synced_at` never gets set. The query is **oldest-first with `limit 25`**,
so the permanently-unpriceable rows would have sat at the head of the queue and
starved every voicemail behind them.

> **Two individually-correct decisions — "keep the historical rows" and "delete
> the outbound pricing path" — composing into a defect that neither one
> contains.**
>
> The lesson is this repo's own, restated: *a finding written from reading is a
> lower bound.* Everything in the inventory had been checked for "does it still
> compile". Nothing had been checked for **"does it still make progress"**.

Fixed by narrowing to `kind == "voicemail"`, with a regression test that fails
against *both* halves of the fix independently.

### 2. The hook that two guards could not see

Removing the keypad markup orphaned `assets/js/hooks/dtmf.js` — tripping the
two-way dead-hook guard added 08-13, itself written because the 08-08 Trading
deletion left dead hooks shipping for five days. The inventory had listed **no
JS at all.**

Its sibling was worse. `assets/js/lib/dtmf.js` became dead production code whose
*own test imports it directly* — so `bun test` stayed green, and the hook
registry guard only inspects `hooks/`. **Invisible to both.**

### 3. A settings field that has never worked

`AppKeys.from_env/1` reads `twilio(:phone_number)`. The `:twilio` config map has
never set it — not today, not at `HEAD`, not before. So the
`TWILIO_PHONE_NUMBER` fallback the settings screen advertises to the operator
has **never once resolved.**

It went unnoticed because the only reader was the dialler's caller-ID line, on a
surface that was off by default. It surfaced today only because the Phone tab
now names the number for everyone. A pre-existing bug, fixed here because this
change is what made it reachable.

---

## The inventory covered what the feature was made of, and missed what mentioned it

Every straggler below was found by an agent doing the cut, not by the read that
produced the roadmap:

| Missed | Why it mattered |
|---|---|
| `supabase/SETUP.md` | **nine** stale refs including **two runnable `./buster-claw run` examples**, in the document an operator follows while wiring the relay |
| `assets/js/**` | the `Dtmf` hook and its lib — a *build gate*, not stale prose |
| `shared.ex` `format_dialed/1` | a **public `def`**, so neither `--warnings-as-errors` nor Dialyzer would ever surface it |
| `clinch/app_keys.ex` | a settings field for a deleted capability, and an on-screen note describing a bridge that no longer exists |
| `comms_panel.ex` | tooltips reading *"isn't available **yet**"* — promising a roadmap that was cancelled |
| `priv/repo/seeds/telephony_demo.exs` | the seed **manufactured** the agent texting back *"$120, pickup in Sellwood"* |

That last one is the sharpest. *"Keep existing outbound rows, they are a true
record"* is correct, and it **does not extend to a fixture that fabricates
them.** A seed is not a record; it is an advertisement for a deleted feature,
rendered on the `/phone` tab to anyone who runs the demo. Rewritten inbound-only
— and an unanswered thread is the more honest demo anyway, because the second
and third texts arriving *because the first got no reply* is exactly the texture
a two-way thread was hiding.

### And a gate with a hole in it

`check_docs_drift.sh` validates `./buster-claw` examples against the live
catalog — across `README.md`, `docs/*.md` and `user-guide/*.md`. It does **not**
scan `introduction/` or `supabase/`.

**Thirteen of this cut's stale-example references were invisible to the gate
that exists to catch stale examples**, including the two most dangerous.
Widening the array is the obvious follow-up and was deliberately *not* bundled
in — changing a gate in the same commit that changes what the gate measures
makes neither result mean anything.

---

## Guards kept load-bearing rather than deleted

Deleting an assertion because its subject is gone is correct. Deleting it and
leaving nothing is how the next false claim ships.

- **`introduction_test.exs`** wrapped its briefing assertions in
  `if Commands.command_type("phone_call")` with **no `else`**. Once the command
  left the catalog, that block would never run again and nothing would guard the
  reverse direction. It has an `else` now — and a third block asserting the
  briefing *states the absence out loud*, because a briefing that goes silent on
  the subject lets a model assume a phone can be answered by phone.
- **The dead SMS-vs-voice blocker test** became a test that the page *claims*
  intake-only and preserves the A2P-classification point — including
  `refute =~ "yet"`, because "yet" is the single word by which that claim will
  soften if it ever softens.
- **`phone_live_test`** now flips every telephony switch **on** and proves the
  surface does not come back. That is the direct test of *deleted, not
  disabled* — a surface that returned when config said so would mean the
  deletion was really a default.

---

## The number is also wrong, and that is a cost decision

Toll-free was chosen 08-15 **only to escape 10DLC**, which only ever gated
outbound SMS. With the messaging gone, we are holding the more expensive
instrument for an answering machine: higher monthly rental, and higher inbound
per-minute cost, because with toll-free *the called party pays the caller's
leg*. That is the entire definition of toll-free and a pure cost transfer here.

**But nothing is broken while we stay on it.** Toll-free verification governs
*messaging*; an unverified toll-free number rings, answers and records exactly
like a verified one. So Phase 3 is an economics move with no deadline, not a
repair — worth knowing before churning a **third** number.

| | Number | Fate |
|---|---|---|
| trial | `+1 844 687-8016` | retired 07-18 |
| paid local | `+1 360 364-6763` | released 08-15 |
| toll-free | `+1 844 484-8755` | works today; release when convenient |
| local | *to buy* | the one meant to last |

Churn is free now and will never be cheaper. It stops being free the moment one
of these reaches a user's contacts.

---

## What the paid tier looks like now

Unchanged, and easier to say. `BUSTERPHONE_ROADMAP` settled it on 07-12:
*"Phase 1 (voice/voicemail) is shippable as the paid tier with NO A2P
registration. This is the fastest honest path to revenue. Do not let SMS block
it."*

The paywall is **"we are the phone company, we hold the number"** — untouched.
The marginal cost that makes the price honest is intact. What changed is that
the product is now describable in one sentence with no asterisk: **an answering
machine for your agent.**

---

## Numbers

| | |
|---|---|
| Files | 47 |
| Lines | **+1,161 / −2,752** |
| Deleted whole | `call_flow.ex`, `call_action.ex`, `call_test.exs`, `sms_test.exs`, `hooks/dtmf.js`, `lib/dtmf.js` |
| `telephony.ex` | 598 → **327** |
| `twilio.ex` | 443 → **173** |
| `explained/phone.ex` | 701 → **593** |
| Commands | 217 → **215** |
| Caps lowered | 4 (2 ratchet-forced, 2 because a cap left where a shrunken file used to be stops meaning anything) |
| `mix precommit` | **green** — 4,172 tests, 0 failures |
| `bun test` | 348 pass, hook registry 47/47 |

---

## What is left, and none of it is code

1. **Withdraw verification `HH0fb442c8…`** — tidiness now rather than urgency,
   since the number keeps taking calls either way.
2. **Text the toll-free number once** and confirm inbound SMS lands in the app.
   Voice is certain; this is the one claim today that was reasoned to rather
   than walked. The last confirmed inbound walk was 08-14, on a number released
   the next day.
3. **Release the toll-free number and buy a local one** — when convenient.
   Point the Voice webhook at the new number *before* releasing the old one.
4. **Take down `busterclaw.lol/busterphone/`** — after step 1, not before.
5. **`SMS_DISCLOSURE_ROADMAP` still needs archiving.** It was not touched today:
   it is another session's uncommitted file, and moving it would be taking their
   work. The `SUPERMAP` row marks it cancelled and names where it goes.

---

## Then the thing no amount of code could fix, got fixed

The list above ended with a caveat: `jobs.ex` seeds its job prompts through
`maybe_write`, which never overwrites, so **every existing workspace kept the old
`sms-triage` brief telling the agent to run `sms_send`** — a command that had
just stopped existing. Not a stale default. A broken one, in the file the agent
reads to decide what to do.

That is `QA_BACKLOG` V.8 and `UPDATE_ROADMAP` `G-44`, filed months ago as *"the
one that only matters over years"*, with *"nobody affected"*, scheduled `[R2]`.

**It arrived four months early, and as a correctness bug rather than an
annoyance.** So it got built.

### The mechanism

`BusterClaw.Seed`. Each seed declares every version of itself ever shipped, as
sha256 digests, oldest first. On boot:

| On disk | Outcome |
|---|---|
| nothing | `:created` |
| the current default | `:current` |
| **any earlier shipped version** | `:upgraded` — the operator never touched it |
| anything else | `:kept` — it is theirs |

Bytes, not timestamps, because a timestamp says *when* a file changed and not
*who* changed it.

**One refinement to `G-44` as written.** It retains **digests**, not the prior
text — 64 bytes per version instead of a document, and enough to answer the only
question being asked. The cost is real and named in the module: the app can say
it declined to update a file, but cannot show a diff of what it would have
changed.

### Recovering history, rather than guessing at it

The mechanism is worthless without the digests of what actually shipped. Those
were **recovered from git** by parsing every past revision of `jobs.ex` and
hashing each `default_*` function body — the defaults are pure heredocs with no
interpolation, so the hashes are stable:

| Seed | Shipped versions |
|---|---|
| `mail-triage` | 8 |
| `voicemail-triage` | 8 |
| roster | 5 |
| `sms-triage` | **2** |

An install holding *any* of them upgrades. The pre-08-18 `sms-triage` brief —
`d3aa96c6…`, the one naming `sms_send` — is the first entry in its list, and
there is a test whose only job is to fail if anyone ever removes it.

### The asymmetry that makes it safe, and the guard that makes it honest

**An unrecognised digest is always treated as the operator's.** So the failure
mode of a forgotten version entry is *"a file that could have upgraded didn't"* —
never *"a file the operator wrote got destroyed."*

That safety is also the problem: a stale version list rots **silently**, in the
safe direction, and nothing in the build would ever notice. Every install would
quietly start looking "edited" and stop upgrading forever.

So the list is guarded by a review-forcing snapshot — `SeedTest` pins each
current digest, and editing a default without appending its digest fails the
build *with the digest to add in the message*.

> **Both guards were broken on purpose before being trusted.** Edit a default
> without appending its digest → the manifest test fails. Drop the historical
> `sms_send` digest → the end-to-end test fails with `left: :kept, right:
> :upgraded`. A test written in the same sitting as its code inherits its blind
> spot; the only cure is watching it fail.

The end-to-end tests run against **the real bytes that shipped**, recovered from
git at `89b2de9` and stored as a fixture rather than paraphrased — the actual
workspace an operator was sitting on this morning. One asserts it upgrades off
the `sms_send` brief. The other adds a single line to that same file and asserts
it is left completely alone.

### What was deliberately NOT converted

`memory/policy.md`, the trusted-sender lists, and the agent settings stay
create-only. `G-44` treats every seed as one problem; they are not.

**Those three are security state.** Silently replacing an operator's policy file
at boot — even one that looks unmodified — is a different act from replacing a
job description, and it deserves its own decision about what an automatic
*tightening* may do and whether it should be announced rather than merely logged.

> **A converted `policy.md` would be the first thing in this app that changes a
> security boundary without being asked.** That is not a list append.

`Skills.ensure/0` and `TerminalCommands.ensure/0` remain open — same mechanism,
same shape, digests still to recover.
