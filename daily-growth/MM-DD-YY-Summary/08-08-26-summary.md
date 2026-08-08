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
