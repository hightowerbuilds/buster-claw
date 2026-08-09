# 08-08-26

Built a careful way to re-home Trading. Then deleted Trading. Then deleted the
way. **~24,000 lines gone**, and the app is smaller than it has been since the
rewrite.

The through-line is not the deletion. It is that **the strongest argument for
removing something is usually what you learn while trying to keep it.** Every
fact that made the cut obvious was discovered while building the alternative to
cutting.

## The review asked for subtraction; the first answer was a mechanism

A whole-codebase critical review landed and its first finding was that the
product has no center — browser, email, calendar, trading, phone, audio,
finance, shader, journal and tutorial surfaces, each pitching something
different. Its first remedy was **subtraction**.

The first response was not subtraction. It was an extension system: a way for
Trading to leave the core download and arrive only when someone asked for it.
That is a better product than either shipping Trading or burying it, and the
roadmap for it was written honestly — its Part VII said in plain words that
**extensions reduce product surface, not code surface.**

That sentence turned out to be the whole story, written a day before it
mattered.

### What the mechanism got right

Reading the code first changed the design, which is the part worth keeping.
`BusterClaw.Trading`'s own moduledoc said the app holds no broker credentials and
speaks no MCP — so Trading was already ~85% a bundle of *data*: a URL, two tool
allowlists, three prompts, two conversation kinds. **~325 lines of data against
9,631 lines of UI.** The seam was in the code already; it did not need inventing.

The ceiling that asymmetry implied became **D1: an extension is never executable
code.** The BEAM has no code sandbox, so one loaded module holds the keychain,
the database, every token and the Tauri bridge — it makes the policy engine, the
tier system, the URL guard and the ACL lockstep test decorative in a single load.
That is a fact about the runtime, not a policy, and it is the one thing from this
work that does not expire.

The other keeper was the containment for model-authored parts: written
`enabled: false` always, install gated, an unattended run may *author* but never
*install*. The reasoning is worth restating — **a composition chaining permitted
reads into an outbound send is exfiltration built entirely from allowed steps.**
Every step authorised, the sequence not. The enable gate is where a human looks
at the sequence.

## The gate, and the door it found open

Gating Trading meant closing every door into it, and doing that surfaced one
nobody had looked at.

`Portfolio.Recorder` is supervised from boot with `autostart: true` and fires
daily after the close. All three of its duties — the balance reading, the market
sweep, the benchmark backfill — are real agent runs against Robinhood, ~28s and
cents apiece by its own moduledoc. It ran **regardless of whether Trading was
installed.**

So a fresh install with the extension off still had a daily unattended job
reaching a broker. The dock item was gone, the route showed an install card, the
split pane refused to open — and the cron kept spending money in the dark. **A
gate that stops the UI but not the scheduler is not a gate; it is a hidden link.**

That is the finding, and it only appeared because someone was trying to make
gating *work* rather than arguing about whether to gate.

## "The trading tab is still in the app"

The operator's read, and it was correct: gating had removed Trading from the
product without removing it from the codebase. Roadmap Part VII, out loud.

The call was to delete the whole thing and size the app down. Sizing it revealed
that Trading was not a feature but a **dependency chain**, and that three of the
five pieces could not be kept even if wanted:

| Piece | Why it could not stay |
|---|---|
| Portfolio (ledger, recorder) | `Trading.fetch_account_snapshot` was its **only writer** |
| MarketData (bar cache) | `Trading.fetch_market_data` / `fetch_symbol_bars` were its **only fillers** |
| Chart Build | Had **no LiveView of its own** — it borrowed TradingLive's chat, streaming and transcript |

Keeping the ledger would have left a schema nobody could ever fill. Keeping Chart
Build would have meant an AI drawing freehand SVG from pasted numbers with both
its data sources deleted.

### One thing survived the deletion by moving

`fetchable` — which data sources this app can actually pull from — lived inside
`ChartBuilder.DataReq`. It is a fact about the **source registry**, not about a
chat surface, so it moved to `Finance.Sources.fetchable_keys/0`. The distinction
it encodes is the one worth keeping: *listing is not permission.* A source becomes
fetchable by someone writing an adapter, never by being described, which is what
stops a `:blocked` entry being reachable because it happens to be in the
catalogue. `bls` lives; `market` went with the cache.

## Then the mechanism itself

With Trading gone, the extension system had zero extensions. Its tests had already
been rewritten once to stop depending on the only extension that ever existed —
which is the tell. It went the same day it was noticed: **a capability system with
no capabilities is the exact speculative breadth the review diagnosed, one layer
up.**

`Skills` returned to one directory. `Layouts.navigation_items/0` was deleted
because no dock item carries a `:surface` any more, so the filter was a fold over
nothing. `extensions/` joined `mcp/` as a retired workspace entry rather than
vanishing from the registry, so an existing folder stays declared and gets swept
when empty instead of becoming an unexplained directory.

Four mechanisms were kept **empty rather than deleted** — `ModelPolicy.@floors`,
`@claude_only`, the conversation `kind` field, `AgentToolPolicy.denied_builtins/1`
— each documenting at its definition that its only user left. The next surface
that needs a floor should declare one, not rebuild the machinery.

## Three corrections, recorded because they were load-bearing

1. **"2,838 tests, 0 failures" was not a claim I was entitled to make**, and it
   was made four times. Those runs were against a working tree carrying another
   session's uncommitted work. The committed tree had **four failures**, all
   pre-existing. Every green claim after that was verified in a throwaway
   worktree at `HEAD`, which is the only honest way to test a shared checkout.
2. **`portfolio_history` was described as reaching the broker. It does not.** The
   entire command layer contains zero `Trading.` calls; those commands read the
   *local* ledger. Acting on the wrong version would have gated three harmless
   commands and broken Chart Build, which calls one of them.
3. **Chart Build's extraction was estimated at half a day.** It was 24 call sites
   threaded through TradingLive's tab creation, layout transitions, history
   loading and streaming — Phase 4 work, not an afternoon. The estimate was
   corrected before it was planned around rather than after.

## The green test that was green for the wrong reason

`workspace_test` asserts a moved workspace gets its `buster-claw` launcher.
`WorkspaceCLI.ensure/0` writes that launcher only if it can find a CLI to point
at, and its last fallback is `./buster-claw` in the cwd — **a gitignored escript
build artifact.**

So the test passed on any machine that had run `mix escript.build` and failed on a
clean clone. It is the review's *"a clean-clone build has not been proven"* gap,
showing up as a green suite locally. Fixed by pointing the documented
`BUSTER_CLAW_CLI_PATH` seam at a real file, so the launcher path is decided by the
test rather than by whether someone happened to build an escript — then verified
by moving the escript aside and running it again.

**That is the worst way for an assertion to be environment-dependent: it is green
for whoever wrote it.**

## The day in one line

**Build the thing that would let you keep it, and you will find out whether it is
worth keeping.** The extension system was not wasted work — it produced the
account of what Trading actually was, found the unattended broker job nobody had
gated, and made the case for deletion in facts rather than in taste. Then it was
deleted too, on the same evidence.

---

# The afternoon: a 3D card for the chat

Same day, opposite direction. Having deleted ~24,000 lines, added a new visual
channel: the model emits a declarative ```scene3d block and gets an inline 3D
card in the transcript. **Scoped, built, shipped, field-tested and fixed in one
afternoon** — `SCENE3D_ROADMAP.md`, commits `da57ac8` → `a314990`.

## The question was "what are our options in Elixir", and the answer was that it is the wrong question

There is no 3D library on Hex worth building on. `:gl`/`:wx` ship with OTP but
render into a desktop window, not the webview; Scenic is 2D; Nx is tensor
compute. **That is not a mark against Elixir.** The webview draws no matter what
feeds it, and Elixir has never been on this app's drawing path — its job here is
the same as everywhere else: validate, bound, persist, hand over.

Three tempting paths were ruled out before any code, each on evidence already in
the tree rather than on taste:

- **three.js / a WebGPU mesh renderer** — the CSP forbids fetching a library, the
  house doctrine forbids adding one, *and* multi-pipeline + depth buffer is the
  exact configuration `smoke.js` records as having crashed the WKWebView GPU
  process.
- **The model authoring WGSL per card** — tempting, since the agent already writes
  shaders. But the shader channel is safe partly *because the user selects it*.
  A chat card renders the moment the model emits it. That difference does not
  survive the transfer.
- **A canvas** — already evaluated and rejected on the Chart Builder, and the
  reason generalises: model-authored executable code, not pixels.

What shipped instead: **one vocabulary, two renderers.** The model only ever emits
validated JSON. A CPU projection to SVG is the renderer; a raymarched WGSL
backend remains gated behind a banner recording that **the SDF attempt already
crashed WKWebView once**, during Humo. The honest default is that it never
happens.

## The contract is what made four agents cheaper than one

Four agents built the four stages in parallel. The thing that made that pay
rather than cost was writing `scene3d/types.ex` **first** — a compiled,
types-only module pinning every stage boundary, including winding convention,
handedness and units. All four composed on the first try; the end-to-end test
passed immediately.

Done twice, both times the same way. The pattern is now a memory.

## The screenshot was worth more than the scoping

Phase 1 shipped green at 2,356 tests and looked fine. Then one real prompt — *a
3D map of Puget Sound* — produced a card with a magenta ocean over 60% of it,
hairline coastlines, and thirteen labels piled into illegible mush.

**Given the vocabulary it was handed, the model did roughly the right thing.**
Plane for water, polylines for coasts, cylinders for towns, labels for names.
All four failures were ours:

1. Labels had no layout — uniform 5.5% sizing, no collision handling. **That was a
   deliberate Phase 1 decision, taken on reasoning that was right at 3–5 labels.
   Nobody asked what happened at thirteen.**
2. Nothing could say "this is a backdrop" — five saturated *series* colours and no
   quiet one, so the ocean got a series slot.
3. Auto-fit framed the backdrop, squeezing the subject to a smudge.
4. No filled-region primitive, so a landmass could only be a hairline.

And a fifth that is about the guide, not the renderer: **a flat map tilted in
space is worse than a flat map.** The model crossed the channel line, which is
evidence the line needed stating more sharply than "if it would read the same
flattened."

## What the agents caught that the coordinator did not

- **My concavity test would have been vacuous.** I specified "an L-shape or a
  C-shape" for the ear-clipping test. The geometry agent used a C and said why:
  an L is star-shaped about its own corner, so a triangle fan is *valid* on it.
  The mutation check would have passed against a fan.
- **My fix would have broken an existing invariant.** Fitting the camera to solids
  only meant a large backdrop could fall behind the eye and be dropped whole — a
  map of Puget Sound with no Puget Sound. Caught, and answered with a clearance
  floor rather than a near-plane clipper.
- **A stale citation in my own roadmap.** I sent an agent to read `PortfolioChart`
  as live house doctrine; it had been deleted that morning, in the work described
  above. It recovered the doctrine *and* the validated palette from git rather
  than inventing substitutes.
- **A cross-module defect, correctly refused.** The renderer found `Labels` raised
  on a non-binary label — breaking the guarantee that a malformed scene cannot
  crash the last stage before the DOM — defended its own call site, and left the
  module's own totality to its owner. That is the right split.

## The lesson that is not about 3D

**Uniform label sizing was correct at the size it was tested and wrong at the
size it shipped.** No test caught it, because every test used three labels. The
screenshot cost one prompt and taught more than the scoping document did.

The palette is now sole-sourced in `Scene3d.Svg`, recovered from a skill deleted
hours earlier. Real accessibility work went into those five hexes *and their
ordering*; the code enforcing it is gone. If a second surface ever needs series
colours, **promote it — do not copy it.** A copy is how the ordering guarantee
quietly dies.

---

# The evening: the room the agent could not enter

The Studio was the only authoring surface in this app the agent could not reach.
Every other one is agent-addressable, which is why *"turn that voicemail into my
notification chime"* was a thing the app could do and the assistant could not.
It had sat in `LEFTOVERS.md` since 08-02 with an honest note attached: it *"doesn't
get expensive; it stays absent, which is the actual cost."*

**Shipped (`e1088c2`, `35e9845`):** thirteen `sound_*` verbs — catalog 162 → 175 —
plus the word-index contract, the assembly engine, and transcript search over the
recordings the app already holds. 2,605 tests green. `STUDIO_ROADMAP.md` is the
live document.

## The design decision the CLI turns on

**It operates on files, never on what the GUI has open.** The Studio's working
state — source, trim, selection, clipboard, undo, redo — lives in `StatusLive`
assigns and is discarded on every tab switch. An agent verb that mutated it would
be editing something the operator is *holding*, with no undo they authored.

**A CLI that renders to a new file is reviewable; one that reaches into a live
editor is not.** That is not a limitation to route around later. It is the design.

## "Build a transcriber" met an honest boundary, and then went around it

The operator asked for a transcriber: find words or sounds inside audio, splice
them across sources into ramshackle sentences. Then, later: **build our own, and
lean on the BEAM.**

Open-vocabulary speech-to-text is not buildable here, and saying so plainly was
the useful part. It needs a trained acoustic model — thousands of hours of
labelled audio, GPU-weeks — or the classical HMM-GMM path, which adds a
pronunciation lexicon and a language model on top of decades of engineering.
Neither is a project. That paragraph is now in the roadmap so nobody re-derives it.

**But the feature never needed transcription.** Re-read what it actually asks:
*find the other takes of this word*, and *where does it start and stop*. Those are
two classical, training-free problems — **MFCC + subsequence DTW**, and **energy
plus zero-crossing-rate VAD**. 1970s technology, no model, no download, no
entitlement, no network, and **zero new dependencies** — which matters more here
than elsewhere, because this project's last audio-ML attempt died on the Apple
signing path.

And query-by-example is arguably the *better* instrument for this aesthetic. A
recogniser answers "what word is this"; DTW answers "what else sounds like this" —
same speaker, same room, same prosody. For assembling a sentence that hangs
together, acoustic similarity is the more useful axis, and **being
speaker-dependent is a feature** on a personal voicemail corpus.

## The staging worked: a free phase changed the decision

The phases were ordered so every risk landed last — prove the assembly engine
against a hand-authored index before any transcription exists, then search the
Twilio transcripts already on disk, and only then decide about a recogniser.

That middle phase cost nothing and **changed the answer**:

- **The corpus is thin but real.** 10 voicemails, 295 seconds, 655 tokens, 238
  distinct words, 47 with 3+ takes, 30 with 5+. A sentence is buildable today,
  mostly out of function words.
- **Twilio's transcription is bad enough to matter.** "Buster Claw" comes back as
  *"busted class"*, *"buster clark"*, *"bus o'clock"*, *"a butcher cool and"*. So
  the frequency counts are polluted by wreckage, search misses words that are
  demonstrably there, and absence of a hit is weak evidence.

That second finding **added an argument nobody had before measuring**: a better
recogniser buys *discovery*, not only timings. The decision it informed was made
on data that cost one phase of otherwise-necessary work.

## The theme: bugs that do not announce themselves

Four separate agents surfaced defects from the same family — wrong in a way that
produces no error, no crash, and no failing test:

- **`mixdown/1` rounds each placement offset independently of clip length**, so a
  join drifts a sample per cut and the total stops being the sum of its pieces.
  Found by choosing `concat/1` instead and asking why the arithmetic disagreed.
- **`fade_ms` must stay well below `pad_ms`.** A ramp longer than the padding
  reaches past it into the syllable onset and re-creates the decapitation the
  padding exists to prevent. Two settings specified independently turned out to
  be coupled.
- **Magnitude versus power** at the FFT/MFCC seam. The contract said "magnitudes"
  without saying which. Get it wrong and every log-domain feature shifts by a
  constant factor *uniformly* — nothing looks broken, both suites stay green, and
  the symptom arrives months later as "the matcher just isn't very good."
- **Cepstral mean normalisation over a template instead of a recording.** Over a
  two-word snippet the mean is substantially the speech, so normalising subtracts
  the signal along with the channel. Template and target land in different spaces
  and every distance is wrong, silently.

The last two are now written on the shared type rather than in any one module,
because they are seam properties and a seam belongs to neither side.

## What the contract-first pattern is actually buying

Four parallel agents, for the third and fourth time today, against a types-only
module written first. The pattern's value is now measurable rather than asserted:
every stage composed on the first try, and **the two most dangerous findings above
were caught *because* the seam was written down** — one agent read the contract,
noticed it under-specified its own input, and said so while the agent on the other
side was still writing that function.

Also worth recording: **three of four agents mutation-checked their own tests**
without being asked twice — reversing a winding, disabling a ZCR gate, zeroing a
silence threshold — and reported which tests went red. A test nobody has tried to
break is a test nobody knows the strength of.

## The number the plan depended on, measured

The roadmap claimed a full index build over the 295-second corpus would take
"tens of seconds" in pure Elixir. That figure came from an operation count, not
from anything that had run, and it was load-bearing: it is the whole basis for
"stay dependency-free, don't reach for Nx until past an hour of audio."

**Measured: ~40 s single-core, ~27 s across 8 cores.** The estimate holds.

**But it holds for a reason worth writing down, because two errors cancelled.**
The estimate costed a *512*-point FFT — and 25 ms at 22.05 kHz is 551 samples, so
the smallest radix-2 size that holds a frame without truncating it is **1024**.
The real work is about 2.2x what was projected. The estimate survived only
because it was pessimistic about per-operation cost by roughly the same factor.
An estimate that is right by accident is worth exactly as much as one that is
wrong, until someone measures it.

**One measured surprise for whoever writes the indexer:** throughput *halves* on
long clips. Framing is eager, so a 10-second clip leaves ~1M live floats on the
process heap and every GC walks them; the same audio in 3-second pieces runs 2.5x
faster. Chunking the consumption does not help — the list is already
materialised. Index one file per process, and prefer short files.

**And a drift bug caught in the same family as the day's others:** a 10 ms hop at
22.05 kHz is 220.5 samples. Rounding that once to 221 and stepping by it is wrong
by 0.23% forever — 0.67 s of accumulated drift across this corpus, which is more
than a word. Frame starts are recomputed from the index instead, so the error is
bounded at half a sample and never accumulates. Pinned by a test over all 29,500
frame indices.

The FFT itself is cross-checked bin-for-bin against an independent naive O(n²)
DFT, which is the strongest verification available for one. The matcher was still
being written when this was recorded.

## The day in one line, again

**Delete what you cannot justify, ship what you can field-test, and measure the
thing your plan depends on before the plan depends on it.** The morning deleted
24,000 lines on evidence gathered while trying to keep them. The afternoon shipped
a 3D card and then fixed it against a real screenshot an hour later. The evening
found the boundary of what can be built, went around it, and let a free phase
decide the expensive question.

---

# Late evening: Notes gets its name back; minutes get theirs

Two problems arrived together: how Buster Claw should be reachable through SSH,
and why the homepage's **Notes** tab was not actually a notebook. Both turned out
to be boundary problems. The safe SSH design keeps the application boundary
narrow; the Notes split gives two kinds of Markdown separate ownership.

## SSH: use the tunnel we already have before building a server

OTP's `:ssh` application can run clients, daemons, shells, command execution,
SFTP, and TCP forwarding. That capability is precisely why embedding it is not
the first release. This project pins OTP 28, where leaving daemon options out can
expose more than intended; authentication also does not create an OS sandbox —
the session still acts with the BEAM process's filesystem authority.

The roadmap therefore chooses ordinary OpenSSH local forwarding first:

```text
remote browser → ssh -L → loopback Phoenix → Buster Claw
```

Phoenix stays bound to loopback. The remote key is forwarding-only, narrowed to
one destination; no IEx, PTY, general command execution, SFTP, agent forwarding,
or public Phoenix bind. Tailscale may supply reachability, but it does not replace
that application boundary. The one product complication is the packaged app's
random Phoenix port, so Remote Access needs a stable loopback gateway before the
copied command can be dependable. The research and security gates live in
`daily-growth/roadmaps/SSH_REMOTE_ACCESS_ROADMAP.md`.

## The Notes tab had been replaced once already

Repository history supplied the cleanest map. Before `a1d0b5e`, Buster Claw had
`BusterClaw.Notes` and a split Markdown editor/preview under `notes/`.
`a1d0b5e` replaced that surface with one dated `journal/YYYY-MM-DD.md` per day,
then later language called it “the Notes record” to make the agent see exactly
one activity destination.

That last constraint was correct; the label was not. The implementation now
keeps exactly one automatic activity log while naming it **Activity**. Notes is
the operator's notebook and is never where the agent dumps routine work.

The Home rail is now:

```text
Chat | Notes | Calendar | Phone | Studio | Explore | Activity
```

Activity sits at the far right by operator decision.

## Activity moved without moving one byte of history

`BusterClaw.Journal`, `journal/`, `journal_append`, `journal_read`, the PubSub
topic, date validation, and every existing file remain in place. Only the
presentation boundary changed:

- `ActivityComponent` renders **BC Minutes** as a read-only day stream;
- the old operator composer is gone, while historical `— OPERATOR` entries stay;
- agent appends still appear live through the existing journal broadcast;
- Runs, Commands, Handled, and Open cards come from `ActivityReport.summary/1`
  and are explicitly labelled as seven-day/current context rather than part of
  the selected day's prose.

This is a migration worth repeating: **rename the responsibility, not the user's
data.**

## Notes is plain Markdown with a concurrency contract

The restored `BusterClaw.Notes` is not a blind copy of the deleted version. It
recursively discovers `.md` and `.markdown` beneath `<workspace>/notes/`, ignores
symlinks, normalizes relative paths, reuses `FileManager.within?/2`, sanitizes new
titles, refuses clobbering, rejects binary/oversized content, and never accepts an
absolute path.

The important difference is save semantics. Each open note carries a SHA-256
revision of the exact bytes read. A save writes a same-directory temporary file
and renames it over the destination only if the disk revision still matches. If
an external editor or agent changed the note first, the UI stops, keeps the
operator's draft in the textarea, leaves the newer disk file untouched, and
offers **Reload disk version** or an explicitly confirmed **Overwrite**.

That is the minimum honest contract for “Obsidian-like.” Plain files are only an
ownership story if opening the same file somewhere else does not make autosave a
data-loss mechanism.

The first UI slice now has safe note creation, streamed recursive discovery, a
real textarea, 700 ms autosave, sanitized live preview, save/conflict/error
status, and confirmed permanent deletion. Folder controls, rename/move, explicit
keyboard save, search, wikilinks, backlinks, and responsive preview switching
remain open in `HOME_ACTIVITY_NOTES_ROADMAP.md`.

## The vocabulary changed with the UI

Changing two buttons without changing the model's guide would have recreated the
bug on the next run. `Introduction`, seeded job descriptions, command catalog
copy, Explore's command tutorial, journal moduledocs, and tests now all teach the
same rule:

> Activity is the one Buster Claw activity log. Notes is the user's notebook.

The compatibility names remain `journal_*`; naming purity is not worth breaking
jobs or old prompts.

## Validation, without borrowing green from the shared checkout

The focused selection is green: **17 tests, 0 failures** across the Notes context,
generated Introduction, and the five new Home split paths. It covers the
Markdown round-trip, stale-revision conflict with both versions recoverable,
nested discovery, hostile path/symlink exclusion, live Activity refresh,
read-only controls, and far-right tab order. Documentation drift also passes.

`mix precommit` completed warnings-as-errors compilation, formatting, Credo,
cycle/file-size checks, and the Rust checks. Its full Elixir run finished at
**2,793 tests with 2 failures**, both in concurrent browser-controller work
outside this slice (`ClawConfirmTest` and `BrowserHomeControllerTest`). This same
daily summary already recorded why a shared working tree does not entitle anyone
to borrow a green claim, so the result is recorded exactly as it ran.

## The late-evening line

**A trustworthy product boundary says not only where something appears, but who
writes it, what authority reaches it, and what survives when two writers arrive
at once.** SSH stays a tunnel to one loopback service. Activity stays the one
automatic record. Notes becomes the operator's Markdown, with a conflict instead
of a silent overwrite.

---

# Night: finishing Notes, and three states that could not come from one place

Phase 2 closed out — folders, rename/move, ⌘S, the save-status lifecycle, the
narrow-window preview toggle, and unsupported files. What made it interesting was
not the feature list. It was that finishing a status chip required deciding, for
each of five words, **which layer is actually entitled to say it.**

## A status chip is a claim about authority, not a label

The roadmap asked for `Unsaved → Saving… → Saved → Conflict`. The obvious
implementation — one assign, five values — is wrong twice over, and both errors
are silent:

- **`Unsaved` cannot be the server's.** `phx-debounce="700"` means the server
  hears nothing for 700 ms after a keystroke, so a server-owned chip reads
  "Saved" over a draft that is not saved. It has to come from the client.
- **`Saving…` cannot be an assign.** The in-flight request is over before any
  assign made during it could paint. There is no moment at which a server render
  could show it truthfully.

The first attempt at fixing `Unsaved` was to let the hook write the label into
the DOM. That is the trap: LiveView diffs against the *previous rendered value*,
not against the DOM. Save-then-save leaves the server's value unchanged, no diff
is sent, and the hook's stale "Unsaved" stays on screen over a saved file. So the
hook does not write anything — it pushes `note_dirty` once per clean→dirty
transition and the server owns the label from there. `Saving…` became four lines
of CSS keyed to LiveView's own `phx-change-loading`, which *is* the in-flight
window rather than a guess at it.

| State | Authority | Why not elsewhere |
|---|---|---|
| `Unsaved` | the hook's `note_dirty` | the server hears nothing for 700 ms |
| `Saving…` | CSS on `phx-change-loading` | over before an assign could paint |
| `Saved` / `Conflict` / `Save failed` | the LiveComponent | only the write knows |

**A UI state belongs to whichever layer can observe it.** Sourcing it anywhere
else produces a display that is confident and wrong.

## Move by copy, because rename destroys

`rename/2` and `move/2` do not call `File.rename/2`. POSIX rename silently
clobbers an existing destination, and losing a note to a name collision is the
exact failure this vault was built to prevent. They copy into an
exclusively-created destination and then remove the source: the collision is
refused by the filesystem rather than by a check that can race, and a crash
between the two steps leaves a **duplicate**, which anyone can fix, instead of a
hole, which nobody can.

## The check that turns a silent overwrite into a decision

Revision-checked saves protect the moment you press save. They do nothing for a
note sitting open while another editor writes it. The hook now asks the server to
reconcile on window focus and on a 20-second tick, and the two outcomes are
deliberately different:

- **clean editor** → adopt the newer file silently; refusing to show it would be
  the surprising half;
- **draft in flight** → the same conflict banner a save would raise, now with
  **Copy my draft** so "Reload disk version" is not the only exit.

## The test that exists because a green suite lied once

`render_hook/3` never loads `assets/js`. A hook that markup names and
`hooks/index.js` does not export is a **silently dead interaction**: no error, no
warning, a passing suite, and a button that does nothing in the real app. This
repo has already shipped that failure once through a regex rename.

`BusterClawWeb.HooksRegisteredTest` now asserts every `phx-hook` in `lib/` exists
in the registry — verified by removing `NoteEditor` and watching it fail. It runs
one direction on purpose: unregistered markup is always a bug, while a registered
hook nobody uses is usually just a deleted surface (`PortfolioChart` and
`ChatWindow` are exactly that, left over from the Trading cut).

The same reasoning added an assertion for the `data-note-editor` anchor the
`Saving…` CSS selects on. Nothing else in the suite could see a rename break it.

## Split at 810 lines rather than after

`NotesComponent` reached ~810 lines, and Phase 3 (search, switcher, wikilinks,
backlinks) lands in the same file. The markup came out as two pure function
components — `Notes.Rail` and `Notes.Editor` — with state and every save decision
staying in the LiveComponent: **486 + 249 + 162**. All three are named in
`check_file_sizes.sh`, so Phase 3 has to raise those caps deliberately instead of
quietly, which is the entire point of that script.

## Validation, and a failure that was not ours

Full suite: **2,824 tests, 3 doctests, 0 failures** — including the two
browser-controller failures this morning's entry recorded, now green. 142 JS
tests. Format, Credo strict, cycles, file sizes, Rust, and docs drift all pass.

One environment fact earned its place in the roadmap: **run tests with
`MIX_TEST_PARTITION=<lane>` in this checkout.** An unpartitioned run collided with
another session on the single SQLite file and produced 19 `Exqlite.Error:
Database busy` failures at `Conversations.ensure_seeded/0` — on mount, which reads
exactly like a LiveView bug and is not one. A shared working tree does not only
threaten borrowed green claims; it manufactures convincing red ones too.

## The night line

**Ask of every piece of state: who can actually see this?** The answer decides
where it lives, and a status that comes from the wrong layer is not a cosmetic
problem — it is a confident lie about whether the user's work is safe.

---

# In parallel: a modularization pass, and what reading forced us to notice

A second thread ran through the day: a feature-by-feature read of all 304 modules
under `lib/`, a roadmap
(`daily-growth/roadmaps/MODULARIZATION_ROADMAP.md`), and then five of its phases.

**The refactoring is the smaller half of what it produced.** Almost every real
defect found today was found while reading code in order to move it — never by
the moving itself, and never by a test that was already there.

## The measurement that made the plan honest

The first useful thing was not a decomposition, it was separating two problems
the line count hides. Measuring each web file's **markup share** split the list
cleanly:

- **Long** files — `explore_panel.ex` at 82% `~H`, `phone_panels.ex` 80%,
  `home_widget.ex` 81%. Big because markup is verbose.
- **Overloaded** files — `status_live.ex` at **11%** `~H`, so 1,356 lines of
  logic. `sound_studio_component.ex` at 20%.

They need opposite treatments, and a roadmap that had not measured the ratio
would have prescribed the same cure for both. `sound_studio_component` was the
sharpest case: `components/sound_studio/` already existed, so the *markup* had
been split and the *logic* never had.

## What landed

| | Before | After |
|---|---:|---|
| `explore_panel.ex` | 1,577 | 92 + 9 modules |
| `phone_panels.ex` | 952 | deleted → 4 modules |
| `gws_panels.ex` | 513 | 122 + 5 modules |
| `status_live.ex` | 1,526 | 804 (logic 1,356 → 634) |
| four browser pages | 723 | 176 controller + 695 HEEx |
| `introduction.ex` | 758 | 146 + `introduction/*.md` |
| `skills.ex` | 533 | 344 + `skill-seeds/*.md` |

Every extraction moved by **line range, never retyped**, and every panel module
is `import`ed so call sites stayed byte-identical. The tests were not edited.

## The same bug, three times, and nobody had noticed once

A rail renders from one list; its guard checks another, hand-written. It had
already shipped once — Phone arrived as a home tab the server refused. Splitting
files surfaced two more:

- **The GWS console.** `console_tab_keys/0` was public, documented "for the
  parent's tab guard", and called by **nothing**; `SettingsLive` hand-wrote the
  same five keys. A sixth tab would have rendered a button that silently fell
  back to Accounts.
- **The corner widget.** The loosest of the three — a literal inlined in a
  template's `for`-comprehension, and a second literal in the guard *in a
  different order*. Also the worst: `select_widget_tab` has no catch-all clause,
  so a drifted key does not fall back, it **raises and takes the LiveView down**.

Three occurrences is not a coincidence, it is a shape. Any surface with a rail
should derive its guard from the rail on day one.

## Two buttons that had never worked

The in-app browser's history page gated its clear buttons on
`onsubmit="return confirm(…)"`. There is no WKUIDelegate in this shell, so
`window.confirm()` returns **false** — which cancels the submit. Both buttons
have been dead in the packaged app for months, and perfect in every dev browser.

`claw_confirm_test.exs` has guarded the rest of the app against exactly this for
months. It missed these because it greps for `data-confirm=` and theirs said
`onsubmit`. **A guard that checks one spelling is a guard against one spelling.**

## The gate shipped third, and was specified to ship first

Phase 0 — a file-size gate that fails in both directions — exists because this
repo has decomposed large files three times and been undone twice. It was
written down as the thing that goes *first*, because everything after it decays
unguarded. It shipped after Phases 1 and 2, because momentum was available and
the gate was not. That is recorded in the roadmap rather than tidied away.

It earned itself twice on day one. It tripped within minutes on `introduction.ex`
growing two lines from another session's new commands — **which was not rot**,
because that file's length tracked the command surface; the cap was wrong, not
the file, and a gate that fights legitimate work gets deleted. Later, when
Phase 7 cut that file to 146, the *under*-cap half refused to pass until the cap
was banked in the same commit.

## Green is not identical — twice

The day's most transferable lesson, and it arrived twice in different clothes.

**Phase 7.** Moving 657 lines of prose out of `introduction.ex`, the first
composition joined sections with `"\n"` — adding seven blank lines, because each
file already ended with the separator the heredoc had. It compiled. All 2,897
tests passed. Only diffing the generated document against a render from the old
code caught it.

**The widened confirm guard.** Its first version skipped heredocs so it would not
flag the six comments that *describe* this bug. But **a `~H` template is a
heredoc** — so it was blind to every LiveView and function component in the app.
It passed cleanly when fed the real historical defect.

Both were caught the same way: by breaking the thing on purpose and watching for
the failure. Every guard written today was verified by injection — a padded file,
a cut file, a restored old guard, a sixth tab, each of the three confirm
spellings. **A guard nobody has watched fail is not a guard, it is a hope.**

## A target retired rather than met

`StatusLive` was supposed to reach under 600 lines. It reached 804. What remains
is `mount`, a 170-line `render`, and 55 message-handling clauses whose largest is
28 lines — the coordinator's job, not residue. Reaching 600 needs macro plumbing
the roadmap ruled out on its first read, and the ruling still looks right. The
target was retired **in the roadmap, with the reason**, and 850 became the number
the gate holds. A goal set before the map existed is allowed to be wrong; quietly
gaming it is not.

## The day in one line, again

**Refactoring pays mostly in what it makes you read.** Three rail/guard bugs, two
dead buttons and a blind test were all sitting in files nobody had reason to open
until something needed moving — and none of them would have been found by the
tests that were already green.

---

# Late night: Notes finishes, and the roadmap closes

Phases 3, 4 and 5 landed in one pass and **Home Activity + Notes is archived**.
Notes now finds things — search, a ⌘P switcher, `[[wiki links]]`, backlinks —
and the agent can touch the notebook through five commands with an explicit
boundary. Phase 5 is closed **unbuilt**, every candidate with a reason.

## A link href had three constraints, and only one shape satisfied all of them

Rendering `[[Remote access]]` as something clickable looks like a formatting
problem. It is a security problem wearing a formatting problem's clothes:

- Note HTML is **sanitized** before it reaches the webview, because a note may be
  agent-authored or imported. So `data-note-path` is out — `data-` attributes are
  stripped. The `href` is the only thing that survives to carry the target.
- `note:Projects/Launch.md` is also out. A custom scheme is stripped too; the
  anchor renders with **no href at all**, silently.
- `/notes/Projects/Launch.md` survives sanitization — and is a **404** the moment
  the click handler doesn't run.

`#note/<encoded path>` satisfies all three: it survives, it carries the target,
and an unhandled click on a fragment does nothing at all. Missing targets get
`#note-new/<title>` and create the note. **When JavaScript fails, the fallback
should be inert rather than wrong.**

## The threshold I was about to publish was 10x off

The plan said to publish measured search thresholds, so I wrote "roughly 25 ms"
in the docstring and then measured it: **125 ms to list, 334 ms to search** a
500-note vault. Nearly all of it was one line.

`FileManager.within?/2` canonicalizes every component of every path — a
`read_link` syscall per component, ~4,000 for a 500-note walk — and it was buying
**nothing** in that walk. A planted symlink `lstat`s as `:symlink`, which matches
neither the file branch nor the directory branch, so the walk had already refused
it before `within?` was consulted. Reading bodies through `get/1` then paid for
the same check a second time.

| | before | after |
|---|---|---|
| `list/0` | 125 ms | **24 ms** |
| `search/1` | 334 ms | **87 ms** |
| `backlinks/1` | 295 ms | **52 ms** |

`within?/2` still guards every caller-supplied path, where the escape is real.
And at 87 ms there is no case for the SQLite FTS index the plan held in reserve:
it would buy tens of milliseconds for a second source of truth and a set of
invalidation rules. **A defence in the wrong place costs real time and protects
nothing — and you find out by measuring the claim you were about to publish.**

## The snapshot test asked a question I had answered too fast

`note_list`, `note_read` and `note_search` were written `:safe`, matching
`journal_read` and `document_read`. The catalog-invariants test refused them:
*commands newly promoted to :safe (runnable by any MCP/agent token)*.

It is right, and the reason is whose writing it is. The journal is the agent's
own record and the Library holds artifacts it produced; `notes/` is the
**operator's private writing** — including the titles, which is why even
`note_list` moved. Scrubbing note bodies out of audit rows and then letting any
token read them would have been incoherent.

What matters more is being precise about what the fix buys, because tiers invite
over-claiming. `:restricted` gates `:agent` and `:mcp`. It does **not** gate
`:agent_untrusted`, whose baseline stops only at `gated` commands — so an
autonomous run on untrusted content can still read the notebook. What contains
that is the other half of the design: **every outbound send is `gated`, so a read
cannot leave the machine without a human in the loop.** The reads were
deliberately not marked `gated`; that flag means outbound or irreversible, and
diluting it would weaken the check actually doing the work.

There is no `note_delete`. Deleting stays a human action behind the UI's confirm.

## A broadcast that reset the rail under the cursor

Wiring the host relay — so a terminal `note_*` command shows up in an open rail —
also wired the editor to its **own** saves. Every 700 ms autosave echoed back and
reset the file rail while the operator typed. `Phoenix.PubSub.broadcast_from/4`
with `self()` fixes it exactly: the caller already knows what it did, and every
*other* subscriber still hears it. **The publisher's own process is almost never
an audience.**

## Closing Phase 5 by writing down what would reopen it

Nine polish candidates, none built, each with a decision and a **trigger**:
`.trash/` when someone actually loses a note; attachments when someone wants an
image; a filesystem watcher when the focus/tick contract demonstrably misses an
edit; a graph when the backlink list stops answering "what links here". One —
the daily-note template — was **rejected outright rather than deferred**, because
a dated note in the notebook is the exact confusion this roadmap removed.

A deferral with a trigger is a decision. A deferral without one is a list.

## Small things that earned their keep

- An existing test compared the Explore tab's hardcoded command total against the
  live catalog and failed the moment five commands landed. That number is
  literal on purpose (to avoid a compile cycle) and the test is what keeps it
  honest — it caught the drift twice in one session, since the tier change moved
  the safe/restricted split too.
- The uncovered JS behaviours went to `LEFTOVERS.md` rather than being quietly
  dropped: debounce-after-destroy, caret survival across patches, reduced-motion.
  All three need a DOM harness this repo does not have, and **faking coverage
  would be worse than the gap because it reads as coverage.**

## The late-night line

**Measure the claim you are about to publish, and say plainly what your defence
does not cover.** The search threshold was 10x wrong until it was timed; the tier
fix was worth making and still leaves a read an untrusted run can perform. Both
are only useful written down in the form someone can act on later.

---

# Night, continued: the sentence, and the word that redirected the work

The Studio thread ran on after the recogniser landed. Its last stretch produced
the one thing this whole day was building toward, and then the most useful piece
of feedback anyone gave.

## First, the door

`sound_import` (`4f34bf7`). The app could already *assemble* ramshackle
sentences and had **no way to get a voicemail in**: recordings are mp3 under the
Library, `sound_assemble` reads WAVs from the Studio, nothing bridged them.
`import_source/1` had done the conversion for weeks; it had no verb.

Two independent guards, because one being subtly wrong is the whole risk — a
segment scan before the filesystem is touched at all, then containment on the
expanded path — with thirteen traversal shapes asserted to their exact named
errors. A 54.5-second voicemail imports end to end in **224 ms**.

`sound_probe` gained decode-on-demand at the same time, closing a gap Phase 0
had flagged honestly rather than papered over: three of its four facts need a
*parsed* clip, so it was blind on exactly the input the acceptance walk starts
from. **It paid for itself immediately — the real voicemails peak at ~0.96, near
the rail**, which means `normalize` has almost nothing to do on this corpus and
clipping on assembly is the live risk instead. Nobody would have guessed that;
the default probe could not see it.

## The threshold, measured — and a small sample that flattered

The DTW matcher's synthetic tests suggested a usable band of 0.2–0.9. Against
**real speech** — the Free Spoken Digit Dataset, 8 kHz, same band as telephony —
it runs an order of magnitude higher. 45 labelled files, **990 pairs**:
same-word/same-speaker median **4.43**, different-word **8.99**, best operating
point ≈ **6.0 at precision 0.88 / recall 0.93**. Speaker-dependence confirmed as
designed: the same word from another voice sits closer to a *different word* than
to the same speaker saying it again.

**An early 8-file sample showed clean separation with no overlap at all.** At 990
pairs, 128 of 225 negatives fall below the worst positive. **Small samples
flatter**, and the honest frame that came out of it is that this is a *shortlist
generator to audition*, not an oracle.

## Then the sentence

Ten voicemails, aligned by distributing each transcript's words across its VAD
spans. 655 words, 237 distinct, 47 with three or more takes. Enough for a real
paragraph, every word of it drawn from audio someone actually left:

> *"Good morning. I need you to send me an email tomorrow morning. Please write
> up all the Spanish words that you want. Thank you."*

**24 words, spliced out of six different voicemails. A sentence nobody ever
said.** It rendered.

And then the honest part: **it worked from a throwaway script.** The agent had
`sound_import`, `sound_index_search` and `sound_assemble` and no way to *fill*
the index between them. `Cutup.Align` and `sound_align` (`12f15ae`) closed
that — plus a fourth index origin, `:aligned`, because labelling a proportional
guess `:recognizer` would tell a future reader that a recogniser ran.

## "Garbled" — one word, and it redirected everything

Asked how it sounded, the operator said: **garbled**.

That single word was worth more than any measurement taken all day, because it
ruled out the tempting next step. The plan had been a learning session — rate
takes, fit weights, pick better ones. **But selection ranks what exists. If every
take of a word has the wrong boundaries, choosing between them cannot help.**
Garbled meant the takes themselves were wrong, so the fix was `Align`, not
labels.

And both defects were ones `Align`'s own moduledoc had already predicted, in
order:

1. **Boundaries landed mid-vowel** — words laid out proportionally, clamped only
   at span edges, so an interior boundary fell wherever the arithmetic put it.
2. **Function words were over-allotted** — `to`, `the`, `of` run under 80 ms in
   real speech but got a full syllable's share, so they ate their neighbours'
   onsets. **And this corpus is mostly function words**, so the algorithm was
   worst at exactly the words a cut-up splices most.

Fixed (`c9fd9b3`): snap each boundary to the nearest strictly-quieter frame
within 40 ms, and scale function words by 0.55 over a curated stopword set.
Rebuilt in four variants — neither, snap, reduce, both — and the operator judged
**both** better. **The default is backed by ear, which is the only validation
that means anything for a change to how something sounds.**

## What the day taught, beyond the audio

**A written-down prediction is worth more than a written-down design.** `Align`
shipped with a moduledoc naming its two likely failure modes. When the operator
said "garbled," the diagnosis took minutes instead of an afternoon, because the
module had already told us where to look. Every agent today was asked what it
expected to break first; that habit paid off here directly.

**Ask the question whose answer changes what you do next.** "Garbled" versus
"crazy-good" pointed at two completely different next steps — alignment work
versus leaning into the aesthetic. Four words of operator feedback resolved it.
No amount of internal reasoning would have.

**And measure the thing your plan rests on.** Snapping — one of the two fixes
just shipped — moved total duration by **10 ms across 24 words**. It is close to
inert, exactly as its own strictly-quieter rule predicts. That is recorded as
open rather than claimed as a win, because the improvement the operator heard may
have come almost entirely from the other fix.

---

# Small hours: finishing the map

The last stretch was five agents against the remaining Studio phases, split by
file so none collided. Four landed; the fifth — the two verbs that finally make
the recogniser reachable — was still being written when this was recorded, and is
blocked on a `credo --strict` arity finding in its own in-flight code.

## The acceptance criterion, unmet since 08-02, is met

*"A voicemail becomes a routed sound effect end to end, from the CLI alone, with
no UI involved."* There is now a test that walks exactly that, every step through
`Commands.call/3` **by name**: probe → import → align → index search → assemble →
trim → normalize → **apply**, then asserts the library file is on disk and the
route resolves to it.

A second test proves the gate is real rather than declared: running as
`:agent_untrusted`, `sound_trim` succeeds and `sound_apply` returns
`{:error, :requires_confirmation}` with nothing written and nothing routed.
Routing is the one gated verb in the surface, because **it is the difference
between the agent making a sound and the agent changing what your computer does
at 3am.**

The catalog went **13 → 24 `sound_*` verbs** across the day.

## Everything expensive got measured, and one thing got measured past its brief

The feature cache is the layer that makes the recogniser usable: **cold 108.8 s,
warm ~155 ms — 700×**. Compression was measured and rejected (95.6% of raw, not
worth the inflate on every read). Float64 over float32 deliberately, because the
threshold study is measured to two decimals on distances of 3–13 and does not
want a silent 1e-7 wobble underneath it.

**The invalidation went past what was asked, for a specific reason.** The brief
said size and mtime. The agent added a SHA-256 digest because **mtime is
one-second granular** — a source re-saved at the same byte length within the same
second is byte-different and stat-identical, which is a silent stale hit. There
is a test that forces exactly that case, and it fails without the digest. Thirty
milliseconds of hashing guarding 109 seconds of recomputation.

## The fifth seam defect of the day

`Signal.default_fft_size/0` is **1024**. `Mfcc.new/1`'s default is **512**. Wired
naively, the filterbank has 257 bins, the spectra have 513, and the first call
raises.

The agent's own framing is the lesson: *"Neither module is wrong alone — this
only exists once something connects them, which is exactly the layer that did not
exist."* That is the fifth defect today living in a seam rather than in a module,
after the magnitude/power convention, CMN scope, the mixdown sample drift, and
the fade/pad coupling.

## Two costs that would have been counted twice

The lattice splits `c0` out of its spectral join cost and measures it separately
as the level term — **because `c0` *is* frame log-energy**, so leaving it in
would measure the same level jump twice and quietly double its weight. And the
natural-run rule (two candidates adjacent in one recording join for free) is
applied **after** normalisation, so a free join still contributes its honest raw
distance to the population the scale is computed from.

Both are the kind of thing that produces a system which almost works.

## What was refused, and why that was right

The skill agent declined to document `sound_align`'s two ear-tuned toggles,
because they were accepted by the handler but **not declared in the catalog** —
and the catalog is the only thing the model sees. Its reasoning: documenting an
undeclared argument in a file the model reads as gospel is the same class of
error as inventing a verb.

It was right, and it was my bug. The toggles are the fixes that took the first
paragraph from *garbled* to audibly better, so they are exactly the knobs someone
would reach for. Now declared.

That skill also ships with a **lockstep test**: every `sound_*` token in its body
must be a live catalog name. A documentation file has exactly one failure mode —
drifting from the thing it documents — and that test fails loudly the moment a
verb is renamed or the playbook invents one.

## What agents cannot finish

Part V needs the operator to **record a donor passage** — an hour of read speech
with known text would dwarf the 295-second corpus and removes `Align`'s two worst
failure modes at the source rather than compensating for them. Part VI's
listening session wants a **LiveView surface** around the existing
`StudioAudition` hook, because judging audio is a listening activity and a CLI
verb can only write files and ask someone to go find them.

Neither is a gap in the plan. They are the parts a person has to do.
