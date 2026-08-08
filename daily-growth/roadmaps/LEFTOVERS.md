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

<!-- DONE 07-22: "Walk the new automation primitives in the real app" — walked
against the PACKAGED app (stronger than the dev-shell ask). Agent side driven
via /api/run: wait (match + real 10s timeout), click text (matched_by:text +
navigation), extract selector+attr (30 matches), flow failing at the reported
step WITH screenshot on disk (twice), check_save→run→`## Runs` line, plus
open_tab (session:ephemeral honored), find_elements, read, screenshot (valid
PNG). Operator confirmed GUI side: co-presence badge flashed on every call,
7-tab eviction, sidebar bumper/⌘B, zoom, ⌘F count, popup-as-tab, download +
reveal, menu accelerators, and the double-launch single-instance check. -->

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

### Mirror input forwarding (click/type into the Agent Mode mirror)

**What.** The Phase 7 mirror renders a run's viewport as MJPEG but is
view-only. Forwarding input means mapping client coords → viewport coords via
the screencast metadata scale, then `Input.dispatchMouseEvent` /
`dispatchKeyEvent` over the CDP pipe we already own.

**Why deferred.** It is blocked on a real prerequisite, not on effort: the run
must carry an `awaiting_reason` so the mirror knows *when* human input is
legitimate. Taking the wheel at an arbitrary moment races the agent's own
actions. Inherited here 07-28 when BROWSER_ENGINE_ROADMAP closed, alongside its
four unfinished field-test repairs — which moved on to
`BROWSER_CLOSEOUT_ROADMAP.md` 08-02, leaving this one behind precisely because
it is the only one of the five that needs a *prerequisite* rather than a
decision. Everything in that roadmap's *Deferred* list was ruled out on the
merits; these five were not.

**What makes it expensive later.** Nothing structural — the transport and the
scale metadata already exist. It gets expensive only if `awaiting_reason` is
designed without this consumer in mind.

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

### Send `nosniff` on the four pipeline-less media routes — **HIGH**

**What.** Inherited 07-30 when `MUSIC_ROADMAP` was archived (its Part VII, the
only item that roadmap left open). `X-Content-Type-Options` appears **nowhere**
in the codebase. `RangeResponse` now sends it, which covers music and voicemail;
these four still serve workspace bytes without it, and — being intentionally
pipeline-less — without `put_secure_browser_headers` or **any CSP header**
either:

- `WorkspaceFileController` (`/ws/file`) — **start here; it renders workspace
  `.html` as-is**
- `NotifySoundController` (`/notify/sound`, `/notify/sound/:name`)
- `AppearanceController` (`/appearance/*` — user-uploaded images)
- `ShaderController` (`/shaders/:name` — user-authored WGSL)

**Why deferred.** It was found during the music build and belongs to the
security surface, not to a music roadmap. Nobody has owned it since.

**What makes it expensive later.** What these serve is a *workspace file* —
bytes a user uploaded or an agent wrote. Without `nosniff` a browser may sniff a
file named `.mp3` whose content is HTML, render it, and run its inline script
from our own origin, with no CSP on that response to stop it. That is the
`window.__TAURI__` → `terminal_*` → shell chain `ContentSecurityPolicy`'s
moduledoc exists to break, reached by a route that never gets the header. One
header each.

---

### Two Trading browser tests the LiveView suite cannot stand in for

**What.** Inherited 08-03 from `TRADING_TAB_CRITICAL_REVIEW_ROADMAP` (archived);
its Stage 6 closed every other test but these. In a real browser: (1) changing
account and range **redraws the actual SVG path**, and (2) the tooltip,
accessibility label, headline figure and plotted line **all agree**.

**Why deferred.** The LiveView tests around them are strong — in-flight account
and symbol switches, fail-closed last-four collisions, unconfirmed orders never
reaching a write tool, confirmed payloads that cannot be replayed. What none of
them can see is the rendered DOM, because `render_hook` never touches JS.

**What makes it expensive later.** These two guard the exact defect the review
opened on: a chart that keeps displaying the previous account's data. That class
of bug is invisible to every test currently in the suite, and it is a *financial*
display error — the one kind this codebase has consistently refused to ship.
Pair with the Chart Build walk below; both need a browser and nothing else.

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


## Rules of engagement

- An item leaves this file by being **done** or by being **promoted** to a real
  roadmap because it turned out to need a design. It does not leave by rotting.
- If an item has sat here through two dev summaries without moving, that is a
  signal it is either not actually worth doing (delete it, and say so) or it is
  more important than "leftover" implies (promote it).
