# BusterPhone — the Message Machine

**Give Buster Claw a real phone number.** It answers calls like a classic
answering machine (greeting → beep → recorded message in the Library) and
sends/receives SMS through the same command surface everything else uses.
An agent that already reads your email and works your dispatch queue gets a
second, more immediate channel: your phone.

> Drafted 2026-07-11 from the telephony research plan
> (`<workspace>/pages/telephony-plan.html`, 07-06). That doc holds the deep
> reasoning (provider verticals, flow diagrams, cost tables); this roadmap is
> the build plan against the source repo.

---

## 💰 07-12: THIS IS THE MONEY LEG

**BusterPhone is now the paid tier** (`GO_TO_MARKET_ROADMAP.md` Part V.1). It stopped
being a fun feature and became the only thing funding the fixed costs — CASA, Apple,
domain, MoR. Build it accordingly.

**The model: we are the phone company.** We hold the Twilio account, we provision the
number, **the user never learns Twilio exists.** One bill to us; we pay the wholesaler.

> **The live number (recorded 07-18): +1 (360) 364-6763** (`+13603646763`) — the paid
> local number bought 07-13. The trial +1 844-687-8016 is retired; its old relay on
> the shared Supabase project was torn down 07-18.

> **The trap to never ship: BYO-Twilio as the paid tier.** If the buyer signs up for
> Twilio, buys a number, and *then* pays us — they pay twice, and we have **zero
> marginal cost, therefore nothing to enforce** in a public repo. That's the same trap
> that killed on-duty as a paid feature. The paywall only works because **the number is
> ours.**

| Tier | What you get | Our cost |
|---|---|---|
| **Free / Channel A** | BYO Twilio + BYO Supabase, wire the webhook yourself (document this). | **$0** → free. Same principle as BYO Claude. |
| **Paid** | We are your phone company: a number, the relay, zero setup. | **Real, recurring, per-user** → earns a recurring price honestly. |

**Sequencing consequence — voice first, and it's a big one.** Voice shipped first as
a pure inbound answering machine. The SMS code path landed 2026-07-18, disabled by
default pending Messaging Service and A2P activation. Inbound voice **does not require
A2P 10DLC** — that registration grind is an *SMS* gate. So:

- **Phase 1 (voice/voicemail) is shippable as the paid tier with NO A2P registration.**
  This is the fastest honest path to revenue. Do not let SMS block it.
- **Phase 2 (SMS) is what triggers A2P 10DLC.** Twilio currently supports a Sole
  Proprietor Brand for eligible direct customers without an EIN; Standard Brand
  registration uses an EIN. Carrier review time, not the LLC, is the schedule risk.

**New obligations that come with being the retailer** (none of these are in the phases
below yet — they are net-new work):

- **Number provisioning** per paying account (buy/release via Twilio API), tied to
  subscription lifecycle: cancel → release the number, or we pay for it forever.
- **Abuse controls.** An agent with a phone is an agent that can be socially engineered
  into recording or calling something it shouldn't — and it's **our** Twilio account and
  **our** carrier reputation on the line. Rate caps + a Sentinel-visible kill switch.
- **Per-account isolation** (Twilio subaccounts) so one user's traffic can't poison
  everyone's number reputation.

---

## The one architectural fact everything follows from

Buster Claw is loopback-only by design — every HTTP scope binds to
`127.0.0.1` and that's a security posture, not an accident. Twilio is a
public-internet service that must POST to a URL the moment a call or text
arrives. **We do not open the Mac.** A small Supabase project is the public
front door:

```
Caller/Texter → Twilio number → Supabase Edge Function (public HTTPS)
                                  · verifies X-Twilio-Signature
                                  · returns TwiML (greeting / <Record> / ack)
                                  · writes audio → Storage, event row → Postgres
Mac (outbound-only) ← polls queue ← telephony_events (synced=false)
  BusterClaw.Telephony.Drain: drains queue, downloads audio into the
  Library, mirrors rows into SQLite; outbound SMS will go straight to
  Twilio's REST API (no ingress needed)
```

> **✅ THE DRAIN SHIPPED 07-12** — `BusterClaw.Telephony.Drain` +
> `Telephony.Relay`, gated on `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY`.
> **Design change from the sketch above: it polls PostgREST (30s tick), it is
> not a Realtime websocket.** Reasons: a websocket can't replay rows that
> arrived while the laptop slept, so the catch-up poll has to exist anyway;
> polling is the house pattern (WalletPoller) with zero new deps; and 30s is
> invisible for an answering machine. A Realtime waker can sit on top later by
> just calling `Drain.tick_now/1` — no rework. Discipline: persist-then-ack
> (a crash between the local insert and the remote `synced` flip re-drains and
> dedupes on the local `twilio_sid` unique index — retry, never a lost
> voicemail), a transcript grace window (young transcript-less voicemails wait
> for Twilio's trailing transcription callback before the one-shot drain), and
> per-row isolation (storage 404 drains without audio; transient failures
> retry; a traversal `recording_path` from the cloud is refused before it can
> land inside the Library root).

This buys **always-on capture** — a call that lands while the Mac is asleep
waits in Supabase and drains on next sync — and keeps the Mac purely
outbound. The lightweight alternative (bare Cloudflare Tunnel) only works
while the Mac is up; rejected as the default for exactly that reason.

Everything downstream is patterns the app already has: an `integrations` row
for creds (`Encrypted` token fields), Library markdown docs + binary
artifacts via `FileManager`, dispatch-queue items for agent follow-up, a
`Commands.Catalog` entry for outbound, and Sentinel observation on every
event.

## Decisions (proposed defaults — confirm before Phase 0)

| Decision | Default | Why |
|---|---|---|
| Provider | **Twilio** | The plan's TwiML is written against it verbatim; Telnyx/SignalWire are near-drop-in (TeXML/LaML) if cost ever matters; Vonage's JSON model would force an Edge Function rewrite — skip. |
| Ingress | **Supabase relay** | Always-on, zero open ports on the Mac. |
| Transcription | **Twilio built-in now, local-Whisper hook later** | Zero effort to ship. NOTE: Whisper STT was deliberately demolished 06-28 — a future local path should be a fresh decision, not a rebuild reflex. |
| Number type | **Local 10-digit** | A2P 10DLC is an **SMS-only** gate — **07-12: it does NOT block Phase 1 (voice), which is the paid tier's v1.** Don't start the 10DLC grind on the critical path; start it when SMS is actually next. Toll-free is the fallback if 10DLC drags. |
| SMS trust model | **Separate trusted-numbers list** | Mirrors the `TrustedSenders` pattern but phone numbers ≠ email addresses; a stranger's text gets archived, never auto-actioned. |

## Phases

### Phase 0 — Provision & reach (no app code)

Twilio account + number; Supabase project with a stub Edge Function returning
a hand-written TwiML greeting; point the number's Voice webhook at it.
**Exit test:** call the number from a phone, hear the greeting. This proves
the only genuinely new thing — public reachability for a loopback-only app —
before a line of Elixir exists.

### Phase 1 — The answering machine (inbound voicemail)

- **Edge Function, for real:** signature verification (fail closed),
  `<Say>` + `<Record maxLength playBeep transcribe>` TwiML, recording
  callback → pull audio into a Storage bucket + insert `telephony_events` row
  (direction, from/to, kind, duration, recording path, transcript,
  twilio_sid, synced flag).
- **`BusterClaw.Telephony` context (Mac):** outbound websocket subscription
  to Supabase Realtime; on new row, download the `.mp3` to
  `library/raw/<date>/voicemail-<time>-<from>.mp3` and write the companion
  Library log doc (caller, timestamp, duration, audio link, transcript).
- **Creds:** widen `Integration.@service_types` to include `"twilio"` —
  Account SID in `config`, Auth Token in the encrypted `token`, signing
  secret in `webhook_secret`. No new secrets table. (Honest caveat: the Edge
  Function holds a second copy in Supabase env vars.)
- **Local mirror:** one Ecto migration for a small `telephony_events` table —
  structured row + human-readable doc, same pairing as `integration_runs`.
- **Sentinel:** every inbound event observed as `:untrusted_ingest`.

**Exit test:** call the number, leave a message, watch the `.mp3` +
transcript doc appear in the workspace without touching the app.

### Phase 2 — Texting (inbound + outbound SMS)

> **Code-complete 2026-07-18; operator activation remains.** Signed inbound SMS,
> trusted-number Dispatch, `sms_send`, local outbound persistence, Sentinel audit,
> kill switch, and daily recipient cap are implemented and tested. The `/phone`
> thread view remains read-only. Live delivery still requires the Messaging Service
> SID, webhook deployment, and approved A2P campaign described below.
>
> **Historical baseline (2026-07-15).** The schema and `/phone` thread renderer
> existed, but no SMS webhook, drain dispatch, REST send, cap, or command wrote
> an SMS row. The 2026-07-18 implementation closes those code gaps; the rotary
> dial is still decorative because outbound voice remains out of scope.

**The one fact that shapes the whole phase: A2P 10DLC is the long pole, and it
is paperwork, not code.** US carriers filter application-to-person SMS from
unregistered senders. So the compliance track starts *first* and runs in the
background while the code track is built and tested against your own verified
number. Nothing below delivers to a stranger's phone until registration
clears — but everything below can be *built and proven* before it does.

#### The Twilio / registration track (operator — do this first, it waits on carriers)

> **Confirm the tier before anything else.** The Campaign Registry has a **Sole
> Proprietor** brand path for individuals with **no EIN** — lower throughput
> (a small MPS cap, one campaign, ~limited daily volume) but no company
> required. If that path still stands (verify current Twilio + TCR terms — these
> programs move), **SMS does not have to wait on forming the LLC**, which
> reverses this roadmap's original "SMS forces the entity early" assumption.
> Decide Sole Proprietor vs. Standard before registering; re-tiering later is a
> re-registration, not a toggle.

Steps in the Twilio Console (and TCR, which Twilio walks you through):

1. **Upgrade the account** off trial if not already, and make sure the paid
   **local 10-digit number** (bought 07-13 — **+1 (360) 364-6763**) is the one
   you'll text from.
   Toll-free is the fallback if 10DLC drags — it has its own (lighter,
   verification-based) path, no TCR campaign.
2. **Register the A2P Brand** — *Messaging → Regulatory Compliance → A2P 10DLC
   → Brand*. Sole Proprietor: your legal name, address, mobile number for the
   OTP verification, email. Standard: legal business name + **EIN** + website.
   A one-time vetting fee applies (~$4 SP / ~$44 Standard, confirm current).
3. **Create a Campaign** under the brand — use case is **"Low-Volume Mixed"**
   or **"Account Notification"** (an agent replying to the number's owner is
   conversational/notification, not marketing). You must supply: a campaign
   description, **2–3 sample messages** the agent would actually send, opt-in
   language, and the **STOP/HELP** handling statement. ~$10 one-time + ~$2/mo.
4. **Create a Messaging Service** — *Messaging → Services* — attach the number
   to it as the sender pool, and attach the approved campaign to the service.
   (Outbound sends go *through the Messaging Service SID*, not the raw number,
   so the campaign registration is applied.)
5. **Point the number's Messaging webhook** at the new `sms` edge function URL
   (*Phone Numbers → your number → Messaging → "A message comes in" → Webhook,
   POST*), exactly as you did for Voice. This can be wired before the campaign
   clears — inbound receipt works during review; it's *outbound* that carriers
   gate.
6. **STOP/HELP compliance is automatic but yours to honor** — Twilio
   auto-responds to STOP/HELP by default; keep that on. Note it in the greeting
   copy and don't send to a number that has replied STOP.
7. **Record the IDs** the code needs: **Messaging Service SID** (`MG…`), the
   Account SID (`AC…`) and Auth Token you already have, and the number in E.164.
   These go in the encrypted `twilio` integration record (app side) and the
   edge function's Supabase env vars (inbound signature verification).

**Registration exit test:** the campaign shows **Approved** in the console, and
a test send through the Messaging Service to your own phone arrives (Twilio
lets you send to verified numbers during review).

#### 2A — Inbound (buildable and testable now, before the campaign clears)

- **Edge Function `supabase/functions/sms/`** — mirror `voice/`: verify the
  `X-Twilio-Signature` (fail closed; `_shared/twilio.ts` already declares itself
  "shared by voice and sms"), insert one `telephony_events` row
  (`kind:"sms"`, `direction:"inbound"`, from/to/body/twilio_sid), return a
  minimal static TwiML `<Response>` (empty, or a one-line ack) — **the Mac is
  never in the synchronous path**; real answers follow as separate outbound
  sends.
- **`Telephony.Drain` SMS branch** — the drain currently special-cases
  `kind:"voicemail"` (audio download, transcript grace window). SMS rows carry
  no audio, so add a simpler branch: `record_event/2` (already handles the
  `sms` kind end-to-end) → mark synced. Persist-then-ack + the `twilio_sid`
  unique index give the same never-lost / dedupe guarantees for free.
- **Trusted-numbers gate before dispatch** — a text from a `TrustedNumbers`
  number (and, if we keep the PIN model for SMS, verified) becomes a Dispatch
  item; a stranger's text lands in the Library thread and the `/phone` Texts
  tab but **never auto-actions**. Inbound bodies are untrusted input, fenced
  exactly like email — `Sentinel.observe(:untrusted_ingest, …)` on every one.

**2A exit test:** text the number from your phone → the row drains → it shows in
the `/phone` **Texts** thread, and (trusted sender) a Dispatch item appears — all
without touching the app. Works during campaign review; only cross-carrier
*delivery of replies* is gated.

#### 2B — Outbound (the genuinely new capability)

- **`BusterClaw.Telephony.Twilio` REST client** — the first outbound client in
  the app. A small module that POSTs to
  `https://api.twilio.com/2010-04-01/Accounts/{AccountSid}/Messages.json` with
  basic auth (Account SID + Auth Token from the encrypted `twilio` integration
  record), sending **via the Messaging Service SID** (`MessagingServiceSid`
  param, not `From`) so the campaign registration applies. Injectable HTTP for
  tests, like `Telephony.Relay`.
- **`sms_send` command** in `Commands.Catalog.Telephony` — tier
  **`:restricted`** (args `to` + `body`), so an `agent_untrusted` caller is
  refused-and-queued, not silently sent. Agent-drivable via `./buster-claw
  sms_send` and `/api/run`; **`Sentinel.observe(:outbound_send, …)` on every
  send.** This is the first thing in the app that can spend money and reach a
  stranger unprompted — the trust tier is load-bearing, not decoration.
- **Compose/reply box in `/phone`** — the thread view is read-only today; add a
  send box that calls `sms_send`. Optional now, since the agent path works
  headless, but it's what makes the Texts tab feel like a phone.
- **Usage caps + kill switch** — a per-day/per-number send cap and a
  Sentinel-visible stop, because unattended outbound on *our* Twilio account is
  the abuse surface the paid-tier section calls "a pricing requirement, not a
  nice-to-have." Ship this *with* outbound, not after.

**2B exit test:** the agent runs `sms_send` from the terminal (or the operator
uses the compose box) and the text lands on a real phone; the send appears on
the Sentinel feed as `:outbound_send` and as an `outbound` row in the `/phone`
thread; a send over the daily cap is refused.

### Phase 3 — Surfacing & polish

- Dispatch-queue items for new voicemail ("New voicemail from +1…") so the
  on-duty loop handles follow-up.
- A **Message Machine panel** (Settings-adjacent or its own tab): call/text
  log from the local mirror, tap-to-play recordings, thread view.
- SMS as a selectable **delivery channel** for daily summaries and alerts —
  the Financial Informant and wrap-up outputs can go by text.
- Optional: local transcription hook (decision above), greeting
  customization (operator-recorded or Polly voice/text in Settings).

### Phase 4 — Resilience (cheap, optional)

Interval poll of Supabase via the existing integration-scheduler pattern as a
backstop to the Realtime websocket. Supabase already holds events durably, so
this is hardening, not new capability.

## What's new vs. reused

| Piece | Status |
|---|---|
| Supabase project (Edge Fn + Storage + one table + Realtime) | **new** — mostly config; the Edge Function is the only new deployed code (Deno/TS) |
| `BusterClaw.Telephony` context + Realtime client | **new** — outbound-only |
| Local `telephony_events` migration | **new** — one table |
| Trusted-numbers list | **new** — modeled on `TrustedSenders` |
| `twilio` integration record / encrypted creds | reuse |
| Library docs + binary artifacts (`FileManager`) | reuse |
| Dispatch queue + Sentinel feed | reuse |
| **SMS (Phase 2):** `sms` edge function | **new** — Deno/TS, mirrors `voice/` |
| `Telephony.Twilio` REST client (outbound) | **new** — first outbound client in the app |
| `sms_send` catalog entry + `:restricted` tier gate | **new** — the catalog/tier/`/api/run` plumbing is reused; the command is not |
| `Telephony.Drain` SMS branch | **new** — small; the drain loop is reused |
| SMS thread reads + `/phone` Texts tab + trusted-numbers gate | reuse — already built, schema-ready |
| Usage caps + send kill switch | **new** — required before unattended outbound |

## Cost of running it (ballpark, confirm at build)

Number ~$1–2/mo · inbound voice ~$0.0085/min · SMS ~$0.008 each + carrier
fees · Twilio transcription ~$0.05/min · 10DLC one-time + ~$2/mo ·
Supabase free tier covers this volume. **Order of $5/mo for personal use.**

**07-17 — measured, not ballpark** (cost instrument built & verified; full record
in `../../archive/07-17-26-voicemail-cost-roadmap.md`): every voicemail on record
costs **$0.0525**, of which **transcription is $0.0500 — 95% of the total**
(recording $0.0025; the inbound call leg never prices on trial-credit calls).

> **OPEN DECISION — the actual savings lever (inherited from the cost roadmap's
> Phase 4):** turn `<Record transcribe="true">` off in the `voice` edge function
> (~one line; drops a voicemail to ~$0.0025) or keep Twilio transcription as
> COGS at ~5¢/message. A local-STT replacement would be a *fresh* decision —
> Whisper was deliberately demolished 06-28; don't reflex-rebuild. This shapes
> paid-tier margin directly, so decide it before pricing, and don't let the
> display instrument stand in for the decision.

**07-12 — this is no longer "what it costs me," it is COGS.** Since BusterPhone is
the paid tier (Part V.1), these numbers set the margin:

- **Per paying user we carry:** the number (~$1–2/mo) + their usage (voice minutes,
  transcription) + a share of Supabase once it outgrows the free tier.
- **At $10–15/mo, gross margin is roughly 80–85%** — healthy, *and honest*: the price
  is backed by a cost we genuinely incur, which is the entire premise of Part V.
- **Verify every figure against current Twilio pricing before pricing anything.**
  These are from the 07-06 research doc and telephony pricing moves.
- **The real cost risk is usage, not the number.** A chatty (or abused) account
  is unbounded voice minutes + transcription against a *flat* subscription. **Usage
  caps are a pricing requirement, not a nice-to-have** — see the abuse controls above.
- **Browserbase is gone** (deleted 07-12) and **GWS is being given away free**, so
  this is now the *only* costs-real-money feature — and the only one funding CASA,
  Apple, the domain, and the MoR cut.

## Risks & honest notes

- **Secrets in two places** — Twilio creds live encrypted in the app *and*
  in Supabase env vars. Document it; Sentinel can't see the Edge Function.
- **10DLC is the schedule risk** for SMS, not code. Voicemail has no such
  gate — hence the phase order. **Register first, build while it grinds** (Phase
  2A is fully testable against your own verified number during review). Confirm
  the **Sole Proprietor** brand tier — if it holds, SMS ships without the LLC,
  reversing the old "SMS forces the entity" assumption.
- **Outbound is the first thing in the app that spends money and reaches a
  stranger unprompted.** The `:restricted` tier on `sms_send` and the usage cap
  are the guardrails; a prompt-injected agent must not be able to fire texts.
  This is a genuinely different risk class from every read-only capability
  shipped so far.
- **The Edge Function is app code living outside the repo's test suite.**
  Keep it tiny and boring; version it in the repo (`supabase/functions/…`)
  even though it deploys elsewhere.
- **Spam calls exist.** The answering machine records strangers by design —
  fine for the Library, but transcripts of unknown callers are untrusted
  input, same fencing as SMS bodies.
