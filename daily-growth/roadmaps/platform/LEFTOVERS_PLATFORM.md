# Leftovers — platform and code health

**Split out of `LEFTOVERS.md` 2026-08-09.** The tail work under the app rather
than in it: the guards, the hotspots, the test harness that does not exist, and
one credential to confirm.

**Everything here blocks nothing** and is **concrete**.

Small, real, and deferred on purpose. Nothing here is blocking a ship; everything
here is the kind of item that quietly never gets done because it never becomes
urgent — until it does, at which point it is expensive.

Covers [Supermap](../SUPERMAP.md) Part VII.

---

### Two wrong-direction failures found 08-09, both in shipped code

Found by agents building the Studio capture modules, both **outside** their scope
and deliberately not fixed there. Neither is urgent; both fail in the direction
that hides the problem, which is what earns them a line.

**1. A corrupt index header flatters itself to the highest trust tier.**
`lib/buster_claw/notifications/cutup/index.ex` — `load/1` maps an **unparseable
`origin` to `:manual`**. `manual` is the one origin that earns confidence **1.0**,
because it means a human marked the boundary by ear. So a corrupt or truncated
index header is read as the most trustworthy kind of data there is. It should
degrade to the *least* trusted origin, not the most.

*Why it matters later:* the whole point of the dictionary (Part VI) is that
`manual` is earned and permanent — `sound_index_import` even refuses to overwrite
without `overwrite: true` for that reason. A default that manufactures `manual`
from damage undermines the one provenance guarantee the corpus has. Cheap now
(one clause); expensive once real hand-corrections exist and nobody can tell
which are genuine.

**2. `agent_backend.ex` crashes the caller instead of returning its error tuple.**
`lib/buster_claw/agent_backend.ex:225-246` — the `rescue` sits **outside** the
`Task.yield`, but `Task.async/1` **links**. So if the enumerated CLI binary has
vanished, `System.cmd` raises inside the task and takes the calling process down
*before* the rescue can convert it to `{:error, {:enumerate_failed, _}}`. The
error path exists and is unreachable.

*Why it matters later:* it only fires when a backend CLI is uninstalled or moved
mid-session — rare, and exactly when a clear message matters most. The fix is to
move the `rescue` **inside** the task, which is what both
`notifications/capture/devices.ex` and `notifications/capture.ex` now do
deliberately; use either as the reference.

**Two of five agents hit this independently on 08-09** — one reasoning it out
before writing, the other discovering it when its own missing-binary test took the
caller down with an EXIT. That it was found twice, by different routes, says the
idiom is easy to get wrong rather than that one author slipped. A grep confirmed
`agent_backend.ex:235` is the **only** remaining site: the repo's other eight
`Task.async` calls do not rescue nearby, so this is a single fix and not a sweep.

---

### The code-quality roadmap's tail — Phase 4 and two odds

**What.** Inherited 08-03 when `CODE_QUALITY_REFACTOR_ROADMAP` was archived. Four
items, none needing a design:

- **Browser pages built by hand** — seven controllers under `/browser` assemble
  standalone HTML, CSS and forms as strings, **1,426 lines** of it. Move to HEEx
  function components and a shared browser-surface layout. While in there:
  **that scope has no `pipe_through`, so it receives no CSP header at all.** The
  pages escape every interpolation through `html_escape/1`, so it is
  defence-in-depth rather than a hole — but it is the one part of the app the
  08-03 `script-src 'self'` tightening does not reach.
- **Nested modules in production** — 4 files under `lib/` define a module inside
  a module, against the repo rule. Extract to their own files.
- **UML sections 3–5** — the Ecto schema diagrams and remaining flows still date
  from 06-14. Sections 1 and 2 had drifted badly enough to be re-derived from
  `lib/`, so assume these have too.
- **Voice edge-function tests** (Phase 0 item 8) — the Supabase voice function
  has none.

**Why deferred.** All four are mechanical, and the roadmap they came from closed
with its five findings resolved. None of them blocks anything.

**What makes it expensive later.** Only the first one really does: 1,426 lines
of hand-assembled HTML is where the next escaping mistake will live, and it
grows every time the in-app browser gains a page. The other three are cheap
forever — which is exactly why they never get done.

---

---

### Decompose the surviving hotspots — and make regrowth visible

*Inherited 08-08 from `archive/08-08-26-busterclaw-critical-review.md` Phase 4, the
only part of that review with no home in `LAUNCH_ROADMAP`. Its predecessor entry
here — "Decompose TradingLive" — died with the file on 08-08.*

**What.** Three surviving clusters, in size order: `explore_panel.ex` **1,577**,
`status_live.ex` **1,460**, `agent/chat.ex` **1,376**. `StatusLive` should become a
page coordinator — it currently owns chat, contacts, telephony, notifications,
weather, music, studio, notes, calendar, shaders and Explore. `Agent.Chat` splits
into a state machine, delivery persistence, queueing/steering, transcript
projection, and transport adapters. Two smaller items travelled with it: burn down
the Dialyzer baseline in risk order (audit/policy → dispatch → orchestration →
browser → filesystem → UI), and replace ignored returns in durability and security
paths with explicit handling.

**Why deferred.** Nothing is broken, and the extraction technique is proven twice
here: map lines-per-responsibility, extract, then `import` the extracted module so
the template call sites stay byte-identical. `StatusLive` needs no design, only an
afternoon each. `Agent.Chat` does need one — its state transitions aren't written
down anywhere yet — so by this file's own rule that half is a roadmap item the day
someone wants it.

**What makes it expensive later.** The load-bearing observation survived the file it
was made about: TradingLive was cut **3,503 → 1,900 (−46%)** and had grown back to
**2,174** by the time it was deleted. **The extraction held and the file still
regrew** — so this is a rate, not a one-time job. Either it gets re-cut
periodically, or something makes growth visible. That is the actual item: a CI
check that fails when an agreed file grows, which is cheap now and is the only part
that stops the next 2,000-line LiveView from arriving unnoticed. Same lesson as the
cycle count, which drifted back to 3 on 08-03 because nothing asserted it.

---

---

### A DOM harness for LiveView hooks, or an honest admission there isn't one

**What.** Three JS behaviours in the Notes editor are uncovered and cannot be
covered by anything this repo currently owns: a debounce firing after its
component was destroyed, caret/selection survival across a LiveView preview
patch, and reduced-motion/narrow-layout interaction. The same gap applies to
every other hook in `assets/js/hooks/` — Notes is only where it got written down.
`bun test` covers pure functions (this is why `note_keys.js` exists at all), and
`render_hook/3` covers the *server* end of a hook's events while never loading
`assets/js`.

**Why deferred.** Adding jsdom or a real browser runner is a testing-strategy
decision for the whole app, and it was not this roadmap's to make. Faking it —
asserting on markup and calling it a JS test — would be worse than the gap,
because it reads as coverage.

**What makes it expensive later.** Nothing gets more expensive; it stays exactly
this size. The risk is the failure mode instead: hook bugs are invisible to a
green suite, which is the same shape as the `phx-hook`-not-registered bug that
already shipped once and now has `HooksRegisteredTest` guarding it. That test
covers *existence*; nothing covers *behaviour*.

---

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

---


---

## The rule for this file

An item earns a line only if it is **concrete** (someone could do it today
without a design), and it carries **why it was deferred** and **what makes it
expensive later**. If an item needs a design, it belongs in a real roadmap, not
here.

## Rules of engagement

- An item leaves this file by being **done** or by being **promoted** to a real
  roadmap because it turned out to need a design. It does not leave by rotting.
- If an item has sat here through two dev summaries without moving, that is a
  signal it is either not actually worth doing (delete it, and say so) or it is
  more important than "leftover" implies (promote it).

---
