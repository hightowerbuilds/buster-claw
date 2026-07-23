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

**Update 07-22 (shell-rebuild Phase 5):** the *infrastructure* half of this is
now automated — `scripts/smoke_desktop.sh` launches the packaged .app and
proves boot, auth, catalog, and a full native-bridge round-trip (the packaged
ACL check the 07-17/07-21 bugs demanded). What remains manual below is only
the interactive primitive walk in a real browser surface.

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

### Refresh out-of-repo prompts naming the old click/fill error atoms

**What.** `browser_click` / `browser_fill` fallbacks were renamed
`:missing_index` / `:missing_index_or_value` → `:missing_target` /
`:missing_target_or_value` on 07-18 (they can fail on more than an index now).
The repo is clean; anything *outside* it — saved prompts, agent skill docs,
personal notes — that names the old atoms should be updated.

**Why deferred.** Nothing in the repo can find or fix out-of-repo text.

**What makes it expensive later.** It doesn't get more expensive; it just
quietly misleads whoever reads that prompt next.

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
