# Voicemail Cost — showing what each message actually costs

*Drafted 2026-07-17. Goal: show the Twilio cost of each voicemail in `/phone`,
plus a running total, so the operator can see the spend per message and where it
goes. Motivating observation: messages seem to run **20–30¢ each**, which is
~4–5× what base rates predict — so the real breakdown is worth having.*

---

## The one fact everything follows from

**Twilio never sends cost in a webhook.** The `voice` edge function receives
`RecordingSid`, `CallSid`, `RecordingDuration`, etc. — never a price. Cost lives
only on Twilio's **REST API**, where each resource carries a `price` (a negative
USD string like `-0.00850`) and `price_unit`. And it is **populated
asynchronously** — `price` is `null` right after the call and Twilio fills it in
a bit later (usually minutes, sometimes longer). So this is a *fetch-and-retry
back-fill*, not something we can capture at drain time.

A full per-voicemail cost is the sum of **three** resource prices:

| Component | Twilio resource | SID we need |
|---|---|---|
| Inbound call leg | `Calls/{CallSid}.json` | `CallSid` — in the recording callback, capture into `metadata` |
| Recording | `Recordings/{RecordingSid}.json` | `RecordingSid` — **stored** as `twilio_sid` |
| Transcription | `Recordings/{RecordingSid}/Transcriptions.json` (list, sum) | none extra — derived from the RecordingSid |

`total = |call.price| + |recording.price| + Σ|transcription.price|`. Only the
**CallSid** must be captured; the transcription price hangs off the recording's
own subresource, so no transcription-callback change and no `TranscriptionSid`
storage is needed.

## ✅ BUILT & VERIFIED 2026-07-17 — with a surprise in the real numbers

Shipped: the `Telephony.Twilio` REST client (prices from the **RecordingSid**
alone — the Recording resource also yields the parent `call_sid`, so no
edge-function change or extra storage was needed), the `refresh_cost` /
`refresh_unpriced_costs` back-fill wired into the drain tick, and the `/phone`
UI (per-voicemail chip, breakdown, running total, manual refresh). Creds read
from `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` in the Mac's `.env`.

**The real per-voicemail cost is ~$0.0525, not 20–30¢.** Priced live against all
8 existing voicemails, every one is identical:

| Component | Price |
|---|---|
| Recording | $0.0025 |
| Transcription | $0.0500 |
| Inbound call leg | `null` (trial-credit calls never per-call price) |
| **Total** | **$0.0525** |

So the 20–30¢ figure was off — the actual Twilio *resource* cost is ~5¢, and
**transcription is 95% of it** ($0.05 of $0.0525). The "kill transcription" lever
still stands (it drops each voicemail to ~$0.0025), just against a smaller
absolute number than feared. (Where the 20–30¢ impression came from is unknown —
likely the console's usage/rounding view or the monthly number fee amortized;
worth a glance at the Twilio usage dashboard, but the per-message resource prices
above are authoritative.)

**Finalization rule (learned from the data):** the inbound call leg is `null`
forever on trial-credit calls, so `final?` gates on **recording + transcription
only** — the call cost is included when it prices but never blocks a row from
finalizing (otherwise trial rows would re-hit Twilio every tick forever).

## The finding worth acting on first (independent of this build)

Base US rates (~$0.0085/min inbound voice, ~$0.0025/min recording, ~$0.05/min
transcription, each rounded up to a minute) predict **~6¢** for a sub-minute
voicemail — and every voicemail on record is ≤53 seconds. The observed **20–30¢**
means **the transcription is the overwhelming cost driver** (Twilio's current
transcription / Voice-Intelligence pricing is far above the old flat $0.05/min).

**The cheapest fix is not this feature — it's turning transcription off** in the
edge function's `<Record transcribe="true">` (or moving to local STT, noted in
`BUSTERPHONE_ROADMAP.md`). That likely drops ~25¢ → ~1–2¢ per message. This
roadmap *measures* the spend; killing transcription *reduces* it. Do the one-line
transcription decision as its own thing; don't let it block or hide behind the
cost display.

## The prerequisite this shares with SMS

To query Twilio's REST API from the Mac we need the **Twilio Account SID + Auth
Token available to the Mac** (read-only is enough for pricing). Today they live
**only in the Supabase edge function's env vars** — the Mac side has Supabase
creds, not Twilio creds. This is the *same* Twilio REST client that
`BUSTERPHONE_ROADMAP.md` Phase 2B (outbound SMS) needs, so build it once, here,
and SMS reuses it. Store the creds in the encrypted `twilio` integration record
(the pattern Phase 1 sketched), never in the repo.

## Phases

### Phase 0 — Twilio REST creds on the Mac *(operator + small code)*
Widen the integration/creds surface so `Account SID` + `Auth Token` are readable
by the Mac from the encrypted store. Operator supplies them once. **Exit:** a
`Telephony.Twilio.configured?/0` returns true and a trivial authenticated GET
(e.g. fetch the account resource) succeeds.

### Phase 1 — Capture the CallSid *(no creds needed; buildable now)*
- **Edge function:** store `CallSid` (in `handleRecording`) onto the
  `telephony_events` row's existing `metadata` map — no cloud migration. (No
  transcription-callback change: the transcription price is read from the
  recording's own subresource on the Mac.)
- **Drain:** carry `metadata` through into local SQLite (the drain already copies
  the row; just don't drop the key).
- **Local migration:** add cost columns to `telephony_events` —
  `cost_micros` (integer, total in micro-USD, nullable), `cost_currency`
  (string, nullable), `cost_synced_at` (utc_datetime, nullable). Per-component
  prices + the SIDs live in `metadata`.
- **Exit:** a freshly drained voicemail carries `call_sid` and `transcription_sid`
  in `metadata`; the cost columns exist and are null.

### Phase 2 — The Twilio price client + back-fill *(needs Phase 0 creds)*
- **`BusterClaw.Telephony.Twilio`** — a small REST client (basic auth, injectable
  HTTP like `Telephony.Relay`) with `resource_price/2` for a Call / Recording /
  Transcription SID, returning `{:ok, micros | :pending}` (`:pending` when Twilio
  hasn't priced it yet) or `{:error, _}`.
- **Cost back-fill** — for events with `cost_synced_at == nil` (or still
  `:pending`), fetch the three prices, sum to `cost_micros`, set `cost_synced_at`
  when *all three* are final. Because prices lag, this is a **retryable pass**:
  drive it from the existing drain tick (cheap: only unpriced rows), plus a manual
  "refresh costs" command/action. Every fetch is Sentinel-observed like other
  outbound Twilio calls.
- **Exit:** the 8 existing voicemails show a non-null `cost_micros` that matches
  the Twilio console to the cent; a brand-new voicemail starts null and fills in
  within a few minutes.

### Phase 3 — Surface it in `/phone` *(no creds; pure UI)*
- Per-voicemail: show the cost (e.g. `$0.24`) in the Playback panel detail, and a
  small badge in the log row. `— pricing…` while `cost_micros` is null.
- **Running total** somewhere honest (Machine readout panel): "This month: $X
  across N voicemails," and the average.
- **Exit:** the operator can read each message's cost and the total without
  leaving the app.

### Phase 4 — The cost lever *(optional, parallel, the actual savings)*
Decide transcription: turn `<Record transcribe>` off, or switch to local STT.
This is where the money is; the display just proves it.

## Schema (local `telephony_events`)

New columns (one migration): `cost_micros` int null, `cost_currency` string null,
`cost_synced_at` utc_datetime null. In `metadata`: `call_sid`,
`transcription_sid`, and `cost_breakdown` (`%{call, recording, transcription}` in
micros) for the detail view. Micro-USD integers avoid float drift and sum cleanly
($0.25 = 250_000).

## What's new vs. reused

| Piece | Status |
|---|---|
| `Telephony.Twilio` REST client | **new** — shared with SMS Phase 2B |
| Twilio creds readable on the Mac | **new** — encrypted integration record |
| Edge function: store CallSid + TranscriptionSid | **new** — a few lines each |
| Cost columns migration | **new** — one migration |
| Cost back-fill pass | **new** — rides the existing drain tick |
| `/phone` cost display + total | **new** — UI |
| Drain, metadata map, Sentinel, PostgREST relay | reuse |

## Risks & honest notes

- **Async pricing** is the whole shape of this — never assume a fresh voicemail
  has a price; treat null as "pending," retry, and say "pricing…" in the UI.
- **Cost accuracy:** sum the three components or it will read low; a message with
  no transcription (transcribe off) simply has no transcription price.
- **Creds reach further than pricing** — the Account SID + Auth Token on the Mac
  can also send messages and spend money. Scope usage and keep them encrypted;
  this is the same trust surface SMS outbound introduces.
- **Don't conflate measuring with fixing.** Phase 4 (kill transcription) is the
  savings; Phases 0–3 are the instrument. Ship the instrument, but don't let it
  delay the one-line decision that actually cuts the bill.
