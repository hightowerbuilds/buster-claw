# 08-16-26 — Six estimates outlived the things they described

Three arcs. Two in the Studio: the Voice tab became the **Voice Library** —
browse your words, hear them, build a sentence, hear that, record what was
missing — and then the **Mix** half got an effect chain, clip removal, and the
fix for a crash the operator had reported twice.

**The third was a deletion, and it did not come from the code.** Two product
reviews arrived in the evening, and one of them ended Scene3D: −7,264 lines, the
largest single cut since the trading stack.

It started as two doc fixes.

The through-line arrived six times before it was exhausted, and it is not
yesterday's. Yesterday was *guards that guarded nothing*. Today was **written
claims that were true when written and had quietly stopped being true**, every
one of them understating what the code could already do:

| The claim | Written | Actually |
|---|---|---|
| "The Dialyzer gate is red — 56 findings" | 08-13 | Green that day, red again with **3** |
| "Studio → Voice: **PLACEHOLDER**" | 08-09 | Built 08-14, two panes shipping |
| Pane 2 "needs a route serving a take's audio, which is its own surface" | 08-09 | The route had existed since the Studio shipped |
| "A name collision is refused, never auto-suffixed" | **this morning** | Made the recorder able to capture each word exactly once |
| "A hook's `pushEvent` resolves against the `phx-target` on the hook's own element" | before today | **It does not.** Every click on a clip crashed the LiveView |
| "Every write goes through here" — `SoundStudio.clamp16/1` | long before today | True until **today**, when two more write paths were built beside it |

The fourth is the one worth sitting with. **I wrote it, defended it in a comment,
and it was load-bearingly wrong within nine hours** — not because the rule was
bad, but because it was applied to a case it was never about.

**The fifth cost the most and is the sharpest instance of the pattern**, because
the wrong comment did not merely fail to describe the code — it *shaped the test
that was written to check it*, and that test passed while the app crashed on
every click. It gets its own section at the bottom.

**The sixth is the one to end on**, because it is the only one nobody wrote
wrongly. `SoundStudio.clamp16/1` said "every write goes through here" and it was
true for months — until this morning, when the recorder and the effect chain each
grew their own saturation. **A single-door claim is not falsified by editing it;
it is falsified by building a second door**, which is precisely the thing a
comment cannot notice.

Not one of the six was found by reading. The gate was run, the file was opened,
the route was questioned, the operator asked for something the code refused, the
fifth needed a real browser, and the sixth needed a scan for duplicate helpers.

| Shipped | |
|---|---|
| **Voice banks** — one voice, one microphone, and banks never merge | `Cutup.Bank` |
| **The in-app recorder** — AudioWorklet capture, AGC off, metering before you arm | `voice_recorder.js`, `Capture.Take` |
| **Audition** — hear any take, or a built sentence | `voice_audition.js` |
| **Sentence build-and-play**, through the same code an agent uses | `Cutup.Sentence` |
| **Multiple takes per word**, and curating them | `Cutup.Takes` |
| **Chips are doors** — a word leads to its takes, a gap leads to the mic | `Studio.Sentence` |
| One tab with a sidebar, after briefly being two tabs | `Studio.VoiceLibrary` |
| `commands/sound.ex` 2,514 → 2,464 | the extraction, not a cut |
| The Dialyzer gate, green and *measured* | — |
| Five commands: `voice_bank_*`, `sound_record_save` | 206 → 211 |
| **Clip effects** — reverse, gain, speed, reverb, chained in the operator's order | `Studio.Effects` |
| The mixdown out of a FROZEN LiveView, and effects applied per clip | `Studio.Render` |
| **Right-click a clip → Remove**, undoable | `clip_inspector.ex`, `studio_context_menu.js` |
| **The clip-click crash** — reported twice, fixed in four lines | `status_live.ex` |

---

## It started as two lines of drift

The morning's ask was small: SUPERMAP contradicted itself about the Dialyzer
gate, and a roadmap existed that the index had never heard of.

The Dialyzer half did not resolve the way it was framed. Line 94 said green, line
305 said red with 56 findings, and the obvious move was to pick the stale one.
**Running it said neither.** Exit 2, three findings, all in
`commands/appearance.ex` — three `refusal/2` fallback clauses that
`Appearance.set_background/2` could never reach, added with the 08-15 appearance
work. The 08-13 fix that made the baseline a *rule* rather than a file list had
held perfectly; 298 of 301 findings were that rule doing its job.

The operator called it: delete the clauses. They went, and the gate went green
with no baseline entry added.

**Then the deletion was measured rather than assumed.** A comment had gone in
claiming a fourth error reason would "fail a test rather than a caller." A probe
introduced one — `:probe_widened_reason` on `appearance.ex:617` — and **neither
gate caught it.** Dialyzer stayed at exit 0, all 28 appearance tests passed, and
`refusal/2` would have raised `FunctionClauseError` in front of the operator. The
comment was rewritten to say so. The trade stands: three clauses that can never
run are not worth a red gate everyone learns to ignore.

That answer came back later in the day in a better form. Two more unreachable
catch-alls appeared in new code, and the choice was not delete-or-baseline after
all — **a map with a default is total AND has no pattern to prove unreachable.**
Both wrong fixes look tidier than the right one, so the comment at
`@create_errors` carries the argument.

## The third row of the table, and what it cost

Before building anything, the roadmap said Studio → Voice was a `PLACEHOLDER`.
It had shipped two days earlier. That correction was one line — and it was in the
exact area the day's work was about to happen, which is the only reason it
surfaced.

The expensive one was VI.1's:

> **Pane 2 — takes, waveform, audition.** It needs a route serving a take's
> audio, which is its own surface.

It does not. `/studio/file/:name` has served any studio source with byte ranges
since the Studio shipped, and **a take is a slice of a source** — two offsets
into a file the browser can already fetch. The missing piece was never a route;
it was about twenty lines of WebAudio arithmetic.

That sentence kept a feature unbuilt for a week, at no cost to whoever wrote it.
It is now recorded in `Studio.Words`, because *"this needs its own surface"* is
the cheapest thing in the world to write and one of the more expensive things to
leave unchecked.

## Banks, and a rule derived three ways

V.0 reached one conclusion by engineering, by measurement, and by law:
**banks never merge, and a bank is a voice-and-channel, not a folder.** A phrase
spliced from two speakers sounds broken, and nothing downstream repairs it —
`Cutup.Select` ranks on acoustic fit, so it will cheerfully offer a stranger.

The roadmap said *not a folder*, so `Cutup.Bank` took that literally: a bank is a
**field on the index**, and `sounds/studio/` stays flat. Every existing index
stays readable, a source can be re-attributed without moving audio, and the ten
voicemails backfill into a reserved `voicemail` bank.

**The first version put an Ecto query inside `Index.load/1`** and 46 tests failed
instantly. The `Cutup` layer is database-free by design, and that property is
worth more than the check it was buying. `Bank.of/1` now validates name *shape*
only — which also means a deleted bank's takes keep their attribution instead of
silently re-filing themselves into the voicemail corpus.

A second finding, later and quieter: **the cut-up command surface ignored banks
entirely.** `sound_sentence` would have spliced across voices. `index_opts` now
scopes to the active bank by default, which changes nothing for existing callers
and closes the hole the whole partition exists to prevent.

## The microphone, and the thing that is still unproven

Capture lives in the WebView because **entitlements do not inherit across
process boundaries** — the process that opens the microphone is the process that
needs the TCC grant. Spawning `ffmpeg` from the BEAM puts it in a process with
neither, which is why `sound_record` can return a perfect WAV of digital silence.

An AudioWorklet, not `MediaRecorder`, for V.7's three reasons — the decisive one
being that `MediaRecorder` emits MP4/AAC in WKWebView and WebM/Opus in Chrome, so
**the two hosts would disagree** about a corpus whose entire purpose is comparing
takes. Echo cancellation, noise suppression and AGC are all explicitly off, and
`getSettings()` is checked afterwards because constraints are requests.

**Before touching `Entitlements.plist`, the wry question got an answer.** wry
0.55.1 implements `requestMediaCapturePermissionForOrigin` and returns `Grant`
**unconditionally, for every origin**. That is not an oversight — it is
[PR #1196](https://github.com/tauri-apps/wry/pull/1196), a deliberate workaround
for a macOS 14 WebKit double-prompt bug, and [issue #1195](https://github.com/tauri-apps/wry/issues/1195)
is still open with no configurability proposed. A version bump will not fix it.

So the choice is explicit rather than accidental: **granting our recorder the
microphone also hands every page the embedded browser visits a silent one.**
`Entitlements.plist` is untouched. `WKWebView.setMicrophoneCaptureState(.none)`
is the one mitigation not ruled out — it lives on the webview rather than the
delegate, so it is ours rather than a fork.

Meanwhile the capability gate reports **what the browser actually answered**
(`unproven` → `ready` / `denied` / `unsupported`) rather than claiming either
way. That is what let the whole surface ship before the spike: in Chrome and
`cargo tauri dev` it may work today, and a packaged build will name what stopped
it. **V.4a has still never been run.**

## One tab, after briefly being two

The recorder landed as a third sub-tab, `Contribute`, and `Studio.Registry` had
predicted that split in writing and promised it would cost one edit. It did.

**Then the operator merged them back**, and that is the more useful half. Two
rail buttons described the *implementation* — a dictionary module and a recorder
module — rather than the activity, which is one thing. The tell is the arrow
back: you find a gap by building a sentence and you close it by recording, and a
rail that makes you leave the tab to do that is a rail in the way.

The reversal cost the same one registry edit in the other direction. **That is
what proved the data-only registry, not the split.**

## Multiple takes, and revising a rule from this morning

`Take.store` refused every name collision, citing V.7: *"a recording is
unrepeatable; a name collision prompts, always."* Half of that was right.

A name the **operator typed** must still refuse — they asked for a specific file
and one exists. A name **derived from the word** must not: you asked to record
*harbor*, not to create `harbor.wav`. The morning's comment argued auto-suffixing
was wrong because you would have no way to tell the files apart — true when
nothing listed takes per word, and spent the moment the Library did.

The old behaviour was worse than untidy. **The recorder could capture each word
exactly once**, which makes a cut-up impossible by construction: every word stuck
at quote-only forever, in a surface whose one job is to say that quote-only is
not a cut-up.

## Preference is a pointer, not a score

"Use this take" stores `{bank, word} → {source, start_ms}` and applies at
selection time. Bumping the chosen take's `confidence` was the obvious
alternative and is wrong three ways — it makes the `origin` field lie (a
`:manual` take earns 1.0 by being marked by ear), it is not reversible, and it
cannot be per-bank. A dangling pointer is deliberately not an error: if the take
is deleted the splice falls through to what exists.

Deletion has three outcomes and the middle one is the guard:

| After removing the entry | Index | Audio |
|---|---|---|
| other words remain | rewritten | kept |
| empty, source was a one-word `:manual` recording | deleted | **deleted** |
| empty, anything else | deleted | **kept** |

A voicemail whose words were removed one by one is still a recording somebody
made, and V.7 is explicit that the masters are the only way back.

**That guard was uncovered, and breaking it is how it was found.** Inverting the
`origin: :manual` condition — so any emptied source lost its audio — failed *no
test*. `takes_test.exs` exists because of that, and re-breaking it now fails as
it should. Yesterday's lesson, arriving on schedule.

## What the repo's own guards caught

Six times, and each was a real defect rather than ceremony:

- **`remote_mode_test.exs`** — `save_take` called `Commands.call/3`, which
  defaults to `caller: :trusted`. A LiveView carries no token, so a remote
  browser driving it would inherit the full tier — on a **gated** verb. The UI
  now uses the domain module; the clip refusal moved down with it so both callers
  share one rule.
- **`check_cycles.sh`** — `Bank` → `Index` → `Bank`. The cycle was the honest
  signal: `Bank`'s own moduledoc says it does not know what an index looks like.
  The measurement moved to `Gaps.bank_in_use?/1`, and `delete/2` now takes the
  answer as an argument so the question cannot be skipped.
- **`form_submit_test.exs`** — the recorder's word field would have navigated
  away on Enter, remounting the LiveView mid-session. Second catch in two days.
- **`catalog_invariants_test.exs`** — flagged `voice_bank_list` as newly `:safe`
  and demanded a review. Bank labels are often people's names; the snapshot now
  records why that is no wider than `sound_gaps` already is.
- **`check_file_sizes.sh`** — failed a *documentation* edit, twice.
- **The LiveView tests** found a real browser bug: server-rendered content inside
  `phx-update="ignore"` can never be updated — not in a test, and not in Chrome.

## Two things measured rather than assumed

**A constant sine has no dynamic range**, so VAD read a test fixture as pure
noise floor and returned zero spans. It looked exactly like a broken aligner.
Probing it took one script: with speech-shaped bursts, alignment finds all five
words at max confidence 0.89 — correctly below `:manual`'s 1.0.

**The audition cache would have replayed the previous sentence.** The preview
overwrites one fixed filename, so the buffer cache is keyed on source *and*
version. Real audio of a real phrase is a convincing way to be wrong.

---

## Where this leaves the build

Everything except capture is done and tested: banks, recording (word and whole
sentence), audition, sentence build-and-play, multiple takes, preference,
deletion. 4,172 Elixir tests, 339 JS, Dialyzer at exit 0, docs drift clean.

**What has never run is V.4a** — `getUserMedia` in a packaged build, which needs
a person to click a permission dialog. Until then the recorder is honest rather
than working, and every path above is tested against synthesised PCM.

**And the entitlement decision is now explicit.** It was accidental this morning
— the app simply declared no microphone. It is a choice tonight, with the wry
behaviour read from the source and the one unexplored mitigation named.

### Deliberately not built

**No commands for take curation.** Deleting and preferring are destructive and
operator-shaped — the call `pocket_*` already makes, where the absence of a mount
verb *is* the enforcement. The agent reads the corpus and benefits from the
operator's preferences when it builds a sentence; it does not decide which takes
to throw away.

**No review-and-trim after a take.** V.7 wants waveform review with
`wave_trim.js`; a take currently saves or is refused, and the surface says so
rather than implying it with a button that does half the job.

---

# The Mix half

## Both things the operator asked for already existed

*"Right users can add clips into the mix and move them around. Thats it. we need
them to be able to remove clips and to be able to delete tracks."*

Both were built. **Remove clip** had a handler and a keyboard path — ⌫ on a
selected clip — and **no button anywhere**. **Delete track** had a real button
with a confirm, at 10px and 30% opacity, hidden entirely when only one track
exists.

A feature reachable only by reading `studio_keys.js` is missing for everyone who
has not read `studio_keys.js`. So the gap was discoverability, and the honest
report was to say so rather than build a second copy of working code.

## The effects chain, which is what "strengthen the studio" actually meant

The durable half of the ask was *"built so we can continue strengthening"* —
reverb, reverse, pitch. So the deliverable is a registry, not four features:

    @catalog entry + apply_one/2 clause
      → appears in the inspector
      → saves into the mix
      → applies on render
      → is audible in preview

Nothing in the UI, the mix format or the renderer changes. A test fails if a
catalog entry has no clause, so a dead control cannot ship.

Three properties every effect holds, each one a bug the chain would otherwise
grow: **total** (a bad parameter clamps, never raises), **format-preserving**
(or `mixdown` refuses the whole arrangement), and **length-free**.

**Length-free is the design call worth keeping.** Reverb adds a tail; speed
changes duration. So a clip's `duration_ms` means *how much source it takes*, not
how long it sounds. Re-deriving it would make the timeline jump under a dragging
hand and make undo move clips. `mixdown` sums overlaps, so a tail bleeding into
the next clip is correct rather than a bug. The panel says so instead of drawing
a lie.

Order is the operator's and is never normalised: reverb-then-reverse is a swell
into the note, reverse-then-reverb is a note with a tail.

## The gate forced the right extraction

`SoundStudioComponent` is `FROZEN` and could not hold any of this, so the
mixdown, `placement/1` and `install_render` moved to `Studio.Render`. The
component went **1,235 → 1,184**, and the render became testable without mounting
a LiveView — which is what made `preview/2` a function instead of a second copy
of the pipeline.

That is the whole argument for FROZEN, stated as an outcome: the choice was
extract or do not ship.

Preview is a **server render**, not WebAudio. Reverb has no client-side
equivalent, so approximating half a chain accurately would mislead more than not
previewing at all. Measured: 0.85s for a ten-second clip.

## The crash, and the comment that hid it

**The fifth row of the table at the top.** The operator had reported it twice:
clicking a clip threw them back to the Chat tab, with *"something went wrong"*.

`home_tab` is only ever `"chat"` at mount, so it was a remount — the LiveView
dying and the client reconnecting. The cause was one missing clause:

> **A hook's `pushEvent` goes to the LiveView.** `pushEventTo` is what targets a
> component.

`track_arrange.js` called `pushEvent("select_clip", …)`, `StatusLive` had no
`select_clip` clause, and every click was a `FunctionClauseError`.

**Three things made it survive two rounds of testing**, and they are the part
worth keeping:

1. **The comment asserted the opposite**, in two files — and ten lines below one
   of them, `move_clip` correctly used `pushEventTo`. Two calls in one function
   behaved differently while a comment claimed they were the same.
2. **The test was written to agree with the comment.**
   `render_hook(element(view, "…"), …)` routes to the component and passes;
   `render_hook(view, …)` routes where the browser goes and crashes. Only the
   first existed.
3. **Nothing in the console.** It was a server crash, so every client-side
   hypothesis — a navigation, a JS exception, a form submit — was wrong, and
   ruling them out took a full pass before the right question got asked.

It was found by driving a real browser: empty console proved the server was
dying, and the LiveView-targeted path reproduced it on the first try. The
generalisation was then checked — **`select_clip` was the only hook event in the
app with no `StatusLive` handler.** Every other one already had one.

Four lines to fix. Both comments corrected, both paths now tested, and a
fallback clause added so a payload without an id costs a no-op rather than a
crash — because ending a bug caused by one unmatched clause with a second
unmatched clause would be a poor joke.

## And one thing the screenshot caught that no test would

With the inspector docked, the clip's name printed **on top of** the arranger's
hint line. Measured in the browser: 27px of overlap. The arranger's root was
`flex-1 min-h-0` inside a scrolling column, so it compressed below its own
content and the tracks spilled over whatever sat beneath. Now `shrink-0` — taking
natural height and letting the column scroll, which is what `overflow-y-auto` on
the parent was always for. Re-measured: 12px of clearance.

## Verified in the operator's own browser

Not only in tests: clicked a clip (stays on Studio, inspector opens, ring
appears), right-clicked one (menu opens with exactly one item), removed it (4
clips → 3, no crash) — **and undid it**, restoring the real `busterClaw-song` mix
to 4 clips across both tracks, confirmed on disk.

### Deliberately not built, second arc

**Effects in the timeline transport.** Play still schedules raw sources and does
not reflect the chain. Render and the per-clip preview do. Stated on the surface
rather than left to be discovered.

**Pitch-shift that holds duration.** `speed` is tape varispeed — pitch and length
move together, honestly labelled. Holding duration needs a phase vocoder, which
is its own catalog entry rather than an option on this one.


---

# The quality pass

The operator asked, at the end: *"lets make sure dead and orphaned code is
deleted and that we are thoroughly modularized."* Scanned rather than asserted —
every public function in the eight new modules against its call sites, every JS
export against its importers.

**Int16 saturation was written three times.** `SoundStudio.clamp16/1`,
`Take.clamp/1`, `Effects.clamp16/1` — and the first carried the comment quoted in
the table above. Three implementations of "what is the loudest sample" is two
that can disagree, and a wrapped sample is a full-scale sign flip at the loudest
moment of the audio. `samples/1`, `map_samples/2`, `frame_bytes/1` and
`clamp16/1` are public on `SoundStudio` now — the module that DEFINES the format
— and both copies are gone.

**Preview versioning existed twice**, identically, six lines each. It is what
stops `voice_audition.js` replaying the previous sentence or chain from a cached
URL — a bug already hit once today — so it is now `Studio.Preview` and stated
once.

**`Take.index_for/3` was public with no caller anywhere.** Made private, after
checking for dynamic references first: this repo has an incident on file where a
`defp` conversion passed 3,569 tests and broke seeding at runtime.

**Two stale module references** (`Status.Contribute`, renamed hours earlier), and
**one module with no size cap** — `capture/take.ex`, the only one of the day's
additions that missed getting one on arrival, which is exactly the drift the
inventory exists to make visible.

## The two "dead" exports that were not dead

`meter.js` exported `TARGET_LOW_DB` and `TARGET_HIGH_DB` and nothing imported
them. The obvious move is to delete them. The truth is that **V.6 asks for the
meter by name** — *"−60 to 0, with a marked target zone"* — and the constants had
been exported for a zone that was never drawn.

Deleting them would have quietly closed a requirement. The zone is drawn now,
positioned from the same constants the hook colours the bar with, so the band the
operator aims at and the band the meter calls "good" cannot drift apart.

Then the same commit created two NEW orphans doing it — `data-role="target-low"`
and `target-high` on the scale labels, read by nothing — which the second run of
the same scan caught. The lesson is cheap and worth keeping: **run the scan
again after fixing what it found.**

## What was deliberately NOT split

`Status.Voice` sits at 365 against a 400 cap and its own comment names the seam:
the CORPUS half (report, query, phrase, preview) and the TAKE half (selection,
preference, deletion). It stays whole. The halves interact on most operations —
`delete_take` calls `load_report`, and the Words pane needs both — so splitting
produces two modules that call each other constantly. **That is dispersal, not
modularisation.** The seam stays documented for when it earns itself.

Three JS "dead method" hits were false positives (`onClick` is bound as a
listener; `process` lives inside the AudioWorklet template string). Each was
checked rather than trusted, because a crude grep is how a load-bearing function
gets deleted.

**The strongest signal in the whole pass is one that costs nothing**: Elixir
warns on unused private functions, so `mix compile --warnings-as-errors` passing
means no dead `defp` survives anywhere in the day's work.


---

## Duplicate, and the defect it surfaced

*"add a 'duplicate' button to the right click menu for clips."* Same source, same
duration, same chain, on the same track **immediately after the original** —
which is deliberately not where paste drops things. Paste means "put this
somewhere"; duplicate means "again, right here."

Building it found a defect in code shipped the same morning. **The clipboard spec
was `%{source, duration_ms}`, written before effects existed**, so ⌘C/⌘V on a
clip you had shaped pasted it DRY — silently, and only audible on render.

The fix was not to teach paste about effects. Both now go through
`StudioMix.place_copy/4`, because two ways to say "a clip like this one" is
exactly how one of them came to forget the chain. That is the same lesson the
quality pass had just applied to int16 saturation, arriving twice in one day from
opposite directions: **the duplication is not the bug, it is the mechanism by
which the bug becomes possible.**

Verified in the browser and undone afterwards; the guard was then broken on
purpose (`effects: []` in `place_copy/4`) to confirm the test fails without it.

**And the FROZEN gate earned its keep a second time.** The handler needed four
lines in a file that may not grow, so it was funded by an extraction rather than
a raised cap: `render_error/1` moved to `SoundStudio.Format`, where the tab's
other pure presentation already lives. 1,184 → 1,178. Twice today the freeze
turned "just add a bit here" into a structural improvement, which is the entire
argument for capping a file you have already decomposed.

---

## The evening's third arc: two reviews, and one of them cost 7,264 lines

Two product reviews landed, both dated today, neither about code quality:
**[`NOVICE_AI_APP_REVIEW`](../roadmaps/NOVICE_AI_APP_REVIEW.md)** — the app
through the eyes of someone who has never used an AI agent — and
**[`YEAR_ONE_SURVIVAL_REVIEW`](../roadmaps/YEAR_ONE_SURVIVAL_REVIEW.md)**, the
same app judged by a committed user twelve months in.

**They are the same review at two time horizons**: the product presents its
machinery instead of its loop. The newcomer meets Claude Code, a workspace,
OAuth, trusted senders, a terminal, a shift, Dispatch and Sentinel before
completing one task. The year-one user finds eight tabs of permanent navigation
weight, half of it holding features that never became habits, and six partial
memories — Chat, Notes, Memory, Activity, Dispatch, the filesystem — where they
needed one.

**One claim from the novice review was checked against the code rather than
believed, and it is worse than a copy problem.** `off-duty` appears in exactly
two files in the web layer, `explained/gws.ex:175` and `setup_live.ex:268`, and
**both are prose telling you to type a CLI command.** No LiveView reads
`Orchestration` at all — so the app cannot show whether a shift is running, let
alone stop one. That is not a UX nicety: `IX.3`'s pass bar names *"stop the agent
immediately"* as one of the two tasks that matter, so today the release plan has
a task nobody can complete inside the app. Filed, not fixed.

### Scene3D is deleted

The year-one review proposed a **Labs** section for Studio, Voice, Cutup and
Scene3D. **The operator took the harder half of that advice for one of them** —
*"we don't want it"* — and kept Labs for the others later.

| | |
|---|---|
| `scene3d.ex` + its five stages | **3,370** |
| Six test files | **3,765** |
| Chat wiring, test and CSS cleanup | 176 |
| **Removed / added** | **7,311 / 47 — net −7,264** |

**The seam was far cleaner than 3,370 lines suggests, and that is the finding.**
Scene3D was reachable from exactly one place — the homepage chat — and was never
a command, never in the catalog, never in the size gate. So the whole removal is
`push_msg/7` becoming `/6`, the visual pool numbering drawings and attachments
only, history replay no longer re-rendering, and one guide in the system prompt
instead of two. A feature can be enormous and still be *attached* by four lines,
which is the argument for contract-first construction arriving from the exit
rather than the entrance: **the same discipline that made four parallel agents
compose on 08-08 is what made deleting their work an afternoon.**

**Both `LEFTOVERS_AGENT_CORE` entries closed by deletion rather than dangling.**
Neither was ever blocked on difficulty. Both said *waiting on evidence* — the
guide-as-skill move and four polish items, deferred because "nobody has yet
wanted them prettier." In the eight days since, nobody did. **A deferral whose
stated unblock condition is other people's enthusiasm has no expiry, so it needs
a reader willing to call the absence itself the answer.**

### The palette lost its second home

`Scene3d.Svg` sole-sourced the app's validated 5-slot series palette, having
inherited it when the Chart Builder that first carried it was deleted on 08-08.
The standing instruction, in its own `@palette` comment, was **promote it, never
copy it** — because a copy is how slot ordering quietly stops being a guarantee.

**There was nobody to promote it to.** One consumer before the cut, zero after,
and a `BusterClaw.Palette` with no callers is precisely what the dead-code pass
exists to delete — it would have gone in the next sweep with nothing to say for
itself. So the five hexes, the slot order, and the numbers that make the order a
mechanism rather than a preference (worst adjacent CVD ΔE **16.0**, normal-vision
ΔE **23.4**, all five slots ≥**3:1** on the dark canvas) are recorded in
`archive/08-08-26-scene3d-roadmap.md`, with the rule attached: **the next surface
that needs series colours promotes them at that moment and cites the file.**

Written down plainly because it is the second time this measurement has outlived
its home in eight days. **A validated fact with exactly one consumer is one
deletion away from being a guess again**, and the honest place for it is not a
module built in advance — it is the document that explains why the numbers are
what they are.

### The test that pins an absence

The two Scene3D LiveView tests became one. A reply carrying a `scene3d` block
must now render as ordinary prose, with no card and no `.ic-scene-card`. It costs
one test and means a re-introduced renderer fails loudly rather than arriving
unnoticed — the same shape as the reverse hook assertion added on 08-13, and for
the same reason: **after a deletion, the thing worth guarding is that it stays
deleted.**

`mix precommit`: **3,950 tests, 0 failures.** `bun test`: 339 pass. Pushed as
`ac23f47`.

### What the reviews are owed, and did not get today

Both are still untracked and unlinked from the SUPERMAP, which is the one thing
this repo's own convention forbids — findings get filed by section, not left
floating. Their P0 overlaps almost entirely with `FRONT_DOOR` `VI-a`/`VI-e`/`VI-f`,
which has been **ACTIVE, nothing done** since 08-09 and is the cheapest
high-leverage work anywhere in the build by the repo's own accounting.

**And a caution that belongs on both of them:** neither reviewer ran the app.
This repo has the lesson on file twice — *a finding written from reading is a
lower bound* — and the whole through-line of this very summary is claims that
were true when written and quietly stopped being true. The year-one review in
particular recommends the largest change in it (rebuild Home as **Today**, one
evidence layer, five areas) and then, near its end, says the product needs local
feature-usage data before deciding what stays. **That paragraph is the argument
against acting on the rest of it yet** — restructuring navigation for a mature
user who does not exist is the same error as building number provisioning before
`IX.4` says anyone wants it. Scene3D was the one item that needed no such data:
its own roadmap had recorded, in writing, that nobody had wanted it.

---

# The afternoon: everything here was already written down

Seven things landed this afternoon and **not one of them needed to be
discovered.** Every single one was filed, dated, and sitting:

| The work | Filed | Sat for |
|---|---|---|
| `VI-a` — one sentence, four surfaces | 08-09 | a week, "ACTIVE, nothing done" |
| `G-30` — a visible kill switch | 08-09 | scheduled for the release *after* the one it gates |
| The size gate's missing 19 files | 08-13 | ranked action #5, never taken |
| The Sound Studio catalog split | frozen phase | weeks |
| The per-clip catalog rescan | 08-13 | filed, confirmed live at HEAD |

**The morning's lesson was claims that stopped being true. The afternoon's is
the opposite failure: claims that stayed true and changed nothing.** A map is
not a mitigation. `VI-a` was described in its own file as "the cheapest
high-leverage work anywhere in the release" and it took an afternoon — the week
it waited was not a scheduling decision, it was nobody picking it up.

## `G-30` — the brake you can reach without a terminal

Until today the emergency stop was a `STOP` file on disk, reachable only by
typing `./buster-claw off-duty` — a command the app described in prose, on two
screens, in a product whose second setup step promises *no terminal knowledge
needed*.

**The promotion from R2 to R1 is not a preference, and that is what made it
easy.** `IX.3`, the release plan's own first-run test, lists *"stop the agent
immediately"* among the two tasks it says matter most, with a pass bar of four
users in five, unaided. That task could not be completed inside the app at all.
**The release gate contained a test nobody could pass, and its fix was scheduled
for afterwards.** Either `IX.3` drops the task or `G-30` moves; dropping it
means dropping the product's claim from the product's own test.

`DutyLive` is a fourth sticky dock LiveView. It renders **nothing** when no
shift is running — a permanent brake showing "idle" trains the eye to skip the
spot the real one appears.

**Three decisions worth keeping:**

**Latch, then stop.** `Dispatcher.maybe_run/1` consults the kill switch on every
decision, so engaging first closes the door before anything else runs. Stopping
first leaves a window where a `shift_start` brings the pump back up and the
operator's brake reads as a glitch. `shift_start` already clears the latch, so
resume needed no new mechanism.

**It states its limit on the button.** *"Stops new work at once · a run in
progress finishes."* Nothing in this app cancels a headless run mid-flight — the
Dispatcher monitors, it does not kill. A brake that overstates its reach is
worse than one that names it.

**No confirmation**, against the house `data-claw-confirm` idiom. An emergency
brake that asks "are you sure" adds friction at the one moment friction is most
expensive. A mis-click costs a restart; hesitating in front of a modal while an
agent does something alarming does not have a bounded cost.

### And a guard that guarded nothing, caught this time

I wrote an ordering test — subscribe, call `stand_down/1`, await
`:shift_stopped`, assert the latch. **It passed with the order swapped**, because
by the time a subscriber receives anything both lines have run. It looked like an
ordering guard and guarded nothing.

Deleted, with the reason left where it stood. What *is* guarded is the property
that matters — the latch goes down regardless of what the stop does — and the
`{:ok, :latched}` case proves it. **Yesterday's lesson arriving one day later and
being caught before it shipped**, which is the only reason it is a footnote
rather than a section.

## `VI-a` — and two of the four surfaces already agreed

> **An assistant on your Mac that uses your tools, keeps working, and shows you
> what it did.**

Operator's call, assistant-first. The three clauses are the three things this
product has that a chat box does not, in the order a newcomer can check them.

**The map was wrong about its own problem.** `VI.1`'s table said busterclaw.lol
pitched *"a desktop runtime where an AI agent manages your web interactivity"*.
It had not for some time — the site already said the README's line, verbatim. **A
map that records another surface's copy is a copy of a copy and goes stale
silently**, which is the argument for fixing this with a test rather than a
corrected table.

`front_door_test.exs` asserts the sentence in the three in-repo surfaces, refuses
all three retired pitches anywhere in them, and pins `VI-i` by refusing the word
*Claude* in the chat's empty state. **It reads source rather than rendering** —
the README is rendered by nothing, and a render test would have passed while it
drifted, which is the case that actually happened.

**It failed on its first run against real code**, catching the retired
queue-jargon phrase inside a comment *I had just written explaining the
retirement*. The comment was reworded rather than the guard loosened.

**It cannot reach busterclaw.lol and says so in its own moduledoc.** Four
surfaces, three guarded, and the unguarded one is the repository that carried
opposite licence terms for two weeks in August.

### One cost, recorded rather than glossed

`IX.1`'s "before" reading was never taken. There is no baseline and the
counterfactual is gone permanently. It was the right trade only because the old
copy contained three verifiable falsehoods — **you do not A/B-test against a
version that lies** — but `IX.1` on the new copy can now report a reading and
never a delta.

## Part IX was measured, and three of five rows were wrong

Ninety seconds of `curl` against the live site, and the map was more wrong than
the site. busterclaw.lol is a **hash-routed canvas app**: the server only serves
`/`, so every path 404s by construction, and the map had read those 404s as
missing pages.

- The download page **exists**, at `#/downloads/busterclaw`.
- Privacy and terms **exist**, at `/busterphone/*.html`, BusterPhone-scoped.
- The headline **already matched** the README.

**What it missed is worse than what it invented.** A live Download button
resolving to `https://DOMAIN-TBD.invalid/` — a 404 reads as "not built yet"; a
dead host on the last click before the product reads as broken. And four false
capability claims, live in the deployed bundle: *203 commands* (211),
*Sentry and Umami* (removed 08-14), *outbound calling is not built* (shipped
08-15), and A2P 10DLC as the SMS blocker (abandoned 08-15).

All four fixed and **deployed**, verified against the deployed bundle rather than
the source. The site is a fifth front-door surface, in another repository, that
no test here renders — and nothing watches it. Today it was fixed because someone
ran `curl` on a hunch.

## The size gate finally covers the whole codebase

Ranked action #5, three days old, and the layers it named had not moved:

```
assets/js         14,202 lines   ZERO capped
desktop/tauri/src   4,681 lines   ONE capped
```

34 files added, **measured at HEAD rather than copied from the review** — which
mattered four times. `gmail.ex` is 301 not 739 (it was split), `integrations.ex`
is 494 not 539 (the dedup landed), `scene3d.ex` was deleted yesterday, and
`studio_mix.ex` had grown **595 → 781 in three days** on a file the review called
cohesive. That last one is the gate's whole argument, found by the act of
building it.

Verified by breaking it in both directions rather than assuming.

**One correction to something I claimed earlier today:** `appearance.ex` was not
drifting ungoverned. It is capped at 895 and sits at 891. The argument rested on
the 34 files that genuinely had no cap.

## The Studio became a place

Three asks in three messages, and they composed into one move.

**`/studio` is a route** with a flat rail — Mix, Voice Library, Sketch Pad. The
alternative was an outer Studio/Sketch pair with the old rail nested inside, and
it lost to the reasoning this repo had already written down when the Voice tab
was briefly split in two this morning: **a rail that makes you leave a tab to
finish a loop is a rail in the way.**

Home dropped from eight tabs to seven. It had cost Home twice — every panel
there renders behind an `:if`, so the studio's component was destroyed and
rebuilt on every glance at Chat, which is the entire reason its selection, trim,
clipboard and undo stacks had to be hoisted into `StatusLive`.

`status_live.ex` **1060 → 738**. The ratchet asked for the new cap, which is the
gate doing its job: left at 1060 it would have silently re-opened 300 lines the
extraction had just closed.

**A behavioural change, accepted and written into the test that used to assert
the opposite:** leaving `/studio` unmounts the LiveView, so the undo stack, trim
and clipboard no longer survive navigating away. The mix is on disk; only
in-progress editing state is lost, and leaving a page is a stronger action than
glancing at a sibling tab.

**Explained became one tab.** `ramshackle.ex` deleted, the half worth keeping
merged into `studio.ex`, net −432 lines. Its registry entry had drifted into
claiming the Voice surface *"is not built"* — months after it shipped. The
framing the operator asked for is now itself guarded: if the Studio is ever
presented as settled, a test fails and somebody has to decide whether that is
true.

## Mix: the frozen phase, then the file bar

**Phase 3, frozen for weeks, took an afternoon.** The catalog moved to core —
and it only worked because of the correction the 08-13 review made to the plan:
four of five builders baked router `~p` URLs, so a naive move would have dragged
`BusterClawWeb.Router` into `lib/buster_claw/`. **Core carries a filesystem
path — what the unbuilt `sound_*` CLI needs — and the web adds the URL.**

That split made the filed rescan bug visible as two different things.
`render_mix/1` passed `&resolve_source/1`, which calls `groups/0` fresh every
time Render asks — and `groups/0` is **four directory listings plus a database
query**. An n-clip mixdown did n of them. It reads the catalog once now.

Then the sidebar went, and the tracks got the width.

**Nothing was allowed to be orphaned, and two things nearly were.** The
sidebar's *rows* were what the right-click context menu attached to — rename,
delete, info, new-audio all find their target by `data-studio-source`. Deleting
the sidebar would have deleted those four verbs **silently**, because a context
menu that never opens raises nothing. And the drop zone was the only thing
saying where an imported file lands.

**Render and Delete are deliberately not in the File menu.** They were, for about
an hour, and came out because the arranger already has them beside the mix they
act on — a second door to one action is exactly how a clip's effect chain was
lost this morning. The test that decided it: **is the existing control
contextual?** Render and Delete only mean anything while a mix is open.

Group folding was deleted rather than migrated: a submenu has nothing to fold,
and a persisted preference no surface can honour is worse than none. Its five
tests went too, **with a note where they stood — they did not start failing,
they stopped having a subject.**

### The bug the port caught

The sidebar compared `@selected.id == item.id`. I first wrote
`item.id == @selected` — comparing an id against the whole catalog item. It
would have shipped a menu that highlighted **nothing, on every row, forever**,
and no test would have noticed. Caught by porting the sidebar's markup carefully
rather than by rewriting it from memory.

## Three sessions, one tree

The clearest operational fact of the day. At various points three agents were
writing into this working tree at once, and it cost real care rather than real
damage:

- **The Sketch Pad was built twice-over.** I built a minimal one before being
  told another agent had it; no files collided, and they have since taken it
  over and improved it — pure `lib/sketch.js`, `data-active` pressed states, its
  own roadmap. The registry entry, panel dispatch, gate caps and tests are
  wiring they needed regardless.
- **Two gate cap raises in `check_file_sizes.sh` are theirs** and were left
  unstaged, reconstructed out of my commit rather than swept in.
- **`setup_live.ex` and its test** carried another session's hunk all afternoon,
  so `VI-k` — the wizard still calling the kill switch a CLI command — is filed
  rather than fixed. One line, whenever that file is free.
- The shared test lane showed **174 failures** at one point, all `Database busy`
  from a concurrent run. `MIX_TEST_PARTITION` is the answer and it is worth
  reaching for sooner than I did.
