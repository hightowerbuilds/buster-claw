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

### Renaming a note orphans every `[[wiki link]]` pointing at it

**What.** `Notes.rename/2` and `move/2` change a note's path and touch nothing
else. Inbound wiki links keep the old target, so after a rename:

```text
resolve_link("Old name")   -> nil
backlinks("New name.md")   -> []
```

The sharp edge is not the dangling link, it is that an orphaned link is
**indistinguishable from one that never resolved** — so it renders as a *missing*
link, and clicking it creates a new empty `Old name.md`. You end up with a ghost
of the note you just renamed, alongside the renamed one.

**Why deferred.** The Home Activity + Notes plan
(`daily-growth/archive/08-08-26-home-activity-notes.md`) explicitly said a rename
may update links "only through an explicit preview/confirmation", because
rewriting every note on a filename change is too large a mutation to do quietly.
Building that confirmation is a feature with its own UI — what links here, what
would change, approve — not a patch, and nothing has demanded it yet. Doing the
rewrite *without* the confirmation is the one option the plan ruled out. The gap
was closed out unrecorded and is written down here late, which is the part that
should not repeat.

**What makes it expensive later.** Not the rename — that stays safe and
reversible. The cost compounds in the vault: every ghost note created by clicking
a stale link is a real file the operator now has to notice and clean up, and it
carries the *old* name, so it looks like the note they were looking for. The
longer wiki links are used before this is addressed, the more stale targets exist
to click.

**Cheapest partial fix**, if the full flow is not wanted: stop offering to create
a ghost for a target that was *renamed* rather than never written. That needs a
rename breadcrumb the vault does not currently keep, so it is more design than it
first appears — which is why it is here rather than done.

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

### The Manual has no test, and had the worst drift of any surface

*Inherited 08-09 from `archive/DOC_DRIFT_ROADMAP.md`.*

**What.** Assert that `user-guide/introduction.md` names the same dock surfaces
`BusterClawWeb.Layouts` declares in `@navigation_items`, and no others. Same
idiom as the `console_tab_keys` rail guard in `settings_live_test.exs`.

**Why deferred.** The drift itself is fixed; this is the guard that keeps it
fixed, and it needs ten minutes rather than a design.

**What makes it expensive later.** `user-guide/` is rendered at `/manual` and is
the first thing a new operator reads, yet **nothing in the suite reads it** —
which is exactly why it accumulated the worst drift found in the 08-09 comb: a
dock of nine when the code declares five, four retired features listed under an
"Advanced" section that does not exist, and two folder names the app relocates
on boot. Every one of those was months old and invisible to a green suite.

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

### `extract` returns empty on anchors and cart rows

*Field-found 08-08 (browser-control book errand, Finding 2).*

**What.** `extract` with `div[data-component-type="s-search-result"] h2` returned
four clean titles; the same selector with ` a` appended returned **zero**. On the
Amazon cart page `span.sc-product-title` worked, but
`span.sc-item-price-block span.a-price span.a-offscreen` and
`div[data-name="Active Items"] .sc-list-item` both came back empty.

**Why deferred.** Cause not established — could be Amazon markup drift, or
`extract` failing to resolve elements whose text lives in descendants. Telling
those apart needs a fixture page, not a guess.

**What makes it expensive later.** It silently degrades the thing Agent Mode
exists to protect. On the 08-08 run the per-line cart price could not be read
back, so the frozen ledger's $49.29 came from the **product buy box, not the
cart line**. Those normally agree and diverge on a format or seller swap — which
is exactly the case the frozen cart is supposed to catch. An `extract` that
returns empty rather than erroring means the fallback is silent.

### Stopped Agent Mode runs accumulate with no reaping

*Field-found 08-08 (browser-control book errand, Finding 3).*

**What.** `agent_run_status` with no id listed `scope_6H` in mode `stopped` from
a prior errand. Runs stay registered after they terminate by design — the
trajectory is the receipt — but nothing ever reaps them. Either age them out or
expose a prune command.

**Why deferred.** It needs a policy call (how old is too old, and does anything
depend on an old trajectory staying readable) rather than a patch.

**What makes it expensive later.** A stale registered run is not inert: it was
the **trigger** for the whole 08-08 live-tab fault. BrowseLive picked it up on
mount, which meant the browser surface was never rendered, which meant the JS
hook never called `browser_open`, which meant every live-tab command failed with
"no active browser tab". `91b6c24` and `7f4071b` fixed that chain, so a stale run
no longer breaks anything — but it accumulated quietly for a whole session
before it did, and the next thing that reads "the newest run" inherits the same
surprise.

---


### The live-CLI walk for chat attachments — the one claim the suite cannot make

*Inherited 08-08 when `CHAT_ATTACHMENTS_ROADMAP` was archived.*

**What.** Drag an image into the homepage chat, send it, and ask the model
something only the picture answers — on **each** backend. Then repeat it in a
**packaged** build.

**Why deferred.** Every mechanism was measured in Phase 0 against a real `claude`,
`codex --help` and `opencode --help`, and 3,268 tests assert what leaves the BEAM
— the argv handed to the spawner, and for the duplex path the actual JSONL bytes
down a real pipe with the base64 decoded and compared to the original file. But
**no test runs a CLI**. The chain from argv to a model that has genuinely seen
the image is asserted at both ends and never walked in the middle.

**What makes it expensive later.** Two specific gaps, both invisible to the suite:

- **The packaged build is the only place the drop path can be proven.** WKWebView
  does not hand file contents to the DOM, so a browser passing proves nothing —
  that is exactly the trap that produced the original bug. This belongs with
  `LAUNCH_ROADMAP` **G-40**, which already collects the needs-a-real-build items.
- **Codex's sandbox reading the staging directory is unverified.** It sits
  outside the working root; `-s workspace-write` is documented as a *write*
  restriction so a read is expected to work — expected, not measured. If it
  cannot, Codex attachments fail silently and only on a real run.

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

### The Explore tab's tail — two errands and five tiles nobody said yes to

*Inherited 08-08 when `EXPLORE_TAB_ROADMAP` was archived
(`daily-growth/archive/08-08-26-explore-tab.md`). Its roster is complete
— six tutorials, no stubs, every demo carrying the four-field contract — so what
is left is editorial and structural, not content.*

**Two things did not come here, and knowing where they went saves a search:**
the packaged-build read-through became one bullet in **`LAUNCH_ROADMAP.md`
G-40** (it needs a build and a person, which is that gate's whole definition),
and **Phase 1's markdown content pipeline was decided against** rather than
deferred — see the archived roadmap's closing note. Do not re-propose either as
a leftover.

**What.** Three items, none needing a design:

- **Verify busterclaw.lol and Notes That Float, then fix the copy that describes
  them.** Both site tabs were rewritten 08-04 for accuracy — vending is
  described as planned, NTF as a creative-writing and journaling app with a
  spatial 3D view. Neither was re-checked against the live sites afterwards, and
  they are the two tabs in Explore whose subject **lives outside this repo**,
  so no test can hold them. Visit both, confirm the copy, and correct it.
- **Decide where NTF belongs in the rail.** It currently sits third, between
  BusterClaw.lol and the six feature tutorials, which reads as though a sibling
  product is a Buster Claw feature. The 08-04 audit floated grouping it (and
  possibly the site tab) under an **Elsewhere** or **About** heading. One
  registry edit; `Registry.@tabs` and `@tiles` both derive from one list, so the
  rail and the launcher grid move together.
- **Cross-link the three teaching surfaces.** Get Started and the Manual should
  mention Explore where it helps, and the Explore Intro should link the Manual
  for reference depth. Today Explore links *out* to app surfaces constantly
  (`/appearance`, `/phone`, `/browse`, `/security`, `/settings`) and to the
  Manual **not once**, which is the wrong asymmetry for the one surface whose
  job is to teach.

**And five candidate tiles that were proposed and never accepted:** *The work
queue & on-duty*, *Chat & the agent*, *Music & Sound Studio*, *Security feed /
Sentinel*, *The terminal*. Filed here rather than dropped because the strongest
of them is a real gap — **the queue is described in the README as "the whole
design" and has no tutorial**, while shaders (ambiance) has one. Each needs an
operator yes, and the roadmap's own standing rule is the reason none was taken
unilaterally: *eight thin tutorials are worth less than five good ones.*

**Why deferred.** The roster work was the part that blocked a first-time user
understanding the app; none of this does. The two site tabs are already accurate
as far as anyone checked, the cross-link is a convenience, and a sixth tutorial
nobody asked for is exactly the thin-tutorial failure the roadmap warned about.

**What makes it expensive later.** The site copy is the one content in this app
that can go stale **without any commit touching it** — a change on
busterclaw.lol or notesthatfloat.com falsifies a page here silently, and this
repo's whole drift defence is derive-from-source plus contract tests, neither of
which can reach another origin. That is also the argument for keeping these two
tabs short: every sentence about an external site is a maintenance liability with
no automated owner. If Explore ever grows a third outbound tab, that is the
moment to reconsider the pattern rather than the moment to write more prose.

---

### From `daily-growth/archive/08-09-26-notes-editor.md`, archived 08-09

The Notes editor shipped as a live-preview word processor and was walked and
accepted. Three items left over, none needing a design.

**What.**

- **Enter continues a list, and Tab nests one.** Pressing Return at the end of
  `- buy milk` should open `- `, on an empty `- ` should end the list, and Tab
  should indent a list line. A working, tested implementation of exactly this
  existed (`assets/js/lib/note_structure.js`, 43 tests) and was **deleted on
  purpose** — recovering it from git is a five-minute job, and re-deriving it
  from scratch would be silly.
- **External links do nothing when clicked.** `[label](url)` renders styled and
  carries its target as `data-target`, but only `[[wiki links]]` navigate.
- **Custom undo granularity.** ⌘Z is the browser's and works. A tested history
  ring with word-level coalescing (`note_history.js`, 37 tests) also exists in
  git history if per-word steps ever prove too coarse or too fine.

**Why deferred.** All three were casualties of the simplification that finally
made the editor usable, not of anyone running out of time. Two earlier designs
failed because they took control away from the browser; the third works because
it takes almost none. Every item above is an *intercept* — a place where the
editor overrides the browser again — so each must go back **one at a time, each
walked in the real app before the next**. Landing them as a batch is precisely
how the base was lost twice, and a green suite did not catch it either time.

**What makes it expensive later.** Only one of them, and it is the link click:
a URL survives tokenizing as inert data, so wiring the click **without a scheme
allowlist turns `[click](javascript:alert(1))` into working script** on a surface
that renders agent-authored and pasted content. That exact string is already in
the editor's XSS fixtures, which is the cheap half of the guard; the expensive
half is remembering why it is there. Wire the check in the same commit as the
click handler, never after.

The other two cost nothing by waiting — they are conveniences on a surface that
works without them, and the git objects do not rot.

---

## Rules of engagement

- An item leaves this file by being **done** or by being **promoted** to a real
  roadmap because it turned out to need a design. It does not leave by rotting.
- If an item has sat here through two dev summaries without moving, that is a
  signal it is either not actually worth doing (delete it, and say so) or it is
  more important than "leftover" implies (promote it).
