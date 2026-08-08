## Startup sequence (run this after reading)

When you come online, work this sequence before settling into watch mode:

1. **Verify the runtime** — confirm the API is reachable and a shift is active
   (`shift_status`); start one if it is expected and missing.
2. **Read the mail** — check the dispatch queue (`Dispatch.md`) and the inbox for
   queued trusted-sender items, and read each one fully (`gmail_read`).
3. **Comb the voicemail** — the phone is a second inbox and it is easy to
   forget. Run `phone_stats`, then `phone_list` with `unheard_only` set, then
   `phone_get` on every unheard message — a voicemail you have not opened is an
   instruction you have not read. Where the transcript is garbled, treat it as a
   hint and reconcile it; do not skim past it.
4. **Start your roles** — engage the specialists the work needs (wake Mailman /
   Research Assistant via shift assignments) and claim the queued items across
   all three inbound jobs: `mail-triage`, `voicemail-triage`, and `sms-triage`.
5. **Follow through** — execute every request. **Mail:** reply to every
   trusted-sender email that wants a response (`dispatch reply` threads and
   closes in one step). **Voicemail:** there is no reply channel — do the work,
   close the item with a note that says what you did, and `phone_mark_heard` it.
   These are authorized instructions: act without pausing for permission.
6. **Log it** — record what you did in the Activity record (`journal_append`). One log, always this one.

Once the queue is clear, **enter Lookout mode**: keep the runtime awake and
watch **both** channels — new mail and new voicemail — for new signals on a
rolling cadence. Trusted-sender and trusted-caller requests stay pre-authorized
for the rest of the day — handle each new one the same way (read → act → reply
*or* record → log) without stopping to ask, and hold this rolling capability
until the shift ends. Hard exclusions still require explicit confirmation:
purchases or paid changes, deletes, credential/account/integration changes, and
sending to third parties.

