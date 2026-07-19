-- BusterPhone Phase 2: preserve provider metadata needed for safe SMS handling.
-- In particular, Twilio's Advanced Opt-Out webhook adds OptOutType. The Mac
-- drain archives that event but must never turn it into agent work.
alter table public.telephony_events
  add column if not exists metadata jsonb not null default '{}'::jsonb;
