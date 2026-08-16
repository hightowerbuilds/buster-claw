# Leftovers — the agent core

**Split out of `LEFTOVERS.md` 2026-08-09.** The tail work in the machinery every
surface sits on: the runner, the command surface, skills, and the sound
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

### ~~Scene3D — the guide-as-skill move, and the unbuilt polish~~ — DELETED 08-16

*Inherited 08-08 from `archive/08-08-26-scene3d-roadmap.md`; closed by deletion.*

**Two items lived here** — relocating `Scene3d.guide/0` into a `scene-designer`
reference skill so the homepage stopped paying for it every turn, and four
unbuilt polish items (wider faceted shading, contact shadow, depth cue, orbit
drag). **Both are moot: the feature was deleted whole on 08-16** — 3,370 source
lines, 3,765 test lines, and the `scene3d` block out of the homepage chat.

**Neither was ever blocked on difficulty.** Both were deferred *waiting on
evidence* — "nobody has yet wanted them prettier" — and in the eight days since,
none arrived. That absence is what the deletion acted on. The guide's compounding
cost went with it: the homepage system prompt is one guide again, not two.

**Do not rebuild speculatively.** If a 3D card is ever wanted back, the argued
design is in `archive/08-08-26-scene3d-roadmap.md` and the code is in git history
at `caa78c2`.

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

### From the 08-13 code review — the agent core's ledger

*Filed from [`CODE_REVIEW_08-13-26`](../../archive/CODE_REVIEW_08-13-26.html) §5, the
whole-codebase review. Its top findings for this section were fixed the same
day (`20a36a9`); these are the ones that remain, each verified against the
file, not inferred.*

- **Land the `Agent.Chat` state machine as a doc.** The Phase 5 prerequisite —
  "write it down before any split" — is now *written*: the review's §5 carries
  the full state × event × guard × effect table, verified against the file
  (~14 transitions; the real machine is `status × transport-presence`, because
  on a persistent transport `:idle` splits in two). It needs a home in or
  beside `chat.ex`. Only then come the ruled seams — event projection (~280
  nearly-pure lines) and queue/ledger choreography (~280) — landing the
  GenServer at ~900 and honoring the cut this file's first item is owed.
- **Consume the duplex steer replay.** `20a36a9` stopped the false `:steered`
  claim by reporting `:unconfirmed` on a bare pipe write. The upgrade path —
  consume the `--replay-user-messages` echo
  (`ChatMessageEncoder.operator_replay?/1` is the ready-made, currently unused
  discriminator) and promote the ledger row uncertain → delivered — is real
  wiring, including a delivery chip a LiveView stream will not re-render on
  its own.
- **The recovered queue never self-dispatches** (`chat.ex:426–447` vs `:472`):
  after a crash, the next new submit starts ahead of items the operator was
  shown as queued. Idle-with-a-non-empty-queue is unreachable any other way,
  so the only case is exactly the case that matters.
- **`capabilities/1`'s no-process fallback hardcodes one-shot Claude**
  (`chat.ex:193`) against its own doc's promise of "the backend the next turn
  would use" — the send button can be mislabeled before a duplex or codex
  conversation's first message.
- **`audit_run` and `audit_delivery` disagree on harness attribution**
  (`chat.ex:1279` vs `:1011`): a confined conversation's run audit charges the
  stored agent while claude actually ran the turn — the exact attribution the
  field's comment says it exists for.
- **Server-connection `refs` maps leak across reconnects**
  (`codex_app_server.ex:385`, `open_code_server.ex:489`): `Chat` drops handles
  on interrupt/timeout/transport-drop without unregistering, so stale entries
  accumulate and late events for dropped turns reach the pid only to die in
  the catch-all.
- **`ModelPolicy`'s floors are vacuously green** (`model_policy.ex:105, 125`):
  `@floors` and `@claude_only` both emptied with the trading deletion — the
  doc-drift comb's "collection empties, guard goes vacuous" cluster,
  pre-acknowledged in comments. Watch item until a money surface returns.
- **Split `commands/sound.ex`** — 2,514 lines, the largest file in the repo,
  ungoverned — into `Sound.Library` (~630) / `Sound.Corpus` (~950) /
  `Sound.Render` (~800) behind a delegating facade, with `under_library/1`
  keeping exactly one home. The 2,524-line `sound_test.exs` is the proof
  harness. Minimum even unscheduled: FROZEN 2514 in the size gate. The repo
  already conceded the point — `SoundCapture` was split out 08-09 explicitly
  to protect this file, which then kept growing.
- Small, dated: `split_lines/1` triplicated (`stream_event.ex:97` + both
  servers); `send(parent, :noop)` scaffolding at `open_code_server.ex:298`;
  claude `normalize/1` keeps only the first `tool_use` block and drops sibling
  text (`stream_event.ex:437`); `cli.ex` usage drift (`dispatch reply`,
  `--body`, `--account` implemented but undocumented; unreachable `--help`
  route clause at `:44`).

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
