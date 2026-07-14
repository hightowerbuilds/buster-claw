-- BusterPhone caller PINs — the credential that caller ID is not.
--
-- The trust decision for a voicemail was, until now, a match on `from_number`
-- against the operator's trusted-numbers list. Caller ID is spoofable, so that
-- match authenticates a *claim*, not a caller. This table holds the second
-- factor: a per-number PIN the caller punches on the keypad before the beep.
-- A voicemail is only enqueued as trusted work when the number is trusted AND
-- the call was PIN-verified (see the `voice` edge function and the Mac-side
-- `BusterClaw.Telephony.Drain`).
--
-- The PIN is never stored in the clear. The Mac hashes it at set-time and sends
-- only the hash + salt here, so the plaintext PIN exists on the operator's
-- machine and on the caller's keypad, nowhere else. The edge function hashes the
-- punched digits with the row's salt and compares. Algorithm, fixed on both
-- sides: lowercase-hex sha256(salt <> pin), pin as its literal digit string.

create table if not exists phone_pins (
  -- E.164, the same normalized form used everywhere else in telephony.
  number text primary key,
  pin_hash text not null,
  salt text not null,
  -- Brute-force telemetry. The edge function bumps failed_attempts on a wrong
  -- PIN and clears it on success; a spike is visible without needing logs.
  -- (Automated lockout is a follow-up — a 6-digit PIN over voice calls is
  -- already ~1e6 combinations at ~30s/attempt, so this v1 makes attacks visible
  -- rather than impossible.)
  failed_attempts integer not null default 0,
  last_verified_at timestamptz,
  last_attempt_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Only the service role touches this table — the edge function (verify) and the
-- Mac drain client (manage). No anon/authenticated access at all: a PIN hash is
-- a credential, and there is no browser-facing reason to read it.
alter table phone_pins enable row level security;
-- (No policies added on purpose: RLS-on with zero policies denies every non
-- service-role request, which is exactly the posture we want.)

-- The verdict of the PIN gate, carried on the voicemail row itself. The edge
-- function sets it true only when the caller punched the correct PIN for their
-- (claimed) number; the Mac drain reads it and will not enqueue an unverified
-- voicemail as trusted work no matter what caller ID says. Default false so any
-- row written by an older function build, or any path that skips the gate, is
-- untrusted by construction.
alter table telephony_events
  add column if not exists verified boolean not null default false;
