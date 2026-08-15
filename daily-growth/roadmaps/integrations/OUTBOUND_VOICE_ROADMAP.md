# Outbound voice — making the rotary dial real

**Scoped 08-15-26 · Status: SCOPED, no code.** Operator asked for outgoing calls
alongside outgoing texts; those turned out to be two different problems and this
is the half that is ours.

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

`sms_send` has existed since 07-18, kill-switched, waiting on approval. There is
**no outbound call path at all**: `Telephony.Twilio` creates messages and reads
call/recording/transcription resources, and never POSTs to `Calls`. The keypad
on `/phone` says so on its face — *"Searches your contacts · outbound calling
isn't built"* — which is the honest placeholder this roadmap exists to retire.

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

## Phase 0 — Decide the identity of a call *(do this first, it is not code)*

Before any of this, one question has to be answered because every phase below
inherits it: **when Buster Claw calls someone, who is calling?**

The `From` must be the owned number, +1 (360) 364-6763. That means the person
being called sees the app's number, not the operator's. Two consequences worth
deciding up front rather than discovering:

- **A callback goes to the answering machine**, not to the operator. That may be
  exactly right — it is the product — but it must be a decision.
- **Blocked or spam-filtered** is a real outcome for a new number placing
  outbound calls. There is no A2P equivalent to fix reputation for voice; there
  is only behaviour over time.

**Exit:** the operator states, in this file, whether outbound calls present the
app's number or should be deferred until a second number exists.

---

## Phase 1 — `Twilio.place_call/3`, the REST half

The smallest honest unit: a function that creates a call and returns a receipt.

- `POST /2010-04-01/Accounts/{sid}/Calls.json` with `To`, `From`, and a `Url`
  pointing at the relay's new bridge endpoint (plus a `StatusCallback`).
- Mirror `send_sms/3`'s shape exactly, including its precondition style: a
  private `voice_ready` that names *which* precondition is missing, and **no
  public boolean twin** — that module's moduledoc records why a second copy of
  the conditions drifts out of step with the tagged errors.
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

---

## Phase 2 — The bridge TwiML, in the relay

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

## Phase 3 — The command surface, and this is where the care goes

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
any caller.

---

## Phase 4 — The keypad stops lying

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

**Exit:** the G-37 disclosure line is deleted because it has become false, and a
test asserts the Call button is disabled with a stated reason when the switch is
off.

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
| Toll fraud through the public bridge endpoint | **High** | opaque id, never a `To=` parameter; cap; kill switch |
| Two-leg cost surprises the operator | Medium | price both legs and show it, as voicemails already do |
| New number gets spam-flagged for outbound | Medium | Phase 0 decision; nothing technical fixes reputation |
| Agent places a call unattended | **High** | gated, not merely restricted — the `sound_record` precedent |
| Operator's phone unreachable, leg 1 fails | Low | fail before leg 2 exists; nobody is called |
