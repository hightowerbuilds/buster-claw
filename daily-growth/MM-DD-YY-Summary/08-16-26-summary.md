# 08-16-26 — Four estimates outlived the things they described

One arc: the Studio's Voice tab became the **Voice Library**, a surface where you
browse your words, hear them, build a sentence, hear that, and record what was
missing. Voice banks, an in-app recorder, audition, curation. It started as two
doc fixes.

The through-line arrived four times before it was recognisable, and it is not
yesterday's. Yesterday was *guards that guarded nothing*. Today was **written
claims that were true when written and had quietly stopped being true**, every
one of them understating what the code could already do:

| The claim | Written | Actually |
|---|---|---|
| "The Dialyzer gate is red — 56 findings" | 08-13 | Green that day, red again with **3** |
| "Studio → Voice: **PLACEHOLDER**" | 08-09 | Built 08-14, two panes shipping |
| Pane 2 "needs a route serving a take's audio, which is its own surface" | 08-09 | The route had existed since the Studio shipped |
| "A name collision is refused, never auto-suffixed" | **this morning** | Made the recorder able to capture each word exactly once |

The fourth is the one worth sitting with. **I wrote it, defended it in a comment,
and it was load-bearingly wrong within nine hours** — not because the rule was
bad, but because it was applied to a case it was never about.

Not one of the four was found by reading. The first was found by running the
gate, the second by opening the file, the third by asking whether the route
really was missing, the fourth by an operator asking for something the code
refused to do.

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
