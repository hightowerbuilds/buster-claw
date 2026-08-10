-- ONE-TIME SWEEP: erase relay rows drained before 2026-08-10.
--
-- WHY THIS EXISTS
--
-- Until 08-10 the Mac-side drain acknowledged a row by flipping `synced` to true
-- instead of deleting it. `Relay.list_unsynced/1` filters on that flag, so drained
-- rows became invisible rather than gone: every voicemail transcript and every
-- audio object stayed here permanently, and nothing collected them.
--
-- The drain now DELETES (see `BusterClaw.Telephony.Drain.erase/2`), so this can
-- only ever happen once, to the backlog that predates the fix. It is deliberately
-- NOT automated: widening the drain's query to catch `synced = true` rows would
-- mean a lost or reset local database replays every voicemail ever received back
-- through the enqueue path.
--
-- SAFETY: `synced = true` means persist-then-ack succeeded, so a local copy
-- existed AT THE TIME. That is not the same as one existing NOW. Step 1 is not
-- optional.

-- ---------------------------------------------------------------------------
-- STEP 1 — PRECONDITION, on the Mac. Do not skip.
-- ---------------------------------------------------------------------------
-- Count what you actually hold locally:
--
--     ./buster-claw run phone_stats --json '{}'
--
-- Compare it to the relay's drained count from Step 2. If the local count is
-- LOWER, something was lost locally and these rows are your only copy — STOP and
-- re-drain instead of deleting. (To re-drain: flip the rows back with
-- `update public.telephony_events set synced = false where synced;` and let the
-- drain run. The local unique index on `twilio_sid` dedupes anything already
-- present, and the erase path will then clean up properly on its own.)

-- ---------------------------------------------------------------------------
-- STEP 2 — INSPECT. Read-only; run this first and keep the output.
-- ---------------------------------------------------------------------------
select
  count(*)                                        as drained_rows,
  count(*) filter (where recording_path is not null) as with_audio,
  count(*) filter (where kind = 'voicemail')      as voicemails,
  count(*) filter (where kind = 'sms')            as sms,
  min(created_at)                                 as oldest,
  max(created_at)                                 as newest
from public.telephony_events
where synced;

-- The audio objects those rows point at, and what they weigh:
select
  count(*)                                          as objects,
  pg_size_pretty(sum((metadata->>'size')::bigint))  as total_size
from storage.objects
where bucket_id = 'recordings'
  and name in (
    select recording_path
    from public.telephony_events
    where synced and recording_path is not null
  );

-- Objects with NO row pointing at them (orphaned by a partial cleanup, or by a
-- row deleted some other way). Review before including them in Step 3.
select name, created_at, pg_size_pretty((metadata->>'size')::bigint) as size
from storage.objects
where bucket_id = 'recordings'
  and name not in (select coalesce(recording_path, '') from public.telephony_events)
order by created_at;

-- ---------------------------------------------------------------------------
-- STEP 3 — ERASE. Destructive. Run only after Step 1 checks out.
-- ---------------------------------------------------------------------------
-- Audio objects FIRST, so a failure here leaves the rows as the record of what
-- still needs cleaning. Deleting the rows first would lose the paths and orphan
-- every object — the same ordering the drain itself uses, for the same reason.
--
-- NOTE ON STORAGE: deleting from `storage.objects` removes Supabase's metadata
-- row. Depending on your project's storage version this may or may not remove the
-- underlying S3 object. The Storage API is the authoritative path and is what the
-- app itself uses (`Relay.delete_recording/2`). If you want certainty, delete the
-- objects over the API instead of with the SQL below:
--
--     curl -X DELETE "$SUPABASE_URL/storage/v1/object/recordings/<path>" \
--       -H "apikey: $SERVICE_ROLE_KEY" \
--       -H "authorization: Bearer $SERVICE_ROLE_KEY"
--
-- ...driven from the path list produced by Step 2. Then run only the row delete.

begin;

  -- 3a. The audio.
  delete from storage.objects
  where bucket_id = 'recordings'
    and name in (
      select recording_path
      from public.telephony_events
      where synced and recording_path is not null
    );

  -- 3b. The rows — transcripts and caller numbers live here, not just pointers.
  delete from public.telephony_events
  where synced;

-- Read the two counts above before committing. ROLLBACK is free; this is not.
commit;

-- ---------------------------------------------------------------------------
-- STEP 4 — CONFIRM
-- ---------------------------------------------------------------------------
select count(*) as should_be_zero from public.telephony_events where synced;

select count(*) as remaining_objects
from storage.objects
where bucket_id = 'recordings';

-- `remaining_objects` should equal the number of rows still queued with audio —
-- i.e. voicemails that have arrived but not yet been drained. Anything above that
-- is an orphan from Step 2's third query.
