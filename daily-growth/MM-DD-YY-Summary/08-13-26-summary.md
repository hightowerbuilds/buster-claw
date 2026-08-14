# 08-13-26 — Two gates that weren't gating, and a phone that doesn't want SSH

A day of guards rather than features, and both guards turned out to be guarding
nothing. In between, a question about phones changed which half of a problem we
are solving.

| Shipped | Commit |
|---|---|
| Remote-mode notices pinned before a tunnel makes them load-bearing | `d26c4ad` |
| Phone access scoped, then reshaped around an operator call | `accbc70`, `1225a88` |
| Clinch Phase 5 marked as far as an agent can take it | `c948c80` |
| **The Dialyzer gate: exit 2 with 67 findings → exit 0 with none** | `1d52cff`, `8dc0cf6` |

---

## The notice guards, and two tests that were proving nothing

Phase 5 says *"no empty xterm, invisible native browser, or dead Voice toggle
ships."* All three already degrade honestly, so this was a guard, not a build —
the risk is that they stop, and nobody is on a tunnel to see it.

Every assertion was verified by reintroducing the defect. **Two did not fire on
the first attempt, and both were the test being wrong:**

- **The terminal contract isn't what I wrote it as.** `terminal.js` never queries
  `[data-terminal-status]`; it reads `dataset.statusId` and resolves it with
  `getElementById`. The inventory's own staleness check caught that, which is the
  one part of the design that earned its keep.
- **"Both credential panels ship a notice" was proving one panel.**
  `clinch_panels.ex` renders the notice twice — once in `clinch_panel`, once in
  `app_keys_panel` — and a `=~` over the whole page is satisfied by either. I
  regressed exactly one and the test stayed green.

> **A substring match over a rendered page cannot assert a plural claim.** The
> test's name said "both"; its assertion said "at least one." It counts now,
> against a panel count derived from the `data-clinch-unavailable` markers rather
> than hardcoded, so a third self-hiding panel raises the bar on its own.

---

## The phone question, and why SSH is the wrong half

"Can I SSH into my laptop from my phone?" turns out to be two questions. A shell
on the Mac is solved and unglamorous. **The UI on the phone is where SSH stops
being the right tool**, for reasons that are structural rather than fixable:

- iOS suspends a backgrounded app within seconds and its sockets die. "Open SSH
  app, start tunnel, switch to Safari" is the exact motion that kills the tunnel.
- **Every iOS SSH client that survives this borrows an entitlement that has
  nothing to do with SSH.** Blink's documented mechanism turns on *location
  tracking* to keep the session alive. That is a workaround, not a capability.
- mosh survives sleep and roaming and **cannot forward ports** — it solves the
  terminal and is structurally incapable of solving the UI.
- NAT and persistence are different problems. A mesh VPN fixes reachability and
  does nothing for backgrounding; conflating them is how this wastes a month.

Then the operator's call reframed it: **the phone is a control device, not a
second Buster Claw, and no VPN goes in the path.** Everything hard above comes
from putting a *window* on a phone. A control device needs a *channel* — and we
already own one.

> **`Telephony.Drain` polls outward every 30 seconds and the Mac never listens.**
> There is no port to reach and nothing to expose, so the "how does the phone
> reach my Mac" problem does not arise. It has been deployed since 07-12.

**The gap, checked rather than assumed:** the relay, the outbound drain and
`Twilio.send_sms` all exist, and **nothing connects an inbound message to the
agent** — not one reference to it anywhere in `lib/buster_claw/telephony/`. Today
an inbound message lands in a list. It is a mailbox, not a conversation.

### The two things that cost money, settled

- **A2P fees belong to The Campaign Registry and the carriers.** Switching to AWS
  or any other provider swaps the vendor and keeps the fees. Personal SMS use is
  ~$5–7/mo; the compliance regime is the real cost, and the GTM went voice-first
  precisely to avoid it.
- **A $5 rented box was evaluated and rejected — not on price.** A relay that
  terminates TLS holds Chat messages in plaintext on someone else's hardware,
  which is a *worse* privacy posture than the WireGuard mesh it was meant to
  avoid. And you would then be running a public internet-facing server; the $5 is
  the cheapest part.
- **Teaching Buster Claw to provision its own cloud instance is refused.** It
  means agent-reachable credentials with instance-creation rights, it contradicts
  the standing rule that Buster Claw never automates public exposure, and it aims
  the agent at credentials that *spend* money when the Clinch exists to keep it
  from credentials that merely unlock things.

Parked until the desktop app ships, by operator call.

---

## The Dialyzer gate was catching new files, not defects

It exited 2 with **67 findings** and blocked nothing. 51 were `unmatched_return`
in files written after the 08-02 baseline — `notes.ex`, `pockets/`,
`terminal_theme.ex`, `chat_skin.ex`, `clinch.ex`, the `live/status/` split. None
were problems.

Section 1 was a hand-written list of 76 files, so **it rotted the instant anyone
added a file.** It is a rule now:

> `unmatched_return` is accepted everywhere EXCEPT paths where a silently
> discarded return could lose a security record or persisted data — computed from
> the tree, so adding a file elsewhere cannot rot it.

The gated set is chosen by that question, not by importance. Ten discards inside
it are now written as `_ =` with a reason. **The gate had already paid for itself
retroactively:** two Clinch revocation categories once recorded nothing while the
whole suite stayed green, because `Event` whitelists categories and `observe/4`
is best-effort. The discarded return was the tell.

**All 16 non-`unmatched_return` findings were traced and none was a defect** —
defensive clauses Dialyzer has now disproved. They are *listed* rather than left
reported, because a baseline that stays red blocks nothing and trains people to
skip the output, which is the exact state this found.

### Three corrections, all from testing rather than reasoning

1. **My first `_ =` landed in the wrong place.** It went on the
   `Sentinel.observe` call, but the unmatched expression was the `if` wrapping
   it — an `if` without `else` yields `nil`, and that was what got discarded. The
   gate caught my own fix.
2. **My first attempt to break the gate passed, and it was a false negative.** I
   put a discarded return in an *uncalled* `defp`; Dialyzer does not analyse
   unreachable code. Had I stopped there I would have reported a working gate
   without having shown one. Redone inside a function `delete/2` actually calls,
   it fails with exit 2 naming the line. **Green never means "no discarded
   returns exist here"** — that limitation is now in the file.
3. **`sound.ex`'s `no_return` is not a crash.** `import_index/4` returns fine;
   `sound_test.exs` round-trips it and asserts `{:ok, imported}`. Three
   hypotheses were checked and all three were wrong. It is a type-chain artifact,
   recorded so nobody re-opens it as a bug.

### The rule needed its own test, for a reason the list didn't have

**A prefix-match rule fails silently in the safe-looking direction.** Rename a
gated file, or mistype a prefix, and it matches nothing — quietly accepted, gate
green, looks like it worked. That is the same rot as before, just harder to see.

`BusterClaw.DialyzerBaselineTest` names the files that must be gated by *what
they protect* and derives the gated set from the ignore file's own output, so
there is one source of truth. It fails on all three undo paths, each verified by
doing it: a mistyped prefix, the rejection being deleted (the tempting fix for a
red gate), and a gated file hand-added back to the accepted list.

Suite: **3,822 tests, 0 failures.**

---

## Where that leaves the board

The Clinch is as far as an agent can take it — Phase 5's preconditions are pinned
and its notices are guarded, and what remains is the tunnel spike, which needs a
person with two machines.

**With the gate green, every remaining item at the top of the Supermap waits on
the operator**: the tunnel spike, the Apple Silicon Mac for `G-4`, BusterPhone's
Twilio steps, and a person at a microphone for Studio. That is worth saying
plainly rather than discovering it next session.
