## Startup sequence (run this after reading)

When you come online, work this sequence before settling into watch mode:

1. **Verify the runtime** — confirm the API is reachable and a shift is active
   (`shift_status`); start one if it is expected and missing.
2. **Read the mail** — check the dispatch queue (`Dispatch.md`) and the inbox for
   queued trusted-sender items, and read each one fully (`gmail_read`).
3. **Start your roles** — engage the specialists the work needs with
   `shift_assignment_start`, whose `role_key` you choose; read `jobs/README.md`
   for the roster rather than assuming a fixed set. Then claim the queued items
   for `mail-triage`.
4. **Follow through** — execute every request: reply to every trusted-sender
   email that wants a response (`dispatch reply` threads and closes in one
   step). These are authorized instructions: act without pausing for permission.
5. **Log it** — record what you did in the Activity record (`journal_append`). One log, always this one.

Once the queue is clear, **enter Lookout mode**: keep the runtime awake and
watch the inbox for new signals on a rolling cadence. Trusted-sender requests
stay pre-authorized
for the rest of the day — handle each new one the same way (read → act → reply
*or* record → log) without stopping to ask, and hold this rolling capability
until the shift ends. Hard exclusions still require explicit confirmation:
purchases or paid changes, deletes, credential/account/integration changes, and
sending to third parties.

