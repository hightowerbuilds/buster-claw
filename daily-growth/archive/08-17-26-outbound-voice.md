> ## ARCHIVED 2026-08-17 — complete, and one phase deleted by the build
>
> > ### 2026-08-18, one day later: THE FEATURE THIS MAP BUILT IS DELETED.
> >
> > Outbound calling was removed whole when BusterPhone became intake-only —
> > `phone_call`, `place_call/2`, the bridge TwiML, the self-dial guard, the
> > voice kill switch, `call_flow.ex`, `call_action.ex` and the keypad. See
> > [`PHONE_INTAKE`](../roadmaps/integrations/PHONE_INTAKE_ROADMAP.md).
> >
> > **It was cut on product grounds, not paperwork.** Nothing below was wrong and
> > nothing below failed: `voice_ready/0` never required a registration, which is
> > exactly why this shipped 08-15 while SMS sat blocked. That remains the most
> > useful fact in this document.
> >
> > **The body below is left exactly as written.** It was true and finished when
> > filed, and rewriting a record to match the present is how it stops being one.
> > This pointer is added rather than edited in, because an archived map saying
> > "COMPLETE, nothing open" is otherwise read as "this works" — and it no longer
> > does.
>
> Scoped and finished 08-15. Phases 1, 3 and 4 shipped with the cost back-fill;
> Phase 0 was the operator's call. **Nothing was open when this closed.**
>
> **Phase 2 was deleted rather than skipped, and that is the reusable part.** It
> scoped a Supabase function serving `<Dial>` TwiML behind a signature check and
> an opaque id — none of which was needed, because Twilio's Calls API takes the
> document inline. The phase and its headline risk went together: there is no
> public endpoint to abuse because there is no public endpoint.

# Outbound voice — making the rotary dial real

**Scoped 08-15-26 · Status: COMPLETE 08-15. Phases 1, 3 and 4 shipped with the
cost back-fill; Phase 2 was deleted by the build; Phase 0 decided by the
operator. Nothing here is open.**

> ### Phase 2 was deleted by the build, not skipped
>
> It scoped a Supabase function serving `<Dial>` TwiML, with a signature check,
> a `PUBLIC_URL_BASE`, and an opaque id so a public endpoint could not be made
> to dial an arbitrary number. **None of it was needed.** Twilio's Calls API
> takes a `Twiml` parameter carrying the document inline, so the instruction
> travels with the request that creates the call.
>
> That removes the phase and its headline risk together: **there is no public
> endpoint to abuse**, and the number dialled cannot arrive from a callback
> because nothing calls back. It is composed on the Mac from a value that was
> validated there. The "toll fraud through the public bridge endpoint" risk
> below is therefore struck rather than mitigated.
>
> It also leaves the Mac-never-in-the-synchronous-path rule fully intact: the
> Mac initiates and is never called back.

Operator asked for outgoing calls alongside outgoing texts; those turned out to
be two different problems and this is the half that is ours.

Sibling of [`BUSTERPHONE`](BUSTERPHONE_ROADMAP.md), which owns the number, the
relay, the drain and inbound. Nothing here changes any of that.

---

## The one fact that reorders everything

**Outbound voice needs no A2P 10DLC.** That registration grind — the one that
currently has the operator's Twilio account misclassified as a business — is an
**SMS gate**. It does not touch voice, inbound or outbound.

So the two halves of "let my phone make calls and texts" have opposite shapes:

| | Blocked by | Who unblocks it |
|---|---|---|
| Outgoing **texts** | Twilio A2P registration (paperwork) | the operator, in Console |
| Outgoing **calls** | nothing at Twilio — **it is unbuilt** | us |

`sms_send` has existed since 07-18, kill-switched, waiting on approval. *As
scoped,* there was **no outbound call path at all**: `Telephony.Twilio` created
messages and read call/recording/transcription resources, and never POSTed to
`Calls`. The keypad on `/phone` said so on its face — *"Searches your contacts ·
outbound calling isn't built"* — which is the honest placeholder this roadmap
existed to retire. **Both halves are gone as of 08-15**; the table above is the
scoping snapshot, not the state of the tree.

---

## The constraint that picks the design

**The Mac is never in the synchronous path.** It is the rule the whole telephony
stack is built on and `voice/index.ts` states it at the top: Twilio talks to a
Supabase edge function, the function answers in milliseconds, and the Mac
*polls* `telephony_events` on its own schedule. A laptop that sleeps must not be
able to make a caller hear silence.

Outbound bends this exactly once and it is worth being precise about how. The
Mac may **initiate** — a REST POST to Twilio is an outbound HTTP call the Mac
already makes for `send_sms`, and if it fails, nobody is on the line. What the
Mac may never do is be the thing Twilio *calls back* for TwiML. That stays with
the relay.

### Three ways to make a call, and why the order is what it is

**Option A — the app speaks (announce call).** POST `/Calls` with inline
`Twiml` containing `<Say>`. Twilio dials, reads a sentence, hangs up.

*Cheapest to build and the most dangerous thing in this document.* One leg, no
audio path, no bridging — and it is a robocall generator. An agent that can
place a call and speak into it, unattended, is a category beyond anything the
command surface currently holds. **Deferred deliberately**, and if it is ever
built it is gated, capped, and never reachable by an untrusted caller. See the
tiering section.

**Option B — bridge to the operator's own phone (click-to-call). ← build this.**
Twilio calls the **operator's** mobile first. When they answer, the TwiML dials
the target and bridges the two legs. The operator talks on their own phone; the
app is a dialer, not a telephone.

Why this one:

- **No audio ever touches the Mac.** No microphone, no speaker, no WebRTC.
- **It sidesteps the unknown that is blocking Studio → Voice.** A softphone in
  the app needs `getUserMedia` inside WKWebView, which is precisely the V.4a
  spike that has not been run. Bridging needs none of it, so outbound calling
  does not have to queue behind a microphone question.
- **It reuses the relay pattern exactly** — TwiML from the edge function, the
  Mac only initiating.
- The operator's phone rings, which is its own consent gesture: a call cannot
  happen while they are away from their phone.

Cost is the honest trade: **two legs, both billed.**

**Option C — a real softphone (Twilio Voice JS SDK + WebRTC).** Talk from the
Mac. **Blocked on V.4a** and a token endpoint, and it is a much larger build.
Not scoped here beyond naming the dependency, so nobody rediscovers it as
"obvious".

---

## Phase 0 — The identity of a call ✅ DECIDED 08-15 (operator)

> **Outbound calls present the app's number, +1 (360) 364-6763.** Not deferred,
> not conditional on a second number existing. The person being called sees the
> agent's line, and that is the product rather than a compromise with it.

The question every other phase inherited: **when Buster Claw calls someone, who is
calling?** Three consequences follow, and they are consequences of the decision
rather than arguments against it.

**A callback reaches the answering machine, not the operator.** This is the half
worth internalising before using it for something where a return call matters. It
is also sharper than it first sounds: that callback is an *inbound* call from a
number that is almost certainly **not on the trusted list**, so it is recorded,
transcribed and archived — and never becomes agent work. Call the print shop, and
their call back is a voicemail you have to go and listen to. The trust gate does
not know you dialled them first, and deliberately so: "we called them" is not
consent for them to drive the queue.

**Reputation is behavioural, and there is no paperwork that fixes it.** A new
number placing outbound calls can be spam-flagged, and unlike SMS there is no A2P
equivalent to register your way out of it. The only lever is how the number is
used over time — which is an argument for the per-recipient cap of 5 being low
rather than generous.

**The operator's own number never leaves the machine.** It is `To` on leg one and
appears nowhere else — not as `From`, not as `callerId`. That is now a test rather
than a property of how the code happens to be written today: the request asserts
the operator's number occurs **exactly once**, so wiring it into caller ID fails
the suite instead of quietly handing a stranger the operator's mobile.

**Not decided, and not needed:** a second number. The one-number design is what
makes a callback land on the answering machine, which is the behaviour above. If
a second number is ever bought it reopens this, not the phases below it.

**Exit:** met — stated here by the operator, and pinned by
`test/buster_claw/telephony/call_test.exs`.

---

## Phase 1 — `Twilio.place_call/3`, the REST half ✅ SHIPPED 08-15

The smallest honest unit: a function that creates a call and returns a receipt.

- `POST /2010-04-01/Accounts/{sid}/Calls.json` with `To` = **the operator's own
  phone**, `From` = the owned number, and `Twiml` carrying
  `<Dial callerId="…">target</Dial>` inline. **No `Url`** — see the header for
  why that deleted Phase 2.
- Mirror `send_sms/3`'s shape exactly, including its precondition style: a
  `voice_ready` that names *which* precondition is missing, and **no public
  boolean twin** — that module's moduledoc records why a second copy of the
  conditions drifts out of step with the tagged errors.
  **Amended by Phase 4:** `voice_ready/0` is public. The rule it was protecting
  was never "keep it private", it was "one copy of the conditions" — and the Call
  button needs the *reason*, not a boolean. Exporting the same function is the
  rule kept; a `voice_ready?/0` beside it would have been the rule broken.
- Preconditions: Twilio configured, the owned number present, and an explicit
  **`voice_enabled` kill switch, separate from `sms_enabled`**. Two capabilities,
  two switches; a text is not a phone call.

**Cost back-fill is nearly free** and should land in the same phase.
`cost_for/2` already sums a call leg from `Calls/{CallSid}`, so an outbound call
is a resource it can already price — the only new work is that a bridged call
has **two** legs and the parent/child relationship has to be walked. Price
settles asynchronously; the existing retry posture applies unchanged.

**Exit:** a call to the operator's own phone connects, and a row lands with a
`call_sid` that `cost_for/2` can price.

**Shipped with two refusals the scope did not think of**, both found by writing
the tests: dialling the app's own number bridges it to its own answering machine
(two billed legs and a voicemail from the operator to themselves), and dialling
the operator's own number bridges them to themselves. Both are
`:cannot_dial_own_number` / `:cannot_dial_yourself` rather than something Twilio
discovers.

**The cost back-fill landed 08-15**, and the scope was right that it was real
work rather than free. `cost_for/2` gained a `%{call_sid: _}` shape that reads
the parent and then `Calls?ParentCallSid=`, because `<Dial>` creates a **second
call resource** with its own price — summing the parent alone halves the bill
*and looks settled while doing it*, which is worse than not pricing at all.

Three things the voicemail path could not simply lend it:

- **An empty child list is not `:pending` here.** For a transcription it means
  the callback has not landed; for a bridge it can mean the operator never
  answered, so `<Dial>` never ran and one leg is the whole bill. Reusing
  `sum_component/1` would have retried those rows forever.
- **A price does not imply the call ended.** `price` and `status` are separate
  fields on the same resource, so `final?` requires a terminal status too. The
  test that pins this feeds a priced, `in-progress` parent — inconsistent on
  purpose, because Twilio's internals are not ours to assume.
- **The work list needed a give-up.** `unpriced_events/1` (was
  `unpriced_voicemails/1`) is oldest-first with a limit, so one row that can
  never finalize starves every row behind it. After seven days the back-fill
  records what settled and marks the row `cost_incomplete`, which the panel
  shows — the difference between a number that is final and one that merely
  stopped changing. **This fixed a latent starvation bug in the voicemail path
  too**, which had been relying on never blocking on the inbound call leg.

Inbound call rows are deliberately excluded: nothing here created them, and an
inbound leg frequently never prices at all.

**The switch was unflippable for its first hour**, and no behavioural test could
have seen it: `voice_enabled` was read from the `:twilio` config map that
`config/runtime.exs` never wrote, so it was false in every build while every
kill-switch test passed — they set the key directly. Worse, the map was wrapped
in `if System.get_env("TWILIO_ACCOUNT_SID")`, so an operator who stored their
credentials in the Clinch (the supported path) had **both** switches stuck off,
SMS included. Both are fixed, and both halves are now guarded by a source-level
test that derives the switch list from the reader rather than hardcoding it.

**To turn it on:** `BUSTER_CLAW_VOICE_ENABLED=true`, plus `TWILIO_PHONE_NUMBER`
and `OPERATOR_PHONE_NUMBER` (or their Clinch entries). See `supabase/SETUP.md`.

---

## ~~Phase 2 — The bridge TwiML, in the relay~~ ❌ DELETED — see the header

A new edge function — or a new `?event=` branch on the existing `voice/` one —
that answers the operator's leg with `<Dial>` to the target.

Non-negotiables, all inherited and all already paid for once:

- **Verify `X-Twilio-Signature`, fail closed.** `_shared/twilio.ts` exists and
  declares itself shared by voice and sms; this is its third consumer.
- **`PUBLIC_URL_BASE` is REQUIRED.** Twilio signs the URL it was *configured*
  with, and Supabase's edge runtime rewrites `req.url` internally, so without it
  every request 403s and the caller hears an error and gets hung up on.
  Documented as optional once; it is not. Verified 07-12.
- **The target number must not be a caller-controlled string.** The bridge
  endpoint takes an opaque id that maps to a row the Mac created, not a `To=`
  parameter. An endpoint that dials whatever it is handed is an open relay for
  toll fraud, and it is public by necessity.

**Exit:** the operator's phone rings, they answer, the target rings, both legs
are audible, and a hang-up ends both.

---

## Phase 3 — The command surface, and this is where the care goes ✅ SHIPPED 08-15

Placing a phone call is **not** the same kind of act as changing a background.
The house has a precedent that names the category: `sound_record` is gated
because "recording the room when nobody is watching" is a thing an untrusted
input must never reach. **Dialling a stranger from the operator's number is at
least that**, and it costs money per attempt.

Proposed and to be argued in the catalog entry, not merely copied:

| | |
|---|---|
| tier | `:restricted` |
| gated | **yes** — `PolicyEngine`'s baseline stops an `:agent_untrusted` caller only with `gated: true`, and an autonomous run processing untrusted email is exactly the caller this must refuse |
| kill switch | `voice_enabled`, default off, separate from SMS |
| daily cap | per-recipient, mirroring `sent_today_to/1` |
| audit | `:outbound_send` on the Sentinel feed, the same category the SMS path uses |

**The opt-out question has no SMS answer to copy.** `sms_opted_out?/1` reads
STOP replies; voice has no STOP. Either outbound calling honours the *same*
opt-out list as SMS — a defensible reading, since it is the same human — or it
needs its own, and "no mechanism" is not an option that survives review.

**Exit:** an untrusted caller is refused without a confirmation prompt existing
at all; a trusted one is asked; the kill switch off means no call is placed by
any caller. **Met**, and both halves are broken-and-verified: flipping
`gated: false` fails the policy test, and removing the opt-out check fails the
STOP test.

**The opt-out question was answered rather than deferred.** Voice has no STOP,
so `phone_call` reads the SMS opt-out list — the same human asked to be left
alone, and treating a STOP as SMS-only would let the same app ring them.

**The cap is 5, not the SMS 20.** A repeated text is an annoyance; a repeated
phone call is harassment, and it bills two legs each time.

---

## Phase 4 — The keypad stops lying ✅ SHIPPED 08-15

`components/phone/playback.ex` renders a working keypad under the line
*"Searches your contacts · outbound calling isn't built."* That sentence exists
because of `G-37` — a decorative control that reads as finished — and it is the
thing this phase deletes.

- The dialled number becomes a **Call** button, disabled while `voice_enabled`
  is off, with the reason on screen rather than in a tooltip. The
  disabled-picker paragraph added to Settings → Models on 08-15 is the pattern:
  say *why*, name the fix.
- **A confirmation before the first ring**, showing the number, the caller ID it
  will present, and that the operator's own phone rings first. A call is
  irreversible in the way an SMS is: it cannot be unsent, and the recipient's
  log keeps it.
- Live legs appear in the Message Machine beside voicemails, since
  `telephony_events` already carries `direction`.

**Exit:** met, with one correction to the scope. **The disclosure line was not
deleted** — it was rewritten. "Outbound calling isn't built" became false, but
"calling is off, here is the variable that turns it on" is *more* true than
saying nothing, and a disabled button next to no explanation is the same G-37
failure as an inert one. The line goes away only when the reason does.

Shipped as three files rather than more of `PhoneComponent`, which the size gate
forced and which was right anyway: `Phone.CallAction` is the button, the confirm
step and the only copy of the refusal wording; `Phone.CallFlow` is the two-step
flow as socket transitions; the component keeps three lines of dispatch, because
`handle_event/3` clauses cannot be imported.

**Two guards were missing until they were broken.** The first pass asserted the
Call button's *enabled* behaviour and never its disabled one — flipping
`disabled` to a constant `false` passed every test. The second is sharper: an
absent `phx-click` is not a guard, because the component is reachable over its
socket by anything that can speak to it. `call_prompt` re-reads the switch in the
handler, and the test sends the event past the button to prove it.

**Still not built, deliberately:** live legs in the Message Machine. The outbound
row lands the moment the call is created — that is what the reload after a
successful placement is for — but it carries `queued`, and nothing updates it as
the legs connect. Making that live needs the status callback this design does not
have, which is the same trade that deleted Phase 2.

---

## Explicitly out of scope

- **Recording outbound calls.** Two-party-consent states make this a legal
  question, not a feature. Default off, and it stays off until someone answers
  the question properly.
- **Voicemail detection / AMD.** Twilio offers it; it costs per call and is
  probabilistic. Not until there is a reason.
- **Conference calls, transfers, hold.** The product is a dialer.
- **Option A (agent speaks).** Named above, deferred on purpose.
- **Option C (softphone).** Blocked on V.4a.

## Risks

| Risk | Weight | Mitigation |
|---|---|---|
| ~~Toll fraud through the public bridge endpoint~~ | — | **Gone.** Inline TwiML means there is no endpoint. |
| Two-leg cost surprises the operator | Medium | price both legs and show it, as voicemails already do |
| New number gets spam-flagged for outbound | Medium | Phase 0 decision; nothing technical fixes reputation |
| Agent places a call unattended | **High** | gated, not merely restricted — the `sound_record` precedent |
| Operator's phone unreachable, leg 1 fails | Low | fail before leg 2 exists; nobody is called |
