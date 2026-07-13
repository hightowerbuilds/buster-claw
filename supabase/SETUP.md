# BusterPhone — operator console checklist (Phases 0–1)

Everything in this file happens in web consoles and a terminal; no app code
runs until the Mac-side `BusterClaw.Telephony` context lands. The code that
deploys from here lives in this directory (`functions/`, `migrations/`) per
the roadmap rule: the Edge Function is app code, so it's versioned in the
repo even though it runs on Supabase.

## 1. Supabase project

1. Create a project at https://supabase.com/dashboard (free tier is fine).
   Save the **database password** somewhere real; you'll need it for `link`.
2. Install the CLI if needed: `brew install supabase/tap/supabase`.
3. From the repo root:

   ```sh
   supabase login
   supabase link --project-ref <PROJECT_REF>   # ref is in the dashboard URL
   supabase db push                            # applies migrations/ (table, RLS, bucket, realtime)
   ```

4. Set the function secrets (Twilio creds come from step 2 below — circle
   back if you do Supabase first):

   ```sh
   supabase secrets set TWILIO_ACCOUNT_SID=ACxxxxxxxx TWILIO_AUTH_TOKEN=xxxxxxxx
   ```

5. Deploy the function. `--no-verify-jwt` is required — Twilio can't send a
   Supabase JWT; the function does its own auth (X-Twilio-Signature,
   fail-closed):

   ```sh
   supabase functions deploy voice --no-verify-jwt
   ```

   The public URL is:
   `https://<PROJECT_REF>.supabase.co/functions/v1/voice`

## 2. Twilio account + number

1. Sign up at https://www.twilio.com (upgrade out of trial — trial numbers
   inject a preamble message and can only call verified numbers).
2. Buy a **local 10-digit number** with Voice + SMS capability
   (Phone Numbers → Buy a Number). ~$1–2/mo.
3. Copy **Account SID** and **Auth Token** from the console home into the
   `supabase secrets set` command above (redeploy is not needed after a
   secrets change; secrets are read per-request).
4. On the number's configuration page, under **Voice & Fax**:
   - A call comes in → **Webhook** →
     `https://<PROJECT_REF>.supabase.co/functions/v1/voice` → **HTTP POST**
5. Leave Messaging unconfigured for now (Phase 2), **but** if you want SMS on
   schedule, start **A2P 10DLC brand + campaign registration** today —
   it's paperwork plus a multi-day wait and it's the Phase 2 gate.
   Voice needs no registration.

## 3. Exit tests

**Phase 0 — reachability.** Call the number from your phone. You should hear
the greeting and a beep. This proves the whole point: a loopback-only app is
reachable from the phone network with zero open ports on the Mac.

- Greeting wrong/missing → check the webhook URL and that the deploy used
  `--no-verify-jwt`.
- 403 in the Supabase function logs → signature verification failed; confirm
  `TWILIO_AUTH_TOKEN` matches the console. If it still fails, set
  `PUBLIC_URL_BASE=https://<PROJECT_REF>.supabase.co/functions/v1/voice`
  as a secret (proxy URL rewrite; see `functions/voice/index.ts`).

**Phase 1 (relay half) — capture.** Leave a message after the beep, hang up,
then check the Supabase dashboard:

- **Storage → recordings** — a `<date>/voicemail-RExxxx.mp3` you can play.
- **Table editor → telephony_events** — one row, `kind = voicemail`, your
  number in `from_number`, `synced = false`; `transcript` fills in ~30–60 s
  after the recording row appears (separate Twilio callback).

The Mac half of the Phase 1 exit test (`.mp3` + Library doc appearing in the
workspace) needs `BusterClaw.Telephony` — next build step after this
checklist passes.

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
