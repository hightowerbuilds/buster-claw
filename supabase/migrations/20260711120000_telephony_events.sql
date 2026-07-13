-- BusterPhone Phase 1: the durable event queue between Twilio and the Mac.
-- The Edge Function inserts rows; the Mac (service role, outbound websocket)
-- drains them and flips `synced`. Rows survive the Mac being asleep — that is
-- the whole point of the relay.

create table if not exists public.telephony_events (
  id uuid primary key default gen_random_uuid(),
  direction text not null check (direction in ('inbound', 'outbound')),
  kind text not null check (kind in ('voicemail', 'sms', 'call')),
  from_number text not null,
  to_number text not null,
  body text,
  duration_seconds integer,
  recording_path text,
  transcript text,
  twilio_sid text unique,
  synced boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists telephony_events_unsynced_idx
  on public.telephony_events (created_at)
  where not synced;

-- RLS on with no policies: anon/authenticated keys can't touch this table.
-- Only the service role (Edge Function + the Mac's drain client) bypasses.
alter table public.telephony_events enable row level security;

-- VESTIGIAL: nothing subscribes to this. The Mac-side drain polls PostgREST
-- instead (Realtime can't replay rows that arrived while the laptop slept, so a
-- catch-up read had to exist anyway — see BusterClaw.Telephony.Relay). Left in
-- place because this migration has already been applied remotely; harmless.
alter publication supabase_realtime add table public.telephony_events;

-- Private bucket for voicemail audio; the Mac downloads via service role.
insert into storage.buckets (id, name, public)
values ('recordings', 'recordings', false)
on conflict (id) do nothing;
