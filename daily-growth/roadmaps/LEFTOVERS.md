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

### Decide the Playwright sidecar's fate (prune or keep)

**What.** `priv/playwright_sidecar/` (17MB of `node_modules`) plus
`BusterClaw.Browser.Sidecar` (~300 LOC) ship in the tree but are default-off and
never active in a packaged build (`browser_sidecar_enabled` gates to dev). The
sole survivor of the 07-17 code-quality roadmap (now archived).

**Why it matters.** It is ~19% of the shipped bundle
(`DISTRIBUTION_ROADMAP.md` §8) and pure dead weight in prod. Note 07-17: the
live-render fallback (`f963963`/`dd97932`) now covers the "agent can't read
SPAs" gap using the native webview, which weakens the remaining case for
keeping node/Playwright at all.

**Why deferred.** Operator call — prune only if browser-rendered fetch via
node/Playwright is declared dead as a product. Don't act unilaterally.

**What makes it expensive later.** Every future release ships (and every signed
build processes) 17MB of waste, and the distribution bundle-trim work will trip
over it; deciding now is free, deciding during the signing crunch is not.

---

## Rules of engagement

- An item leaves this file by being **done** or by being **promoted** to a real
  roadmap because it turned out to need a design. It does not leave by rotting.
- If an item has sat here through two dev summaries without moving, that is a
  signal it is either not actually worth doing (delete it, and say so) or it is
  more important than "leftover" implies (promote it).
