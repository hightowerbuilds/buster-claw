# BusterPhone — operator console checklist (Phases 0–1)

Everything in this file happens in web consoles and a terminal; no app code
runs until the Mac-side `BusterClaw.Telephony` context lands. The code that
deploys from here lives in this directory (`functions/`, `migrations/`) per
the roadmap rule: the Edge Function is app code, so it's versioned in the
repo even though it runs on Supabase.

## 1. Supabase project

> **Use a project dedicated to telephony. Nothing else.** The Mac drain holds
> this project's `service_role` key, which bypasses RLS for the *entire*
> project. Deploy the relay alongside another product and that key — sitting in
> a `.env` on a laptop — is also a skeleton key to that product's tables, storage
> and users. Learned the hard way 07-12: the relay was first deployed into a
> project that also held Stripe keys and customer data, and had to be moved.
> Live project: `tzptdzmwypdmmnmbruke` (telephony only).

1. Create a project at https://supabase.com/dashboard (free tier is fine).
   Save the **database password** somewhere real; you'll need it for `link`.
2. Install the CLI if needed: `brew install supabase/tap/supabase`.
3. From the repo root:

   ```sh
   supabase login
   supabase link --project-ref <PROJECT_REF>   # ref is in the dashboard URL
   supabase db push                            # applies migrations/ (table, RLS, bucket, realtime)
   ```

   **Do not run `supabase init`.** The dashboard's first-run copy suggests it;
   it scaffolds a fresh `supabase/` directory and will stomp the `config.toml`,
   `migrations/` and `functions/voice/` already in this repo.

   **`db push` on a brand-new project fails the first few minutes** with
   `relation "storage.buckets" does not exist` — Postgres comes up before the
   storage service does, and the migration creates the `recordings` bucket. It
   rolls back cleanly (nothing partially applies). Wait and re-run.

4. Set the function secrets (Twilio creds come from step 2 below — circle
   back if you do Supabase first):

   ```sh
   supabase secrets set TWILIO_ACCOUNT_SID=ACxxxxxxxx TWILIO_AUTH_TOKEN=xxxxxxxx
   supabase secrets set PUBLIC_URL_BASE=https://<PROJECT_REF>.supabase.co/functions/v1/voice
   ```

   **`PUBLIC_URL_BASE` is required, not optional.** Twilio signs the exact URL
   it was configured to call; on Supabase's edge runtime `req.url` is an
   internally-rewritten URL, so the signature never matches, the function 403s,
   and Twilio answers the call and immediately hangs up with no greeting. This
   is the single most confusing failure mode in the whole path — the phone
   *rings*, so it looks like a TwiML bug rather than an auth one. Secrets are
   read per-request, so setting it needs no redeploy.

5. Deploy the function. `--no-verify-jwt` is required — Twilio can't send a
   Supabase JWT; the function does its own auth (X-Twilio-Signature,
   fail-closed):

   ```sh
   supabase functions deploy voice --no-verify-jwt
   ```

   The public URL is:
   `https://<PROJECT_REF>.supabase.co/functions/v1/voice`

   Smoke-test it without a phone — an unsigned POST must be refused:

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' -X POST \
     https://<PROJECT_REF>.supabase.co/functions/v1/voice   # expect 403
   ```

## 2. Twilio account + number

1. Sign up at https://www.twilio.com (upgrade out of trial — trial numbers
   inject a preamble message and can only call verified numbers).
2. Buy a **local 10-digit number** with Voice + SMS capability
   (Phone Numbers → Buy a Number). ~$1–2/mo.
3. Copy **Account SID** and **Auth Token** from the console home into the
   `supabase secrets set` command above (redeploy is not needed after a
   secrets change; secrets are read per-request).
4. On the number's configuration page, under **Voice Configuration**, the
   **"A call comes in"** row (the first one — *not* "Primary handler fails",
   which is the fallback):
   - dropdown → **Webhook**
   - URL → `https://<PROJECT_REF>.supabase.co/functions/v1/voice`
   - method → **HTTP POST**
5. Add an **emergency address** to the number. Twilio warns about a $75 charge
   per emergency call without one. The app has no outbound calling at all, so
   nothing can dial 911 today — but it's free to add and becomes a real
   liability the moment outbound lands.
6. Leave Messaging unconfigured for now (Phase 2), **but** if you want SMS on
   schedule, start **A2P 10DLC brand + campaign registration** today —
   it's paperwork plus a multi-day wait and it's the Phase 2 gate.
   Voice needs no registration, so 10DLC is **not** on the Phase 1 critical
   path; don't let the banner on the number page bait you into it.

## 2b. Caller PINs (the credential caller ID is not)

Caller ID is spoofable — anyone can present your number and leave a voicemail
that would otherwise be auto-enqueued as *your* trusted instruction. So trust is
two-factor: a voicemail becomes agent work only when the caller's number is on
`memory/trusted-phone-numbers.md` **and** the caller punched the correct PIN for
that number on the keypad before the beep.

**This is a hard cutover, not an add-on.** The moment the PIN-gated `voice`
function is deployed, a trusted number with **no PIN set stops being enqueued** —
its voicemail is still recorded and playable, just never queued. So setting a PIN
for your own number is a required go-live step, not optional. (The drain logs a
`warning` when a trusted number calls unverified, so a silent "why isn't my
voicemail becoming work" has a breadcrumb.)

Set one from the in-app terminal (or any `./buster-claw` shell):

```sh
./buster-claw run phone_pin_set --json '{"number":"+15551234567","pin":"481500"}'
./buster-claw run phone_pin_list          # numbers + failed-attempt counts; never the PINs
./buster-claw run phone_pin_remove --json '{"number":"+15551234567"}'
```

- PIN is **4–10 digits**. Use 6+ — a 4-digit PIN is 10,000 combinations, and
  while each guess costs a phone call (~30 s), don't make it cheap.
- The plaintext PIN is hashed on this machine before it leaves; only
  `sha256(salt‖pin)` + salt reach Supabase. It is never logged and is redacted
  out of the Sentinel audit. It exists on your Mac for the length of one command
  and on the caller's keypad — nowhere else.
- The PIN and the trusted-numbers list are **independent kill switches**: remove
  either and the caller stops driving the queue.

## 3. Exit tests

> **Passed 2026-07-12** on project `tzptdzmwypdmmnmbruke`: greeting + beep, a
> 147 KB `.mp3` in Storage, a `telephony_events` row, and the transcript landing
> on the follow-up callback ~40 s later. The relay half is proven.

**Phase 0 — reachability.** Call the number from your phone. You should hear
the greeting and a beep. This proves the whole point: a loopback-only app is
reachable from the phone network with zero open ports on the Mac.

- **It answers and immediately hangs up, no greeting** → this is the
  `PUBLIC_URL_BASE` failure and it will burn an hour if you don't know it.
  Twilio got a 403 from the function (signature computed against the wrong URL)
  and played its error handler. Set the secret per step 1.4 and call again. It
  presents as a TwiML/audio problem; it is an auth problem.
- Greeting wrong/missing otherwise → check the webhook URL is on the
  **"A call comes in"** row and that the deploy used `--no-verify-jwt`.
- Still 403 with `PUBLIC_URL_BASE` set → confirm `TWILIO_AUTH_TOKEN` matches
  the console, and that the secret's URL is byte-identical to the one in the
  Twilio webhook field.

Note the Supabase **function logs are not reliable here** — `function_edge_logs`
returned zero rows for requests we could prove had happened (including a manual
`curl` that came back 403). Don't use log silence as evidence the function was
never called. Twilio's **Monitor → Logs → Errors** is the trustworthy source: it
records the HTTP status Twilio actually received.

**Phase 1 (relay half) — capture.** Leave a message after the beep, hang up,
then check the Supabase dashboard:

- **Storage → recordings** — a `<date>/voicemail-RExxxx.mp3` you can play.
- **Table editor → telephony_events** — one row, `kind = voicemail`, your
  number in `from_number`, `synced = false`; `transcript` fills in ~30–60 s
  after the recording row appears (separate Twilio callback).

**Phase 1 (Mac half).** With `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` in
`.env` (exactly those names — `config/runtime.exs:102-103`; the drain child is
simply absent from the supervision tree if either is missing), start the app
with `./scripts/dev.sh`. Within ~30 s `BusterClaw.Telephony.Drain` ticks, pulls
the `.mp3` into the Library, inserts into local SQLite, and the row flips to
`synced = true`. It shows up on the `/phone` tab.

## How the Mac side actually works (built — this supersedes the old plan)

- **The drain polls PostgREST. It does not use Realtime, and Slipstream was
  never added.** The original plan was a websocket subscription to
  `postgres_changes`; it was rejected at build. Reason: Realtime cannot replay
  rows that arrived while the laptop was asleep, so a catch-up read has to exist
  regardless — and at answering-machine latency that catch-up read *is* the whole
  drain. A websocket would have been a second code path earning nothing.
  See the `BusterClaw.Telephony.Relay` moduledoc.
  - Consequence: the `alter publication supabase_realtime add table …` line in
    the migration is **vestigial**. Nothing subscribes. It is harmless and left
    in place because the migration has already been applied remotely.
- `BusterClaw.Telephony.Drain` ticks every 30s: read `synced = false` rows
  (oldest first, limit 50) → download audio → insert locally → *then* mark
  synced. Persist-then-ack, so a crash re-drains rather than losing a voicemail;
  the local unique index on `twilio_sid` dedupes the retry.
- Transcript arrives as an **UPDATE** after the INSERT, and a drained row is
  never re-read — so voicemails with a null transcript are left queued until they
  are older than the 180s grace window.
- Credentials come from `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` in the app's
  env (not an integration row). The drain child only starts when both are set.
- Secrets live in two places by design (app + Supabase env). Documented risk;
  Sentinel can't see the Edge Function.
