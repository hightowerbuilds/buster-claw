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

### Walk the new automation primitives in the real app (~5 min)

**What.** The 07-18 automation build (wait / selector acting / extract /
flow / checks) is covered by fake-desktop protocol tests and Rust injection
tests, and the operator confirmed the browser works after the cold-boot fix —
but the five primitive-specific checks were never individually run:
(1) `browser_wait until:"selector"` on a slow SPA resolves past the old 8s
ceiling; (2) `browser_click text:"…"` acts with scroll-into-view; (3)
`browser_extract` with a selector returns structured matches; (4) a 3-step
`browser_flow` with a wrong selector fails at step 3 *with a screenshot*;
(5) `browser_check_save` → `run` → the `## Runs` line appears;
(6) with the app running, launch it a second time — the second launch must
exit immediately and focus the first window (single-instance guard; only
works between two post-07-18 binaries, so both launches must be fresh builds).

**Why deferred.** Needs operator hands on the real WKWebView; the operator
moved on after confirming the browser itself works (07-18).

**What makes it expensive later.** Same as every unwalked feature: the first
break becomes a beta user's bug report with cold context.

---

### Decide: `browser_wait` tier + `browser_flow` audit posture

**What.** Two trust-model defaults chosen deliberately in the 07-18 build,
awaiting operator ratification. (a) `browser_wait` is the **only safe-tier
co-presence command** — it returns just `matched: true/false`, but that is a
yes/no oracle about the live tab; flipping to `:restricted` is two lines plus
the tier snapshot. (b) `browser_flow`'s auto-audit records **full step args —
including fill values — to `security_events`** (documented out loud in the
catalog); the flow-level event redacts to lengths, but a password in a fill
step persists plaintext in the local audit DB. Alternative: length-redact
fill values before the choke-point audit too. Related one-liner: refresh any
out-of-repo prompts/skill docs naming the old `:missing_index` atoms
(now `:missing_target`).

**Why deferred.** Operator judgment on trust boundaries; the defaults are
live and documented, so nothing is broken meanwhile.

**What makes it expensive later.** (b) becomes a privacy surprise the first
time a real credential rides a flow — deciding after beta users exist means
renegotiating what's already on their audit feeds.

---

### Confirm the rotated DB password reached the password manager

**What.** The 07-18 Supabase rotation printed the new BusterClaw DB password
exactly once, in-session; it exists nowhere else. Confirm it's stored, then
delete this item. (The personal access token pasted that day needed no
revocation — 1-hour TTL, long expired.)

**Why deferred.** Only the operator can check their password manager.

**What makes it expensive later.** Nothing — nothing authenticates with the
DB password and a reset stays a two-minute dashboard job. Pure bookkeeping.

---

## Rules of engagement

- An item leaves this file by being **done** or by being **promoted** to a real
  roadmap because it turned out to need a design. It does not leave by rotting.
- If an item has sat here through two dev summaries without moving, that is a
  signal it is either not actually worth doing (delete it, and say so) or it is
  more important than "leftover" implies (promote it).
