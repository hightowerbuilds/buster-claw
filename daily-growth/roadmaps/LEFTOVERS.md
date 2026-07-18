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

### Walk the merged browser/tab features in the desktop app, once

**What.** The ten browser/tab features merged 07-02 (Shortlist PRs #1–#9, items
10–12) were verified with **compile + tests only** — nobody has clicked through
them in the running desktop app. The checklist, moved here when the Shortlist
was retired (07-14):

- **Tab UX:** with a single tab open, Cmd-W closes the tab but the app stays
  open on a fresh home tab (does NOT quit); Cmd-Q still quits. Right-click a
  joined tab → Rename → edit inline → label survives a reload.
- **History → SQLite:** browse, revisit a site; homepage "Recent" dedupes for
  display, visit counts reflect revisits, search returns matches.
- **Chrome polish:** loading indicator (orange spinner + progress bar) appears
  during navigation and clears on finish (and within ~20s on a stuck load);
  tabs show real page titles and favicons.
- **Bookmark folders:** add into a folder → grouped render on the homepage;
  export → import round-trips with no duplicates; an old flat bookmark file
  still loads at root.
- **Agent co-presence:** `browser_current` returns the active tab's URL+title;
  `browser_navigate` drives the live tab; `browser_open_tab` opens one (strip
  stays in sync); all three are `:restricted` and land on the Sentinel feed.
- **Cmd-1…9** switches tabs by position (Cmd-9 = last tab).
- **Busy-terminal close confirm:** closing a terminal tab with a running
  foreground process prompts; an idle shell closes silently.
- **/browse full width:** the solo browser page fills the window like /split.

**Why it matters.** These are shipped features on main. Until walked, "shipped"
means "compiles."

**Why deferred.** It needs operator hands on the actual app — the native
WKWebViews, PTYs, and macOS keyboard shortcuts can't be driven by the test
suite or an agent.

**What makes it expensive later.** The walk is ~15 minutes today with warm
context and a known fix-forward pattern (same as Cmd-W #1→#8). Skipped, the
first discovery of a break becomes a beta user's bug report months after the
merge, with cold context and the distribution clock running.

---

## Rules of engagement

- An item leaves this file by being **done** or by being **promoted** to a real
  roadmap because it turned out to need a design. It does not leave by rotting.
- If an item has sat here through two dev summaries without moving, that is a
  signal it is either not actually worth doing (delete it, and say so) or it is
  more important than "leftover" implies (promote it).
