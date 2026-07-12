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

> **The trap to never ship: BYO-Twilio as the paid tier.** If the buyer signs up for
> Twilio, buys a number, and *then* pays us — they pay twice, and we have **zero
> marginal cost, therefore nothing to enforce** in a public repo. That's the same trap
> that killed on-duty as a paid feature. The paywall only works because **the number is
> ours.**

| Tier | What you get | Our cost |
|---|---|---|
| **Free / Channel A** | BYO Twilio + BYO Supabase, wire the webhook yourself (document this). | **$0** → free. Same principle as BYO Claude. |
| **Paid** | We are your phone company: a number, the relay, zero setup. | **Real, recurring, per-user** → earns a recurring price honestly. |

**Sequencing consequence — voice first, and it's a big one.** As shipped, BusterPhone
is a pure **inbound answering machine**: `<Say>` → `<Record>` → transcribe
(`supabase/functions/voice/index.ts:77-83`), with **no outbound Twilio call anywhere in
the codebase**. Inbound voice **does not require A2P 10DLC** — that registration grind
is an *SMS* gate. So:

- **Phase 1 (voice/voicemail) is shippable as the paid tier with NO A2P registration.**
  This is the fastest honest path to revenue. Do not let SMS block it.
- **Phase 2 (SMS) is what triggers A2P 10DLC** — and A2P brand registration wants an
  **EIN**, which likely forces the LLC earlier than `GO_TO_MARKET` Part I assumes
  ("entity deferred"). **Confirm this before committing to an SMS date.**

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

- **Edge Function `/sms`:** verify, write event row, return a static TwiML
  ack (`Got it — on it.`) since the Mac is never in the synchronous path;
  real answers follow as separate outbound sends.
- **Inbound on the Mac:** running SMS-thread doc per sender number in the
  Library; **trusted-numbers gate** before anything reaches the dispatch
  queue — inbound text bodies are untrusted input and get fenced exactly like
  email bodies.
- **Outbound:** `sms_send` command in `Commands.Catalog.Integrations`
  (tier **restricted**, args `to` + `body`), calling Twilio's Messages REST
  API directly from the Mac. On the command surface = agent-drivable via
  `./buster-claw` and `/api/run`, Sentinel `:outbound_send` on every send.
- **Compliance gate (start day 1 of this phase):** A2P 10DLC brand +
  campaign registration — paperwork + a few days' wait; unregistered traffic
  gets carrier-filtered. Voice needs no registration (why voicemail ships a
  phase earlier).

**Exit test:** text the number → ack arrives, thread doc + dispatch item
appear (trusted sender only); agent runs `sms_send` from the terminal and
the text lands on a phone.

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
| `sms_send` catalog entry, tier gate, `/api/run` | reuse |
| Dispatch queue + Sentinel feed | reuse |

## Cost of running it (ballpark, confirm at build)

Number ~$1–2/mo · inbound voice ~$0.0085/min · SMS ~$0.008 each + carrier
fees · Twilio transcription ~$0.05/min · 10DLC one-time + ~$2/mo ·
Supabase free tier covers this volume. **Order of $5/mo for personal use.**

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
  gate — hence the phase order.
- **The Edge Function is app code living outside the repo's test suite.**
  Keep it tiny and boring; version it in the repo (`supabase/functions/…`)
  even though it deploys elsewhere.
- **Spam calls exist.** The answering machine records strangers by design —
  fine for the Library, but transcripts of unknown callers are untrusted
  input, same fencing as SMS bodies.
