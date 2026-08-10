# Leftovers — the index

Small, real, and deferred on purpose. Nothing here is blocking a ship; everything
here is the kind of item that quietly never gets done because it never becomes
urgent — until it does, at which point it is expensive.

**Split into three maps 2026-08-09** so each one hangs off the part of the
[Supermap](SUPERMAP.md) that owns it. One file of 25 unrelated items was read by
nobody looking for any of them.

| Map | Covers | Items |
|---|---|---|
| [`LEFTOVERS_SURFACES`](LEFTOVERS_SURFACES.md) | Supermap II–III — Notes, Chat, Explained, Manual, Music, Browser | 11 |
| [`LEFTOVERS_AGENT_CORE`](LEFTOVERS_AGENT_CORE.md) | Supermap V — runner, command surface, skills, Scene3D, sound verbs | 9 |
| [`LEFTOVERS_PLATFORM`](LEFTOVERS_PLATFORM.md) | Supermap VII — guards, hotspots, test harness, one credential | 5 |

**The two HIGH items left this file entirely** and are now release gates:
`G-34` (walk a signed-in checkout, confirm the payment gate fires) and `G-35`
(`nosniff` on the four pipeline-less media routes), both in
[`TRUST_AND_SUPPORT_ROADMAP`](TRUST_AND_SUPPORT_ROADMAP.md). `G-35`'s detail
stayed with the media surface in `LEFTOVERS_SURFACES`.

---

## The rule for these files

An item earns a line only if it is **concrete** (someone could do it today
without a design), and it carries **why it was deferred** and **what makes it
expensive later**. If an item needs a design, it belongs in a real roadmap, not
here.

## Rules of engagement

- An item leaves these files by being **done** or by being **promoted** to a real
  roadmap because it turned out to need a design. It does not leave by rotting.
- If an item has sat here through two dev summaries without moving, that is a
  signal it is either not actually worth doing (delete it, and say so) or it is
  more important than "leftover" implies (promote it).

---

## Promotion history

Kept because it is the record of this file working as intended — twice, items
that needed a design or blocked a release left rather than rotting here.

### Promoted 08-02 → `BROWSER_CLOSEOUT_ROADMAP.md`

Four browser items left this file together: the **signed-in checkout walk**
(HIGH), `find_elements`' **selector**, the **Keychain-backed `secret_resolver`**,
and **per-host egress levels**. They went to a real roadmap because the biggest
open browser question — *may the agent confirm a purchase, and what should a
confirmation even produce now that the wallets ledger is deleted?* — needs a
design, and this file's own rule says a thing needing a design does not belong
here. Their detail travelled with them; nothing was lost.

---

### Promoted 08-03 → `LAUNCH_ROADMAP.md` **G-40**

Every item that needed *a person looking at a packaged build* left this file
together and became one release gate: the **Chart Build look**, the
**first-open workspace through the setup wizard**, and the **packaged byte-range
and codec walk** — joined there by the **signed-in checkout walk** inherited
from `BROWSER_CLOSEOUT_ROADMAP.md` on its archive.

They went because they are one sitting, not four errands, and because splitting
them across two documents is why none of them had happened. The detail travelled
with them; nothing was lost. This file's rule still holds — they needed no
design, only a build and an afternoon — but they blocked a release, and this
file is explicitly for things that block nothing.

---


---

## Completed, kept as evidence

The one item that left by being **done** rather than promoted. Kept because it
records *what was actually walked* against a packaged build — which is the thing
a later "has anyone tested this?" question needs, and which no test asserts.

<!-- DONE 07-22: "Walk the new automation primitives in the real app" — walked
against the PACKAGED app (stronger than the dev-shell ask). Agent side driven
via /api/run: wait (match + real 10s timeout), click text (matched_by:text +
navigation), extract selector+attr (30 matches), flow failing at the reported
step WITH screenshot on disk (twice), check_save→run→`## Runs` line, plus
open_tab (session:ephemeral honored), find_elements, read, screenshot (valid
PNG). Operator confirmed GUI side: co-presence badge flashed on every call,
7-tab eviction, sidebar bumper/⌘B, zoom, ⌘F count, popup-as-tab, download +
reveal, menu accelerators, and the double-launch single-instance check. -->
