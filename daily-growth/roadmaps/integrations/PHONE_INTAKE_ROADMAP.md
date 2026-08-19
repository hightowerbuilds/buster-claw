# BusterPhone — intake only

**Scoped 08-18-26 · Status: PHASES 1, 2, 4 and 5 SHIPPED the same day
(`e08d1cd`, `d9ca4ee`). Phase 0 and Phase 3 are the operator's and are open.**

| Phase | | |
|---|---|---|
| 0 | Withdraw the verification | **OPEN — operator.** Tidiness, not urgency: verification governs *messaging*, so the number answers calls regardless |
| 1 | Delete outbound SMS | ✅ shipped |
| 2 | Delete outbound calling | ✅ shipped |
| 3 | The number move | **OPEN — operator.** A cost decision with no deadline, not a repair |
| 4 | Rewrite `Explained.Phone` as an intake page | ✅ shipped, 701 → 591 |
| 5 | Close the record | ✅ except the website takedown (operator, other repo) |

47 files, **+1,161 / −2,752**. Six files deleted whole. 217 → 215 commands.
`mix precommit` green at 4,187 tests.

> ### The one-sentence version
>
> **BusterPhone stops sending. It answers, records, transcribes, files, and
> archives inbound text — and every outbound capability is deleted rather than
> disabled, because a deleted capability cannot carry a registration, a consent
> obligation, a false sentence about itself, or a carrier's opinion of us.**

> ### What forced it
>
> Twilio rejected the toll-free verification for `+1 844 484-8755` on 08-17
> (`30484` — *Business Name Must Match Official Records*; submitted as
> `hightowerbuilds`, which is a GitHub handle and appears on no government
> record). The prioritized resubmission window closes **~08-24**.
>
> **This roadmap does not resubmit.** It removes the reason to.

> ### Read this before planning around it
>
> **The rejection is the occasion, not the argument.** Even a successful
> resubmit would have bought outbound SMS at the price of a permanent consent
> disclosure, a public page that must stay fetchable, a business identity on
> file with a carrier, and a reputation to defend — for a capability nothing in
> the product has ever needed. The 08-17 email made the price legible. It did
> not create it.

---

## Contents

- [Part I — The structural fact](#part-i--the-structural-fact)
- [Part II — What deletion removes that disabling does not](#part-ii--what-deletion-removes-that-disabling-does-not)
- [Part III — The number is wrong for intake](#part-iii--the-number-is-wrong-for-intake)
- [Part IV — The deletion inventory](#part-iv--the-deletion-inventory)
- [Part V — What survives, untouched](#part-v--what-survives-untouched)
- [Part VI — The gates this trips](#part-vi--the-gates-this-trips)
- [Part VII — The phases](#part-vii--the-phases)
- [Part VIII — Operator-only actions](#part-viii--operator-only-actions)
- [Part IX — Risks](#part-ix--risks)
- [Part X — What this supersedes](#part-x--what-this-supersedes)

---

## Part I — The structural fact

The two readiness gates in `lib/buster_claw/telephony/twilio.ex` are the whole
diagnosis:

```
sms_ready/0   (:360)  → kill switch + creds + Messaging Service SID
voice_ready/0 (:172)  → kill switch + creds + from-number + operator-number
```

**Only `sms_ready` touches the Messaging Service**, and the Messaging Service is
the thing toll-free verification governs. Toll-free verification, A2P, 10DLC,
`OptInImageUrls`, the consent disclosure, and error `30484` are downstream of
one function.

Outbound *voice* was never gated by any of it — `voice_ready` names four
preconditions and not one is a registration. That is why `phone_call` shipped
08-15 while SMS sat blocked.

So the cut is not forced on outbound calling by compliance. **Outbound calling
is being cut on product grounds**, stated plainly in
[Part II](#part-ii--what-deletion-removes-that-disabling-does-not) so nobody
later reads this document as a compliance decision and re-adds the dialler the
moment the paperwork clears. It was not paperwork.

---

## Part II — What deletion removes that disabling does not

Both capabilities are already fail-closed behind kill switches. A reasonable
reader asks why deletion beats leaving two switches off, and the answer is the
reason this codebase already treats stale prose as a bug:

**A feature that exists must be described, and a description can go false.**
`Explained.Phone` is 701 lines and, as of 08-15, is *wrong* about the SMS
blocker in seven places — `SMS_DISCLOSURE_ROADMAP` Part II enumerates them with
line numbers and the four test assertions pinning the stale strings. That page
went false because a built-but-off feature changed its blocker while nobody was
editing the page. Leaving the code and correcting the prose buys the same bug
again on the next regulatory change.

Deletion is the only fix that holds without discipline.

Second, and specific to being the retailer: `BUSTERPHONE_ROADMAP` names abuse
controls as a net-new obligation *because the Twilio account is ours*. An agent
that can be socially engineered into sending a text or dialling a stranger puts
**our** carrier reputation at risk, not a user's. A kill switch defends that
only while it stays off, and its whole purpose is to be turned on someday.

Third, the sharpest caller: `PolicyEngine`'s baseline refuses `gated` commands
to `:agent_untrusted` — the exact caller an unattended run becomes after
touching untrusted email. Both `sms_send` and `phone_call` are `gated: true` for
that reason, and `catalog/telephony.ex:63` records it. Deleting the verbs
removes the class of question rather than answering it correctly forever.

### The compliance stack this deletes outright

| Deleted | Because |
|---|---|
| The toll-free verification `HH0fb442c8…` | nothing left to verify — withdraw, do not resubmit |
| The 08-24 resubmission deadline | moot |
| The business-name problem (`30484`) | no business identity needs to be on file with a carrier |
| `busterclaw.lol/busterphone/` opt-in page + image | existed **only** to satisfy `OptInImageUrls` |
| `SMS_DISCLOSURE_ROADMAP` — all five parts | its subject stops existing |
| `Telephony.Disclosure` + `mix busterphone.disclosure` + the cross-repo copy | Part IV of that roadmap proposed a generator to prevent drift between two copies of a document neither surface would now need |
| ~200 lines of false claims in `Explained.Phone` | fixed by **deletion**, not the rewrite its Phase 1 planned |
| A carrier's standing opinion of us | we stop being a sender |

**The dormant A2P brand `BN6532532434778a9206dd275dce3d23dd`** (APPROVED, no
recurring cost) can stay or go; it costs nothing either way. Deleting it is
tidier and removes a thing a future reader would have to ask about.

---

## Part III — The number is wrong for intake

The 08-15 move to toll-free was made **for one reason: to escape 10DLC**. 10DLC
gates outbound A2P messaging. Cut the messaging and the reason evaporates —
which leaves us holding the more expensive number for an answering machine.

Toll-free is the wrong instrument here on both axes:

- **Higher monthly rental** than a local DID.
- **Higher inbound per-minute cost** — with toll-free, *the called party pays
  for the caller's leg*. That is the entire product definition of toll-free. For
  an answering machine it is a pure cost transfer onto us, per minute, forever.

Toll-free buys exactly one thing: free for the caller. That matters for a
support line a stranger dials. It does not matter for a personal answering
machine whose callers are dialling a person they already know.

> **Verify current rates in the Twilio console before acting.** The direction of
> the comparison is structural and will not have changed; the magnitudes are not
> quoted here because a stale number in a roadmap is how this file becomes the
> next thing that lies.

**Inbound-only needs no registration on a local number.** 10DLC governs outbound
A2P messaging; receiving is unregistered-fine. So the local number carries no
paperwork at all once outbound SMS is gone.

### The cost that is not money

This would be the **third number**:

| | Number | Fate |
|---|---|---|
| trial | `+1 844 687-8016` | retired 07-18 |
| paid local | `+1 360 364-6763` | released 08-15 |
| toll-free | `+1 844 484-8755` | released by this roadmap |
| **local** | *to buy* | the one intended to last |

Churn is cheap now and will never be cheaper — nothing is published, nobody
external holds any of these. It stops being cheap the moment one appears in a
user's contacts. **This is the last free number change**, and the roadmap says
so here rather than discovering it later.

---

## Part IV — The deletion inventory

Measured 08-18 against `main`. Line numbers are where the symbol is defined.

### Command surface

| File | What goes |
|---|---|
| `commands/catalog/telephony.ex` | `sms_send` (`:52`), `phone_call` (`:74`) and the 11-line comment above it (`:63`) |
| `commands/telephony.ex` | `sms_send/1` (`:47`–`:52`), `phone_call/1` (`:63`–`:64`) |
| `commands.ex` | two `defdelegate`s (`:795`, `:796`) |

**217 commands → 215.** Both are `type: :mutate, tier: :restricted, gated:
true`, so the derived counts in `explained/registry.ex` `@command_stats` move:
`total 217→215`, `mutate 112→110`, `restricted 126→124`, `gated 25→23`.
`read`, `trigger` and `safe` are unchanged.

### Context — `telephony.ex` (598 lines; ~280 go, near half the file)

`send_sms/3` (`:54`) · `place_call/2` (`:77`) · `called_today/1` (`:86`) ·
`sent_today_to/1` (`:99`) · `sms_opted_out?/1` (`:112`) · `deliver_sms/3`
(`:130`) · `sms_consent_event/1` (`:147`) · `deliver_call/2` (`:158`) ·
`persist_outbound_call/2` (`:175`) · `observe_call_place/3` (`:203`) ·
`call_daily_cap/1` (`:220`) · `persist_outbound_sms/3` (`:231`) ·
`observe_sms_send/3` (`:277`) · `normalize_recipient/1` (`:291`) ·
`validate_sms_body/1` (`:298`) · `sms_daily_cap/1` (`:308`)

> **`sms_opted_out?` and `sms_consent_event` go too**, and the reason is worth
> stating because it looks like consent handling being removed. They exist
> **only** to gate our own outbound sends (`deliver_sms` is the sole caller).
> With nothing outbound, STOP/START keywords are Twilio's business at the
> carrier level and ours to *archive*, not to enforce against. Inbound STOP
> messages still land in the ledger like any other text.

### REST client — `twilio.ex` (443 lines; ~200 go)

`send_sms/3` (`:52`) · `place_call/2` (`:105`) · `bridge_twiml/1` (`:134`) ·
`refuse_self_dial/1` (`:150`) · `voice_ready/0` (`:172`) · `sms_ready/0`
(`:360`) · `messaging_service_sid/0` (`:430`) · `sms_enabled?/0` (`:431`) ·
`voice_enabled?/0` (`:437`) · `operator_number/0` (`:439`) ·
`validate_recipient` / `validate_body` / `normalize_sms_response`

**Cost logic splits, and the split is the sharp edge.** `cost_for/2` has two
clauses:

- `cost_for(%{call_sid: _})` (`:255`) plus the `ParentCallSid` child-leg fetch
  (`:301`–`:306`) price an **outbound bridged call** — two billed legs. **Both
  go.**
- `cost_for(%{recording_sid: _})` (`:223`) prices a **voicemail** and internally
  fetches the parent `Calls/{CallSid}` resource for the *inbound* leg. **This
  stays.** It reads a call resource, which makes it look like outbound-call
  code; it is not. Deleting it silently un-prices every voicemail.

The moduledoc (`:1`–`:40`) documents both and must be rewritten, not trimmed.

### Web

| File | What goes |
|---|---|
| `live/phone/call_flow.ex` | **whole file** (105) |
| `components/phone/call_action.ex` | **whole file** (187) |
| `live/phone_component.ex` | `@keypad_keys` (`:70`) and the dial/call handlers |
| `components/phone/playback.ex` | the keypad section and its `:100` comment |
| `components/explained/phone.ex` | the outbound sections — `:401`, `:407`, `:470`, `:518`, `:623`, `:666`, and the moduledoc's `:29`–`:39` |
| `components/explained/cmd.ex` | `:305`, `:315` |
| `components/explained/registry.ex` | `@command_stats`, and the 08-15 `phone_call` provenance comment |

> **The keypad question.** `call_action.ex:14` records that `G-37` closed by
> *labelling the keypad in place* — it was decorative, got labelled, then became
> real when `phone_call` shipped. Removing the dialler returns it to decorative,
> which is the state `G-37` already judged unacceptable. **So the keypad is
> deleted, not re-labelled.** Reopening `G-37` by leaving dead buttons on screen
> would be the worst of the three states.

### Prompts, config, docs

| File | What goes |
|---|---|
| `jobs.ex` | `:242`, `:328`, `:336` — `sms_send` in the agent's job prompt |
| `commands/dispatch.ex` | `:108` comment pointing phone replies at `sms_send` |
| `config/runtime.exs` | `:119`–`:146` — `messaging_service_sid`, `sms_enabled`, `voice_enabled`, `sms_daily_recipient_cap`, and the comment block explaining two switches |
| `README.md` | `:5`, `:25` (217→215) and **`:31`** — see below |
| `docs/COMMAND_SURFACE.md` | `:25` (217→215) |
| `docs/ARCHITECTURE.md` | `:29` — **see correction below** |
| `introduction/01-orientation.md` | `:21` |
| `introduction/03-jobs-and-phone.md` | `:98`, `:107`, `:124`, `:126` |
| `introduction/07-notify-memory-shaders.md` | `:45` — *conditionally*. The WGSL shader is **named** `keypad` and survives as the Playback backdrop; only the keypad **UI** goes. Fix only if the line describes a pressable keypad |
| **`supabase/SETUP.md`** | **`:98`, `:103`, `:209`, `:217`, `:243`, `:252`, `:253`, `:266`, `:277`** — nine refs incl. **two live `./buster-claw run` examples** |

> **Correction, 08-18: this table originally claimed `docs/ARCHITECTURE.md` "mentions
> outbound". It did not** — at `HEAD` that line already described inbound only. The
> edit actually made was to state the *absence* explicitly, so outbound cannot be
> quietly re-added later. Recorded rather than silently fixed: an inventory that
> invents a defect is the same class of error as one that misses a real one, and this
> document is asking to be trusted on ~30 other file:line claims.

> **`supabase/SETUP.md` was missed entirely by the first inventory pass**, and it is
> the worst single omission — two runnable `./buster-claw run` examples for deleted
> commands, in the document an operator follows while wiring up the relay.

> **`README.md:31` is already false today**, independent of this roadmap: it
> says *"Outbound calling is not built and the dialpad remains decorative"*
> when `phone_call` shipped 08-15 and the keypad is wired to it. It happens to
> become true again when Phase 2 lands, which is the most dangerous way for a
> false sentence to survive — **rewrite it, do not leave it to be accidentally
> correct.**

### Found during execution — absent from the inventory above

Every one of these was found by an agent doing the cut, not by the read that
produced this document. Recorded because the pattern matters more than the list:
**the inventory covered what the feature was made of, and missed what merely
mentioned it.**

| File | What |
|---|---|
| `assets/js/hooks/dtmf.js` + `hooks/index.js` | the keypad's DTMF hook. Part IV listed **no JS at all**. Removing the keypad markup orphaned it and tripped `hooks_registered_test.exs` — the two-way dead-hook guard added 08-13 *because* the 08-08 Trading deletion left dead hooks shipping for five days |
| `assets/js/lib/dtmf.js` + `lib/dtmf.test.js` | dead production code, and **invisible to both guards**: its own test imports it directly so `bun test` stays green, and the hook-registry guard only inspects `hooks/` |
| `components/phone/shared.ex` | `format_dialed/1` orphaned — a **public `def`**, so neither `--warnings-as-errors` nor Dialyzer would ever surface it. Also `priced_kind?` at `:91`, which advertises a Cost line on legacy outbound rows that can never price again |
| `clinch/app_keys.ex` | `twilio_messaging_service_sid` still operator-settable for a deleted capability; `:69` and `:108` notes describe placing and bridging calls — **`:108` renders on screen** |
| `components/phone/registry.ex` | the Messages tab blurb — *"The log, the keypad, and whatever is playing"* — rendered as the tab's `title=` |
| `components/widget/comms_panel.ex` | `:26` comment doubly false (the dialpad was not decorative, and now does not exist); `:99`/`:110` tooltips say *"isn't available **yet**"*, promising a roadmap that was cancelled |
| `notifications/sound_gen.ex` | `:10` cites a client-side WebAudio dialpad that no longer exists |
| `supabase/functions/sms/index.ts` | `:5` names a Messaging Service that is no longer in the path; `:12` gives a **false reason** for correct behaviour — empty TwiML was "replies are policy-gated on the Mac", now it is "there is no reply path" |
| `priv/repo/seeds/telephony_demo.exs` | **the sharpest of these.** The demo seed *manufactured* outbound SMS rows — the agent answering *"$120, pickup in Sellwood"*. Part V's "keep existing outbound rows, they are a true record" does **not** extend to a seed: a fixture that fabricates them is not a record, it is an advertisement for a deleted feature, rendered on the `/phone` tab to anyone who runs the demo. Rewritten inbound-only |

> **`introduction/07-notify-memory-shaders.md:45` was checked and deliberately
> NOT changed.** It lists shader consumers by what each draws — *"the animated
> face, the phone keypad, the seven-segment clock, the day-cycle sky"*. The
> WGSL shader named `keypad` still exists and still renders as the Playback
> backdrop; only the pressable keypad went. The obvious edit would have deleted
> a true statement. Noted because the next reader will have the same instinct.

### Tests

| File | What |
|---|---|
| `telephony/call_test.exs` (265) | **delete whole** |
| `telephony/sms_test.exs` (112) | **delete whole** |
| `telephony/twilio_test.exs` (210) | partial — outbound cases out, `cost_for` voicemail cases stay |
| `telephony/cost_test.exs` (244) | partial — the bridged-call two-leg cases go |
| `commands/telephony_test.exs` (175) | partial |
| `phone_live_test.exs` (556) | partial, incl. the A2P comment at `:271`–`:275` |
| `status_live_test.exs` | `:1726`, `:1729`, `:1733`, `:1736` and the `@command_stats` drift assertion |

> **Those four assertions moved.** `SMS_DISCLOSURE_ROADMAP` recorded them at
> `:1657`–`:1667` on 08-15; they are at `:1726`–`:1736` today, because the file
> grew underneath them. Verified 08-18. **Re-grep rather than trusting any line
> number in this table** — including these, by the time you read it.
| `jobs_test.exs`, `introduction_test.exs` | prompt/doc assertions |

**Estimated total: ~1,500–2,000 lines deleted.** An estimate, not a measurement
— record the real figure in the closing summary.

---

## Part V — What survives, untouched

Nothing in the intake path is touched. Stated explicitly because "cut the phone
feature" is not what this is:

- **Inbound voice** — greeting → beep → record → transcribe → file in the
  Library. The product.
- **Inbound SMS** — archived; trusted-number texts still enter `sms-triage`.
- **The relay + drain** — `telephony/relay.ex`, `telephony/drain.ex` (386)
  entirely unchanged. Persist-then-ack, transcript grace, PostgREST polling.
- **The ledger** — `Event`, `list_events`, `thread_messages`, `sms_threads`,
  `stats`, `unheard_count`, `mark_heard`.
- **Trust and PINs** — `TrustedNumbers`, `telephony/pins.ex` (170), and the six
  `phone_trusted_*` / `phone_pin_*` commands. These gate *what inbound becomes
  queue work* and are more load-bearing now, not less.
- **Voicemail cost back-fill** — `cost_for(%{recording_sid: _})` and
  `refresh_unpriced_costs`.
- **The remaining ten commands** — `phone_list`, `phone_get`, `phone_stats`,
  `phone_mark_heard`, three `phone_trusted_*`, three `phone_pin_*`.

**Existing `direction: "outbound"` rows stay in the database.** No migration, no
backfill, no deletion — they are a true record of what happened. The code simply
stops creating new ones. The `Event` schema keeps the field.

### The paywall survives, and this is the roadmap's own prior conclusion

`BUSTERPHONE_ROADMAP` settled it on 07-12: *"Phase 1 (voice/voicemail) is
shippable as the paid tier with NO A2P registration. This is the fastest honest
path to revenue. Do not let SMS block it."*

The paywall is **"we are the phone company, we hold the number."** Intake-only
does not touch that — and the marginal cost that makes the price honest (a
number, a relay, per-minute inbound) is entirely intact. What changes is that
the paid tier is now describable in one sentence with no asterisk.

---

## Part VI — The gates this trips

Deletion at this scale sets off machinery built to notice exactly this. All of
it must move in the **same commit** as the cut.

1. **`scripts/check_file_sizes.sh` fails in both directions.** Two distinct
   failures:
   - **Deleted files must lose their `check` lines** — the script fails when a
     capped path does not exist: `live/phone/call_flow.ex` (`:853`),
     `components/phone/call_action.ex` (`:854`).
   - **The ratchet fires on shrinkage.** A file below 80% of its cap fails so
     the cap gets lowered in the commit that earns it. `telephony.ex` (cap 630,
     `:1307`) and `explained/phone.ex` (cap 710, `:168`) will both trip hard;
     `phone_component.ex` (590, `:847`) and `phone/playback.ex` (314, `:198`)
     likely will. **This is the gate working**, not an obstacle.
2. **The Explained drift test** — `status_live_test.exs`, *"the Command List tab
   is the atlas"*, derives the real counts from `Commands.list_commands/0` and
   compares them to `registry.ex`'s `@command_stats`. It caught `phone_call`
   within the hour it landed; it will catch its removal.
3. **`scripts/check_docs_drift.sh`** — validates `./buster-claw <verb>` examples
   in `README.md`, `docs/*.md`, `user-guide/*.md` against the live catalog. Any
   surviving `sms_send` / `phone_call` example fails CI.

   > **The gap is bigger than it looks, and it is the finding of this pass.** That
   > `DOCS` array is `README.md docs/*.md user-guide/*.md`. It does **not** scan
   > `introduction/` (4 stale refs) or `supabase/` (9, including two runnable
   > examples). **Thirteen of this roadmap's stale-example references are invisible
   > to the gate that exists to catch stale examples** — and the two most dangerous,
   > because `supabase/SETUP.md` is what an operator follows while setting the relay
   > up. `user-guide/` was checked and is clean. **Fix all thirteen by hand; nothing
   > will tell you if you miss one.** Widening `DOCS` to cover both directories is
   > the obvious follow-up and is deliberately *not* bundled into this roadmap —
   > it would change the gate in the same commit that changes what the gate
   > measures, and then neither result means anything.
4. **`mix precommit`** — `--warnings-as-errors` catches orphaned aliases and
   now-unused privates; `credo --strict` catches the rest.
5. **Dialyzer** — deleting a caller can strand a clause as unreachable. The
   08-16 lesson applies: **delete unreachable clauses, do not baseline them.**

---

## Part VII — The phases

### Phase 0 — Stop the clock *(operator, today)*

Withdraw verification `HH0fb442c8ebd7ae71dae79af109d94876`. No resubmit. This
is independent of every phase below and should not wait on any of them.

### Phase 1 — Delete outbound SMS

Everything in [Part IV](#part-iv--the-deletion-inventory) marked SMS: the
command, the context and client functions, the caps, the opt-out gate, the
Messaging Service config, the kill switch, the `Explained` sections, the tests.

**Ships on its own.** It is the phase that retires the compliance stack, and it
does not depend on the number move or on Phase 2.

### Phase 2 — Delete outbound calling

`phone_call`, `place_call`, the bridge TwiML, the self-dial guard, the voice
kill switch, `call_flow.ex`, `call_action.ex`, the keypad, and the
outbound-bridged-call branch of `cost_for/2`.

Separate from Phase 1 **because the reasons are different** — Phase 1 is
compliance, Phase 2 is product surface — and separating them keeps the commit
messages honest about which argument moved which code.

### Phase 3 — The number move *(operator + code)*

Release `+1 844 484-8755`, buy a local number, re-point the Voice webhook at the
relay, verify an end-to-end inbound call and inbound SMS **in the app**, and
update every recorded instance of the number.

> **Sequence matters.** The webhook must point at the new number *before* the
> old one is released, or inbound is dark in between.

### Phase 4 — Rewrite `Explained.Phone` as an intake page

Not a trim. The page is currently organised around what the phone *cannot yet
do* and why — a structure with no subject once nothing is pending. Rewrite it
around what intake *is*: who may reach you, what happens to a message, what the
trust and PIN gates decide, what it costs.

**Keep the point at `:527`–`:531`** (*"Twilio still classifies an individual's
application traffic as A2P"*, verified 08-18) — that inbound traffic is still
A2P-*classified*.
It survives the deletion of everything around it and is the guard against the
page's next false claim, which would be *"A2P does not apply to us."* The
regime always applied; we simply stopped being a sender.

### Phase 5 — Close the record ✅ *(done 08-18, except the website)*

- [x] `SMS_DISCLOSURE_ROADMAP.md` archived to
      `archive/08-18-26-sms-disclosure.md`, cancelled unbuilt, with **where its
      leftover went** recorded per the archiving convention — Part II was
      consumed by Phase 4's rewrite, not orphaned.
- [x] `SUPERMAP` Part VI rows updated; the folder tree no longer lists it.
- [x] A forward pointer added to `archive/08-17-26-outbound-voice.md`. That map
      still said **COMPLETE, nothing open** for a feature deleted the next day,
      which reads as "this works". The pointer is *added above* the header; the
      body is untouched.
- [ ] Take down `busterclaw.lol/busterphone/` — **only after Phase 0 is
      confirmed withdrawn**, see [Part IX](#part-ix--risks). Operator's, and in
      another repo.

---

## Part VIII — Operator-only actions

No agent can do any of these:

1. **Withdraw the toll-free verification** (Twilio Console / Messaging
   Compliance API).
2. **Release `+1 844 484-8755`.**
3. **Buy the replacement local number** and re-point the Voice webhook.
4. **Delete or keep** the dormant A2P brand `BN6532532434778a9206dd275dce3d23dd`.
5. **Take down `busterclaw.lol/busterphone/`** — a different repo
   (`~/Desktop/websites/hightowerbuilds/BusterClaw-Website`).
6. **Place a real inbound call and text** to the new number and confirm both
   land in the app. The 08-14 lesson stands: this page did not know inbound was
   live until somebody opened the app.

---

## Part IX — Risks

1. **Taking the website page down before the verification is withdrawn.**
   `SMS_DISCLOSURE_ROADMAP` Part VI.2 warns that a reviewer fetches
   `OptInImageUrls` mid-review; removing it is a rejection. That inverts here —
   we *want* the rejection — but the honest order is still **withdraw first,
   then delete**, so nothing is left half-filed against a URL that 404s.
2. **Deleting `cost_for(%{recording_sid: _})` by association.** It reads a
   `Calls` resource and looks like outbound-call code. It prices every
   voicemail. `cost_test.exs` should fail loudly if this is got wrong —
   **verify that it does before starting**, per this repo's break-the-guard
   rule. A guard written in the same sitting as its code inherits its blind
   spot.

   > ### 2b. The one this roadmap got WRONG, found during execution 08-18
   >
   > Part V lists `unpriced_events/1` as surviving untouched. **That would have
   > silently starved the voicemail cost back-fill**, and no test or compiler
   > check would have said so.
   >
   > Its `where` selected `kind == "voicemail" OR (kind == "call" AND direction
   > == "outbound")`. Legacy outbound rows **stay in the database** — Part V
   > says so, correctly. But once the outbound `cost_for` clause is deleted,
   > those rows route to the catch-all and return `{:error, :missing_sids}`
   > *forever*, so `cost_synced_at` never gets set. The query is **oldest-first
   > with `limit 25`**, so the permanently-unpriceable legacy rows sit at the
   > head of the queue and starve every voicemail behind them.
   >
   > Fixed by narrowing `unpriced_events/1` and `cost_sids/1` to
   > `kind == "voicemail"`. A regression test pins it.
   >
   > **The lesson is this repo's own, restated:** *a finding written from
   > reading is a lower bound.* Two decisions that are individually correct —
   > "keep the historical rows" and "delete the outbound pricing path" —
   > combined into a defect that neither one contains. **Deletion inventories
   > must trace what SURVIVES into the deleted paths, not only what dies.**
   > Everything in Part V was checked for "does it still compile", and nothing
   > was checked for "does it still make progress".
3. **Re-adding the dialler later on compliance grounds.** Outbound voice was
   never blocked by paperwork; if it returns, it must return on a product
   argument. [Part I](#part-i--the-structural-fact) exists so a future reader
   cannot mistake this for a paperwork decision.
4. **The keypad returning as decoration.** `G-37` already ruled on that state.
   See Part IV.
5. **A stale number in a user's hands.** Not a risk today; the reason Part III
   calls this the last free change.
6. **Losing the argument.** The most likely failure is that in three months
   somebody reads "intake only" as timidity and rebuilds outbound without
   reading this file. The counter is that the deletion commits cite this
   roadmap, and Part II states the price rather than merely the decision.

---

## Part X — What this supersedes

| Document | Effect |
|---|---|
| `SMS_DISCLOSURE_ROADMAP` → [`archive/08-18-26-sms-disclosure.md`](../../archive/08-18-26-sms-disclosure.md) | **Superseded whole; cancelled unbuilt and archived 08-18.** Its Part II inventory of false claims was **consumed by Phase 4, not orphaned** — it is the map that rewrote the page, and the one claim it said to preserve (inbound traffic is still A2P-*classified*) is still there under `[data-phone-a2p]` |
| [`BUSTERPHONE_ROADMAP`](BUSTERPHONE_ROADMAP.md) Phase 2 (SMS) | **Cancelled.** Phase 1 (voice/voicemail) is unaffected and remains the paid tier |
| `SUPERMAP` Part VI | rows *Outgoing texts* (`:309`), *The SMS consent story* (`:310`), *Outgoing calls* (`:311`) all resolve to **DELETED**; the *Twilio / BusterPhone* row (`:308`) needs its "the only thing this phone cannot do is send a text" framing rewritten — that stops being a limitation and becomes the design |
| `OUTBOUND_VOICE_ROADMAP` (archived 08-17, COMPLETE) | its subject is deleted. **The body stays exactly as written** — it was true and finished when filed. A dated forward pointer was *added above* its header on 08-18, because "COMPLETE, nothing open" is read as "this works". Adding a pointer is not rewriting a record; editing the body would be |

> The last row is this repo's own rule, from the 08-17 handling of `VI.0b`:
> *"Rewriting history to match the present is how a record stops being one."*

---

## Part XI — Open questions for the operator

**XI.1 — Local number, and which area code?** `360` was the previous local
number (Washington). Same area code again, or one matching where the product is
sold from?

**XI.2 — Keep or delete the dormant A2P brand?** No cost either way. Deleting
removes a thing a future reader must ask about; keeping preserves an approved
registration if outbound SMS is ever revisited. **Recommendation: delete** — a
dormant approval is exactly the kind of artifact that makes a future reader
think outbound is nearly free.

**XI.3 — Does the paid tier's description change?** "An answering machine for
your agent" is a cleaner sentence than what BusterPhone has been able to claim
so far. Worth deciding before the website is touched, so the takedown and the
new copy are one edit.
