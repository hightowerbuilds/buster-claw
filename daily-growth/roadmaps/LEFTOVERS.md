# Leftovers

Small, real, and deferred on purpose. Nothing here is blocking a ship; everything
here is the kind of item that quietly never gets done because it never becomes
urgent — until it does, at which point it is expensive.

The rule for this file: an item earns a line only if it is **concrete** (someone
could do it today without a design), and it carries **why it was deferred** and
**what makes it expensive later**. If an item needs a design, it belongs in a real
roadmap, not here.

---

## Open

### Rotate the Supabase database password

**What.** The telephony project (`tzptdzmwypdmmnmbruke`) still has the database
password it was created with on 07-13: `buster-claw-2026`.

**Why it matters.** Supabase Postgres is reachable from the open internet
(`db.<ref>.supabase.co:5432`, plus the pooler). That password is a dictionary
phrase plus the current year — it is guessable by anyone who knows the project's
name, and it is the shape a credential-stuffing list tries early. This is the
database that now holds callers' phone numbers, voicemail recordings, and
transcripts: real PII belonging to people who never agreed to be in the system.

It was also pasted into a chat transcript during setup, which is an independent
reason to change it.

**Why deferred.** Operator call, 07-13: not blocking, and the practical risk
while the project holds only the operator's own test voicemails is low.

**What makes it expensive later.** Nothing, mechanically — it stays a two-minute
job. But the risk it carries is not flat: it scales with the first *real* caller's
voicemail. The moment BusterPhone answers for someone who is not Luke, this stops
being a hygiene item and becomes a breach waiting for a bored scanner. Do it
before the first outside caller, not after.

**How.** Project Settings → Database → Reset database password.
<https://supabase.com/dashboard/project/tzptdzmwypdmmnmbruke/settings/database>

A generated candidate (07-13): `ziP97WRSV9NBKuMT7FswjbKCBisNZvEA`. Into a password
manager, not the repo. Nothing depends on it: `supabase link` caches it, and the
app authenticates with the service-role key, not the DB password. So rotating it
breaks nothing.

---

### Tear down the old Supabase project's telephony surface

**What.** The `voice` edge function is still deployed, and `TWILIO_ACCOUNT_SID` /
`TWILIO_AUTH_TOKEN` are still set as secrets, on the **old** project
`gbnizxzurmbzeelacztr` — which is the `notes-that-float` project, and also holds
`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `GITHUB_TOKEN`, and customer data.

**Why it matters.** Two live endpoints can answer the phone number, and a Twilio
credential is parked in a project full of unrelated production secrets. Neither is
needed: BusterPhone moved to its own project (`tzptdzmwypdmmnmbruke`) on 07-13 and
is proven end to end there.

**Why deferred.** Sequencing — we wanted the new path proven with a real call
before deleting the old one. It now is.

**What makes it expensive later.** It doesn't get more expensive; it just stays
wrong. The failure mode is forgetting it exists and being surprised by a Twilio
charge or a leaked token from a project nobody associates with telephony.

**How.**

```sh
supabase functions delete voice --project-ref gbnizxzurmbzeelacztr
supabase secrets unset TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN --project-ref gbnizxzurmbzeelacztr
```

**Known consequence:** this kills the trial number (+1 844-687-8016), which points
at the old function. That number is being retired anyway — but make it a decision,
not a surprise.

---

### Record the new Twilio number

**What.** The roadmap (`BUSTERPHONE_ROADMAP.md`) and the agent memory still name
the retired **trial** number, +1 844-687-8016. The live paid local number bought
on 07-13 is not written down anywhere.

**Why it matters.** The trial number appears in docs as if it were the product's
number. Anyone following the docs tests the wrong line.

**Why deferred.** Nobody wrote it down in the moment.

**How.** Get it from the Twilio console, then update `BUSTERPHONE_ROADMAP.md`,
`supabase/SETUP.md`, and the `busterphone_roadmap` memory.

---

### `auth_status` on `dispatch_items` is (probably) dead

**What.** Every row in `dispatch_items` — all 120 gmail items and all 3 voicemail
items — carries `auth_status = "unverified"`. It is not obvious that anything ever
sets it to anything else.

**Why it matters.** It is a field that *looks* like a security signal and may be
one nobody computes. That is the same class of bug as the `telephony_contacts.trusted`
decoy column deleted on 07-13 (commit `ed048c1`): an unwired switch that a future
change binds to and trusts.

**Why deferred.** Needs five minutes of grep to confirm before deciding whether to
populate it or delete it. Being investigated as part of the caller-ID spoofing
work, which is a real roadmap item and not a leftover.

---

## Rules of engagement

- An item leaves this file by being **done** or by being **promoted** to a real
  roadmap because it turned out to need a design. It does not leave by rotting.
- If an item has sat here through two dev summaries without moving, that is a
  signal it is either not actually worth doing (delete it, and say so) or it is
  more important than "leftover" implies (promote it).
