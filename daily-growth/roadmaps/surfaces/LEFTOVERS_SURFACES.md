# Leftovers — surfaces

**Split out of `LEFTOVERS.md` 2026-08-09.** The tail work attached to a screen
the operator can point at: Home's sub-tabs and the full-screen surfaces.

**Everything here blocks nothing** and is **concrete**.

Small, real, and deferred on purpose. Nothing here is blocking a ship; everything
here is the kind of item that quietly never gets done because it never becomes
urgent — until it does, at which point it is expensive.

Covers [Supermap](../SUPERMAP.md) Parts II and III.

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

---

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

---


---

### From the 08-13 code review — surfaces

*Filed from [`CODE_REVIEW_08-13-26`](../CODE_REVIEW_08-13-26.html) §§4 and 6.
Both frozen modularization phases were re-verified against current code and
still fit — with corrections that change how they should be executed.*

- **Phase 3 (Sound Studio catalog → core) fits, with one real correction:**
  four catalog item builders bake router `~p` URLs
  (`sound_studio_component.ex:208, 242, 258, 273`), so the core module takes
  `{id, kind, name, label, sub, path}` — exactly what the missing `sound_*`
  CLI needs — and the web side decorates `url` in the already-existing
  `BusterClawWeb.SoundStudio.Catalog`. The plan's import-pipeline half is now
  marginal (~60 lines); the better second cut is the render/trim/rename block
  (~170 socket-free `{:ok,_}/{:error,_}` lines). Callers to update:
  `StatusLive` reaches `collapsed_groups/0`/`put_collapsed/1` directly
  (`status_live.ex:135, 318`).
- **Phase 4 (Settings) fits, and its open question resolves YES:** every
  settings sub-tab is its own route (`settings_tabs.ex:10–18`), so real
  live_components are legitimate — forward `handle_info` via `send_update`,
  the pattern `status/studio.ex` already uses. The numbers moved in the
  split's favor: GWS is now 12 of 20 clauses. Models first (~300 lines, no
  `handle_info`, maps 1:1 onto `ModelPolicy`).
- **Calendar (866, FROZEN) now has its map and two byte-identical seams:**
  view components + the modal form → `components/calendar/views.ex` (~240
  lines; the `target` attr is already threaded), and the pure date/grid math →
  core `Calendar.Grid` (~190 lines, zero assigns). Honors the home-panel
  constraint — function components and pure modules only. Nits: the
  Sunday-week-start expression ×3 (`:689, :695, :744`); `day_view`'s required
  `:today` attr is unused (`:624`).
- **Phase 8's premise has only strengthened:** the chip idiom is now at 14
  occurrences (recorded 4× on 08-08), `button_outline` ×4 verbatim `defp`
  copies plus an inline variant, display headings 8×/10×. Still correctly
  sequenced *after* the extractions — it changes call sites.
- **The cut-up pipeline is healthy — leave it — but carries four repairs:**
  `safe_source/1` duplicated *verbatim* between the two stores
  (`index.ex:428` ≡ `features.ex:720` — the one duplicate with security
  weight); `gaps.ex:205` asserts the exact defect `index.ex:599` fixed
  (damaged origin degrades to `:aligned`, not `:manual`); the 25/10 ms frame
  clock is "pinned in Types" by prose only — three independent attribute
  copies, one drift away from silently mis-timing every index; transcript and
  index vocabularies use different apostrophe normal forms and nothing says
  so.
- `sound_studio_component.ex:297–303` — an empty "Import" section banner
  labels code that moved to `:577–607`; and `resolve_source/1` triggers a full
  4-directory + DB catalog rescan per clip, so an n-clip render does n scans —
  pass the assigned `groups` down.
- **`appearance.ex:379` vs `appearance_live.ex:955`** — with an image+shader
  background selected, `option_key` matches no minted catalog key, so no tile
  may highlight. Verify in the running app before treating as a bug.
- **`shader_preview.js:86/115`** calls `getBoundingClientRect` every frame at
  60fps — the exact forced layout its sibling `smoke_background.js:70–72`
  documents avoiding — and skips the hidden-tab rAF stop. The two hooks also
  duplicate the boot sequence nearly line-for-line (~60 lines a shared
  `bootSmoke(el, opts)` would cut). The file is in flight under
  `IMAGE_SHADER_ROADMAP`; fix it there.
- Cosmetic, dated: "an mix" ×3 in `studio_mix.ex` (`:118, :285, :424`); the
  Google bundled-connect handler pair duplicated between
  `settings_live.ex:109–147` and `setup_live.ex:155–225` — two surfaces that
  must move in lockstep today.

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
