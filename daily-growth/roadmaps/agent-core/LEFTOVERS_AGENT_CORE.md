# Leftovers — the agent core

**Split out of `LEFTOVERS.md` 2026-08-09.** The tail work in the machinery every
surface sits on: the runner, the command surface, skills, Scene3D, and the sound
verbs the Studio never got.

**Everything here blocks nothing** and is **concrete**.

Small, real, and deferred on purpose. Nothing here is blocking a ship; everything
here is the kind of item that quietly never gets done because it never becomes
urgent — until it does, at which point it is expensive.

Covers [Supermap](../SUPERMAP.md) Part V.

---

### `agent/chat.ex` is owed a cut — the frozen promise was broken 08-08

*Inherited 08-08 when `CHAT_ATTACHMENTS_ROADMAP` was archived.*

**What.** `lib/buster_claw/agent/chat.ex` is **FROZEN** in `check_file_sizes.sh` —
the tier that means *already too big; may shrink, never grow*. Chat attachments
grew it 1,376 → 1,510 and the cap was raised to match. **That is a broken
promise, and it is filed here rather than left as a number nobody remembers
earning.**

**Why deferred.** Roughly half the growth is documentation and the rest is a
GenServer message gaining a field — every `handle_call({:submit, …})` clause, the
queue that carries a message until its turn runs, and the resolve step. **You
cannot extract "this process's messages carry one more thing."** The delivery
logic itself was correctly kept out (it lives in `ChatTransport`, +112, and
`claude_duplex`, +51).

**What makes it expensive later.** This is the third time a decomposition in this
repo has been undone by regrowth, which is why the gate exists at all. The file
is a target of the modularization work; the honest cut is to extract the queue
and run-lifecycle half, not to shave the attachment threading. **Do not raise
this cap again without extracting first** — twice is a pattern.

---

---

### Cost aggregation — the totals, not the capture

**From the agent-backend roadmap's Phase 4** (`daily-growth/archive/08-04-26-agent-backend-roadmap.md`). The capture is
done and shipped: `StreamEvent.usage` normalizes input/output/cache/cost across
all three harnesses, `run_usage/2` reads it out of a completed blocking run, and
the Sentinel feed already carries harness, model and cost per run. What does not
exist is any **total** — per surface, per day, per harness.

**Concrete enough to do today.** The data source is `Sentinel.list_events/1`;
the shape is a sum grouped by `metadata["agent"]` and surface over a date range,
rendered wherever Activity already lives.

**Why it was deferred.** It is a display problem, and the capture underneath it
had only just been proven. Shipping the sum on the same day as the measurement
would have meant trusting a number nobody had looked at twice.

**Three things that make it harder than a `SUM()`.** Codex reports tokens and
**no dollars**, and its cost must stay nil rather than be derived — a price table
this app does not own would make an invented figure look authoritative. So any
total spanning harnesses is either two columns or an explicit "+ N tokens on
codex, not priced". Second, the feed is an audit log, not a ledger: it is
prunable and was never designed as a billing source, so a total read from it is
"what we observed", not "what you were charged". Third, only chat and the order
path record usage today — the dispatcher and swarm surfaces run through
`AgentRunner.run/2` and drop their result event on the floor, so a "per surface"
total would silently read zero for three of six surfaces. That last one is the
real prerequisite and is the reason this is not a half-hour job.

**What makes it expensive later.** Nothing breaks by waiting. But the app now
tells the operator the harness is theirs and the cost is theirs, which invites
exactly the question this would answer — and an operator who asks "what did
today cost" and gets nothing will not ask twice.

---

### `opencode models` is uncached, and must not reach a render path

**From the agent-backend roadmap's Phase 2** (`daily-growth/archive/08-04-26-agent-backend-roadmap.md`).
`AgentBackend.enumerate_models/1` shells out to `opencode models` with a 15s
timeout. Its docstring says loudly that it must be resolved in a Task and cached
— and **nothing calls it yet**, so today that warning is the only protection.
The Settings harness picker offers free text plus claude's shipped list instead.

**Concrete:** resolve it once per session into a cache (or on an explicit
refresh), and only then have the picker offer opencode's real list.

**Why deferred.** Wiring it live without a cache would put a subprocess spawn in
a LiveView render, which is the kind of thing that is fine until the binary is
slow or missing.

**What makes it expensive later.** The list is per-machine (it reflects the
operator's authenticated providers), so this is the only honest way to offer
opencode models at all. Until it exists, opencode users type model IDs by hand.

---

---

### Two skill seeds were never combed

*Inherited 08-09 from `archive/DOC_DRIFT_ROADMAP.md`.*

**What.** Read `skill-seeds/shader-designer.md` (108 lines) and
`sound-cutup.md` (183 lines) against the code, the way the 08-09 pass did for
`introduction/*.md`. Same for the three job mandates seeded as heredocs in
`jobs.ex` (`mail-triage`, `voicemail-triage`, `sms-triage`) — the roster was
verified, the mandates inside were not.

**Why deferred.** The comb was scoped to the surfaces most likely to be wrong
and ran out of afternoon. Neither seed showed a symptom; neither was checked.

**What makes it expensive later.** These are **reference playbooks the model
reads to author an artifact** — a wrong constraint here produces a broken shader
or a bad cut rather than a confusing sentence. And they are seeds: `maybe_write`
never overwrites, so an error ships permanently into every workspace that has
already been created. See the shipped-defaults problem in `LAUNCH_ROADMAP` V.8.

---

---

### Move the scene3d guide into a reference skill

*Inherited 08-08 from `archive/08-08-26-scene3d-roadmap.md`.*

**What.** `Scene3d.guide/0` is now a substantial block teaching primitives,
composition helpers, the `region`/`surface` vocabulary, a label budget and the
SVG-vs-3D channel line. It ships in the homepage system prompt on **every turn**,
alongside `SvgViewer.guide/0`. Make it a `handler_kind: reference` skill instead —
`skills/scene-designer.md`, sibling to the existing `shader-designer`.

**Why deferred.** The guide has to be right before it is worth relocating, and
"right" is an empirical question nobody has enough transcripts to answer yet. The
one live signal so far — the model choosing a 3D scene for a flat map — was
answered by making the guide *longer*, which is the wrong direction to relocate
from.

**What makes it expensive later.** This is a compounding cost, not a fixed one:
every turn on the homepage pays for the whole guide, and each vocabulary addition
makes it worse. Skills are runtime-loadable and operator-editable; a system-prompt
string is neither, so today the only way to tune the wording is a recompile. The
`shader-designer` skill is the worked precedent, so this needs no design — only
the confidence that the words have settled.

---

---

### Scene3D's unbuilt polish — all of it waiting on evidence

*Inherited 08-08 from `archive/08-08-26-scene3d-roadmap.md`.*

**What.** Three cosmetic items and one interaction, none started: widen the
faceted shading (`Project` already computes `shade`; `Svg` applies it narrowly),
a ground contact shadow, a depth cue, and **orbit drag** — porting the projector
to JS so a card can be turned with the pointer.

**Why deferred.** The cards became legible on 08-08 and nobody has yet wanted
them prettier or wanted to rotate one. Orbit in particular costs the most and is
the least justified: it duplicates ~200 lines of projection math in JS, and would
need a lockstep test pinning both implementations to the same projection for a
fixture scene — because the Elixir suite cannot see JS, so without one they
silently diverge.

**What makes it expensive later.** Nothing structural; these stay additive. The
one trap is the depth cue: **`depth` is in scene units and is not
scale-invariant** — only the ordering is — so an implementation that treats it as
a 0–1 quantity works on a small scene and breaks on a large one. That constraint
is recorded in `t:BusterClaw.Scene3d.Types.poly/0` where it will be read.

---

---

### The `sound` command surface — the Studio has no CLI

**What.** Inherited 08-02 when `SOUND_STUDIO_ROADMAP` was archived (its Phase 2,
never built). New `commands/catalog/sound.ex`: `sound_list` (both layers,
showing which wins), `sound_import`, `sound_trim`, `sound_apply` (write into the
library and route a key to it), `sound_delete`. Read verbs `:safe`; anything
writing the library `:restricted`, because a sound effect is a file the app will
later play unattended. `Sound.route_keys/0` is the validation source, so a
typo'd key is refused at the verb.

*Acceptance, from the archived roadmap:* a voicemail becomes a routed sound
effect end to end, from the CLI alone, with no UI involved.

**Why deferred.** The GUI got built first and covers the operator's own use, so
nothing stopped. Fully specified — no design needed, just the writing.

**What makes it expensive later.** It doesn't get expensive; it stays *absent*,
which is the actual cost. Every other authoring surface in this product is
reachable by the agent, and this one is a room the agent cannot enter — so
"turn that voicemail into my notification chime" is a thing the app can do and
the assistant cannot.

---

---

### The chime designer — the third half that never shipped

**What.** Inherited 08-02 when `SOUND_STUDIO_ROADMAP` was archived (its Phase 4,
never built). `SoundGen`'s tone-spec language as an editor: frequency, onset,
duration, amplitude, octave partial — the five fields `tone/5` already takes.
Live render on change, preview, save to `<workspace>/sounds/` plus the spec
JSON, with the shipped 16 loading as starting points so *tuning* is the common
path rather than starting from a blank canvas.

**Preview must go through WebAudio, not a `blob:` URL** — CSP declares no
`media-src`, so media falls back to `default-src 'self'`, which excludes
`blob:`. A blob preview works in dev and fails only in the packaged app.
`dtmf.js` is the precedent.

**Why deferred.** The 07-30 scoping locked three halves — editor, surface,
designer — and the first two consumed the four days. This is the third.

**What makes it expensive later.** Nothing structural: `SoundGen` already speaks
the spec language and the surface it would live in is built. But this is the
largest unbuilt thing in this file, and per the rules above it should be
**promoted back to its own roadmap** if it is genuinely wanted rather than
picked up as a leftover.

---

---

### Persisting fetched macro series — waiting on evidence, not on a design

**From the chart-build web-data roadmap's Phase 4**
(`daily-growth/archive/08-05-26-chart-build-web-data.md`). Series fetched through
the `datareq` channel are conversation-scoped: fetched, plotted, gone. Persisting
them means **a new table**, not a wider `symbol_bars` — that schema is
ticker-and-cents shaped, and pushing a CPI index or an unemployment rate through
it would feed prose-shaped keys to a regex that exists to refuse them.

**Concrete:** a table for external series (source key, series id, observation
date, value, units, frequency), written by `ChartBuilder.Fetch` on the registry
path and read back before re-fetching.

**Why deferred.** The value is unproven, and `MarketData`'s own moduledoc draws
the line this sits on: a lost bar is one tool call away, unlike a portfolio
reading — which is why one is a cache and the other a ledger. External series are
firmly in the cache half: refetchable, published by someone else, not ours to
lose.

**The trigger, written down so it can actually fire:** build this when repeated
fetches of the *same* series are observably costing something — rate limit
headroom or latency in a real session. Note the number this depends on: **BLS
keyless is 25 queries/day**; a free key takes it to 500 (`:buster_claw,
:bls_api_key`). Without the key, "we are re-fetching too much" arrives far
sooner, and the cheaper fix is the key, not the table.

**What makes it expensive later.** Nothing, structurally — it stays a clean
greenfield table. The risk is the opposite one: building it *before* the evidence
means a schema shaped by guesses about which sources matter, on a registry whose
whole design assumes free tiers and endpoints will move.

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
