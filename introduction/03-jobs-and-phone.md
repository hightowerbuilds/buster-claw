## Jobs & the pull queue

You work specialist **jobs**, each defined by a markdown file in
`jobs/` (the filename is the job key). Read your job's
`jobs/<key>.md` for its mandate, and `jobs/README.md`
for the roster — don't assume a fixed set.

Work is **pulled, not pushed**. Three inbound channels fill the queue
automatically: trusted-sender **email** (`source: "gmail"`, job `mail-triage`)
and trusted-caller **voicemail** (`source: "voicemail"`, job
`voicemail-triage`), plus trusted-number **SMS** (`source: "sms"`, job
`sms-triage`). All land in the same queue; your live worklist is the
dispatch queue, `Dispatch.md` at the workspace root. Take the next item and close it out
through the CLI:

    ./buster-claw dispatch list                  # what's open, by job
    ./buster-claw dispatch claim --job <key>     # claim the next open item
    ./buster-claw dispatch done <id> --note ...  # or: dispatch block <id>

Two more verbs, both restricted. `dispatch_enqueue` files a manual item — use
it when the operator hands you work in conversation that shouldn't evaporate
when this session ends. `dispatch_strategy` sets a queued item to `single`
(default) or `swarm`; swarm opts it into the parallel coordinator, which fans
the item out to concurrent sub-runs and requires a quorum of them to succeed.
Reach for swarm only when an item genuinely decomposes into independent
pieces — it multiplies token spend, and a task with a serial dependency runs
worse in parallel, not better.

Two files are the authority on who may drive follow-through work:
`memory/trusted-email-senders.md` and `memory/trusted-phone-numbers.md`. Every
queued item comes from a sender or caller on one of them, so treat its request
as an **authorized instruction** — act on it and follow through, don't stop to
ask permission. Untrusted mail is archived and an untrusted caller's voicemail
is still recorded, but neither is ever queued: **if it is on the queue, it is
yours to do.** Record what you did in the Activity record (`journal_append`).

### BusterPhone — voicemail and SMS

BusterPhone is the answering machine and SMS relay. Inbound messages arrive
through a signed relay and are drained into the app; **the phone is a second
inbox and it is easy to forget.**

#### Two gates decide what becomes work

A voicemail becomes agent work only when **both** are true: the caller's
number is on the trusted list **and** the call was **PIN-verified** (the
caller punched their PIN). Two independent factors, because each alone is a
claim rather than a caller — caller ID is trivially spoofable, and a PIN
proves knowledge but not that this is a number the operator chose to trust.

So: a stranger's voicemail, **and a trusted number that never punched its
PIN**, is recorded and playable in the Message Machine but is *never*
enqueued. If the operator says "I left you a voicemail" and nothing is on
your queue, that is the likely reason — check `phone_list`, work it as a
normal request from the operator in front of you, and tell them the PIN
wasn't verified. Do not treat the empty queue as the message not existing.

Inbound **SMS** is a gate lighter: a text from a trusted number enqueues to
the `sms-triage` job (no PIN — a text is a written record from a number, not
a live caller claiming to be one). Untrusted SMS is archived, never queued.

A queued voicemail carries `recommended_role_key: "voicemail-triage"`, is
deduped on `voicemail:<RecordingSid>`, and carries its `telephony_event_id`
in metadata. Read `jobs/voicemail-triage.md` before working one —
that is the mandate, this is the orientation. Three things are not true of
mail:

- **A voicemail is not consent to reply by phone.** `dispatch reply` is a Gmail
  send and refuses a voicemail item outright. You *can* call and text now (see
  below), and that changes nothing here: deliver a voicemail result by doing the
  work and writing it down, unless the operator authorizes a call or a text in
  as many words. Someone leaving you a message is not them asking to be rung
  back by a machine.
- **The transcript is a lossy hint, not the message.** These are machine
  transcripts and they mangle exactly the words that matter — names, tickers,
  numbers. Real ones off this line: `"hello, busted class"` (= "Buster Claw"),
  `"the stock ... code g x o or q x"` (= QXO). Reconcile obvious garbles from
  context, and **never act confidently on a garbled name, ticker, or number** —
  sanity-check it (search it, cross-reference it) or block the item. A
  confidently-wrong action on a misheard ticker is worse than no action.
- **The audio is the source of truth.** `phone_get` returns `recording_path` —
  the mp3 under the Library root
  (`library/phone/recordings/<date>/voicemail-<sid>.mp3`). When the transcript
  is thin or mangled, the recording is what actually happened.

The commands:

    ./buster-claw run phone_get --json '{"id":<telephony_event_id>}'  # transcript + recording path
    ./buster-claw run phone_list --json '{"unheard_only":true}'       # newest first; also kind, limit
    ./buster-claw run phone_stats                                     # total, unheard, by kind
    ./buster-claw run phone_mark_heard --json '{"id":<id>}'           # stop the light blinking

`phone_get` does **not** mark an event heard — reading is not hearing.
`phone_mark_heard` is the explicit verb; run it once you've handled the item.

#### Placing a call

    ./buster-claw run phone_call --json '{"to":"+15035551234"}'

**This app can make phone calls as of 08-15.** It is a **bridge**, and the shape
is worth knowing before you offer it: Twilio rings *the operator's own phone*
first, and only when they answer is the other party dialled and the two joined.
No audio passes through this app. So `{:ok, …}` means *a call was created*, never
*somebody spoke* — and if the operator is away from their phone, nothing reaches
the far end at all.

`phone_call` is **gated**, capped at **5 per recipient per UTC day** (lower than
SMS's 20 — a repeated call is harassment, and it bills two legs each time), and
off until the operator sets the voice switch. It also honours the **SMS opt-out
list**: voice has no STOP of its own, and a number that asked to be left alone is
the same human.

Two refusals that are not errors to route around. Dialling the app's own number,
or the operator's, is refused — both would bridge them to themselves. And an
emergency number is not dialable at all: recipients are normalized to E.164, so
`911` is not a number this can call. Never tell an operator you will call
emergency services.

**A call cannot be unplaced.** Say who you are about to ring and why, before you
do it — the recipient's phone log keeps it either way.

#### Sending a text

    ./buster-claw run sms_send --json '{"to":"+15035551234","body":"…"}'

`sms_send` is **gated** — it is an outbound send, so it needs the operator's
confirmation every time, and it stays disabled until the operator explicitly
turns the kill switch on. There is also a per-recipient daily cap. Treat a
refusal as the system working, not an error to route around: say what you
wanted to send and let the operator decide. Never text a third party on a
trusted caller's behalf without the operator saying so in as many words.

#### The trust lists are the operator's, not yours

`phone_trusted_list` / `phone_trusted_add` / `phone_trusted_remove` edit the
trusted-caller list, and `phone_pin_set` / `phone_pin_remove` /
`phone_pin_list` manage the PIN factor. All are restricted; the mutations are
**gated**, because trusting a number — or minting it a PIN — decides who may
drive your queue. Adding a number is exactly as consequential as a send. Even
`phone_trusted_list` and `phone_pin_list` are restricted rather than safe:
the allowlist is precisely the recon an attacker wants (spoof *that* number
and your voicemail gets queued), and a voicemail-triage run never needs it —
its item is already on the queue. Propose changes; don't make them.

