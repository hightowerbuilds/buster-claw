# The Sound Studio — Roadmap V.1

> ## ARCHIVED 08-02-26 — shipped as a cutting and arranging tool
>
> **Built, over four days:** the pure editing core (`Notifications.SoundStudio`
> — splice, fade, normalize, mixdown, WAV parse/render), the Studio surface as a
> Home sub-tab with every audio source down the left, drag-to-trim on the
> waveform, the multi-lane arranger, copy/paste/undo keybindings, track identity
> and colour, a transport that performs the timeline, import through
> `/usr/bin/afconvert`, and right-click delete (08-01).
>
> **Deliberately not built — two of the three halves the 07-30 scoping locked:**
>
> - **Phase 2, the `sound` command surface.** The studio is GUI-only; no agent
>   or CLI can reach it. The gap is real and the spec below is complete.
> - **Phase 4, the chime designer.** The tone-spec editor was the third half of
>   the original scope. The 16 bundled chimes remain fixed; you can cut and
>   arrange audio, but you cannot *tune* a chime.
>
> Both moved to `roadmaps/LEFTOVERS.md` rather than dying with this document —
> their designs are Phases 2 and 4 below, still good, and either one that
> genuinely gets wanted should be **promoted back out to its own roadmap**
> rather than done from a leftover line.
>
> **Phase 5's remainder** (the packaged webview's autoplay posture, and seeking a
> long track) rides with the byte-range walk already in `LEFTOVERS`. Its harder
> half was answered on 08-01: **`afconvert` executes under the packaged
> sandbox** — import works in a real build.
>
> **Still worth re-reading before touching audio:** Part V's landmines. Three of
> them bit during this build exactly as written, and one of them (`phx-target`
> on a component-owned hook) bit again on 08-01 during the delete-menu work.

**Date:** 2026-07-30 · **Status:** SCOPED — plan first, per the operator's 07-28
call on `SOUND_ROADMAP.md` Part V ·
**Scope:** the docketed audio editor, plus the surface and the designer around
it. `SOUND_ROADMAP` built the *plumbing* — what rings, when, routed how. This
builds the *authoring*: where a sound comes from in the first place.

**Absorbs `MUSIC_ROADMAP.md` and `SOUND_ROADMAP.md`** (both complete, both
archived 07-30). Their shipped-work records are history; their *findings* are
Part V below, because five of them are traps this build walks straight into.

**Operator decisions, locked 07-30:**
- **All three halves are in scope** — the audio editor with a CLI (splice cuts
  out of recordings, apply them as effects), a visual Studio surface, and a
  chime designer that tunes `SoundGen` specs live.
- **Placement: a Home sub-tab**, in the strip beside Music — not a dock tab,
  not buried in Settings. Sound authoring sits where music playback sits.

> **Vocabulary swapped 08-01 (operator call).** What this document's history
> calls a *track* is now an **audio**; what it calls a *lane* is now a
> **track** — operators expect DAW terms, where you add tracks to an audio.
> The code renamed with it (`StudioTrack` → `StudioAudio`), the phase records
> below stay as written (they are history), and the **v1 disk format keeps
> the old words on purpose** (`studio/tracks/`, `.track.json`, `"lanes"` key)
> because those files are hand-editable and may already exist. `to_map`/
> `from_map` are the entire translation layer.

---

## Part I — What exists, and why this is mostly assembly

Six seams are already load-bearing. This roadmap is largely the work of
connecting them, which is the reason it can be ambitious.

| Seam | Where | What it gives us |
|---|---|---|
| Two-layer resolution | `notifications/sound.ex:157` | "Apply this as a sound effect" is **already** just `File.write` to `<workspace>/sounds/<key>.wav` — the workspace layer beats bundled *by basename*, with no routing entry needed. There is no "install a sound" feature to build. |
| WAV writer + tone language | `notifications/sound_gen.ex` | Pure-Elixir PCM16→WAV with a hand-rolled header (`sound_gen.ex:169`), and a tone-spec vocabulary (`tone/5`) the designer can expose directly. We already write WAVs; we've never *read* one. |
| Waveform renderer | `assets/js/audio/clipwave.js` | A WGSL DAW-region renderer that fetches real audio, decodes it to a 256-bucket envelope texture, and draws it Pro Tools style. Built for the Phone rack; the Studio's waveform is this plus a selection overlay. |
| Library audio serving | `telephony_recording_controller.ex` | Byte-range serving of Library audio, path-guarded to `Artifact.root()` via `FileManager.within?`. Recordings are already fetchable by the browser. |
| Routing + audition UI | `notify_settings_live.ex` | Per-key assignment, "silent" as a definitive stop, preview through the real two-layer route. The Studio hands off to this; it does not reimplement it. |
| Home sub-tabs | `status_live.ex:1066` | A tab is one entry in a literal list and one `live_component` block. The Music tab is the template. |

**What does not exist:** any `sound` verb in the command catalog. Grep
`lib/buster_claw/commands/catalog/` — there is no sound entry at all. The CLI
front door Part V assumed is genuinely new construction.

---

## Part II — The decisive constraint, and the finding that dissolves it

Recordings arrive as whatever the carrier wrote — Twilio's voicemails are
typically **mp3**. Elixir cannot decode mp3, and `SoundGen`'s hand-rolled WAV
knowledge is write-only. Every editing operation we want — splice, trim, fade,
normalize — needs decoded PCM. So the studio appears to need a codec.

**The rejected answer is `ffmpeg`.** It lives at `/usr/local/bin/ffmpeg` on this
machine, which is Homebrew, which means *this machine only*. Shipping it means
bundling a large binary into an app that already has an Intel-only build crisis
(`DISTRIBUTION_ROADMAP`), signing it, and inheriting an LGPL/GPL provenance
audit — reopening precisely the licensing question that Phase 0's "synthesize
it ourselves" decision closed.

**The answer is `afconvert`.** It is a macOS *system* binary at
`/usr/bin/afconvert` — present on every Mac, nothing to bundle, nothing to
sign, no license to audit. Probed 07-30, both directions:

```
afconvert -f WAVE -d LEI16@22050 -c 1 <any input> out.wav
  mp3 → 1 ch, 22050 Hz, Int16 ✓
  m4a → 1 ch, 22050 Hz, Int16 ✓
```

That output format is **byte-for-byte the format `SoundGen` already writes**:
PCM16, mono, 22.05 kHz. The decoder hands us exactly the buffer our synthesizer
produces, and afconvert resamples and downmixes on the way in, so a 44.1 kHz
stereo source needs no resampling code of ours.

**The rule this sets:** shell out at the **import boundary only**. Once audio
is PCM16 mono, every edit — splice, fade, gain, concat — is plain binary
arithmetic in Elixir, testable without a subprocess. `afconvert` never appears
in the edit loop, only at the door. This is the same shape as Phase 0: reach
for the outside world once, own everything after.

---

## Part III — Design rules

1. **The CLI is the engine; the UI is a client.** Every studio operation is a
   command-surface verb, and `SoundStudioComponent` calls the same functions the
   verb calls. Not a courtesy to headless use — it is how the editing math gets
   tested without mounting a LiveView, the same split `SoundBoard` and
   `Music.Player` already use, for the same reason. It also makes the agent able
   to cut a sound, which is the interesting version of this feature.
2. **Edits never touch the source recording.** Read-only in, new file out into
   `<workspace>/sounds/`. A voicemail is evidence; the studio is not permitted
   to modify one, ever. No in-place write, no "save over".
3. **One internal format: PCM16 mono 22.05 kHz.** Accept many formats at the
   door, store exactly one. A format zoo inside the editor would mean every
   operation branches on sample width.
4. **The bundled set stays read-only.** The designer writes to
   `<workspace>/sounds/`, where basename override already does the work.
   `sound_gen.ex` remains the untouched canonical recipe for the shipped 16 —
   codegen-into-source would need a recompile to hear a change and would break
   the "bundled is read-only at runtime" posture that Phase 0 paid for.
   *(Operator: this is my call, not yours yet — overturn it here if you'd rather
   your taste land in the shipped defaults.)*
5. **Designer specs persist as JSON in `Settings`, keyed by name.** A chime you
   made last week is reopenable and nudgeable. Rendering is deterministic from
   the spec, so the spec is the document and the WAV is the export.
6. **Never:** destructive operations on Library files; a realtime effects rack
   (reverb, EQ, compression); multi-track mixing; recording from a microphone.
   The studio cuts, shapes, and synthesizes. Everything else is a DAW, and a DAW
   is not what a phone-answering agent needs.

---

## Part IV — The phases

### Phase 0 — The audition — **DONE 07-30**

> Auditioned by the operator, all sixteen, spoken-labelled and grouped by family
> (`say` announcing each key before its chime — 16 unfamiliar tones in a row are
> unmappable otherwise). **No defects raised.** For a taste gate that is the
> verdict: the synthesized set stands, Risk 3 does not fire, and no tone spec was
> re-tuned. The designer (Phase 4) therefore stays where it is in the order —
> a nice-to-have, not a rescue.
>
> **Measured before listening, and still true:** the set is *not* clipped (0
> samples at the ceiling across `order`/`security`/`alarm`/`confirm` — the Phase
> 0 test's claim holds), but peak levels span 8.6 dB, and `order` sits at
> **−0.0 dBFS**, hotter than every neighbour and 3.4 dB above `security`. Peak is
> not loudness — `security` runs 1.01 s of repeating alternating tones against a
> 0.44 s decaying chord — so this is an *inversion on paper only* until an ear
> says otherwise. Left as-is deliberately; see Risk 5.

The sixteen chimes had never been heard by a human. This ran first because it was
the only phase that could reorder the others.
*Acceptance:* met — the set was heard and accepted.

### Phase 1 — `Notifications.SoundStudio`, the pure core — **SHIPPED 07-30**

> 24 tests, credo `--strict` clean, and an end-to-end walk that tests cannot
> stand in for: `security.wav` imported, spliced 0–300 ms, faded, normalized,
> written — and **`afinfo` (macOS's own decoder, not our parser) reads the
> result back as `1 ch, 22050 Hz, Int16, 0.300000 sec`**, which is the check
> that matters, because a parser and a writer that agree with each other and
> with nothing else are a closed loop.
>
> **Named `SoundStudio`, not `Sound.Studio`** — `notifications/` is flat
> (`sound_gen.ex`, `sound_board.ex`), and house convention beat the sketch.
> Likewise `import_source/1`, not `import/1`: `import` is a
> `Kernel.SpecialForms` macro and cannot be defined as a function.
>
> **Three decisions worth keeping:**
>
> 1. **The parser walks the RIFF chunk list; it does not seek to byte 44.**
>    `SoundGen`'s minimal header does put data at 44, so a fixed-offset parser
>    would have passed every test written against our own output — and then read
>    `LIST`/`fact` metadata as audio on the first real afconvert import, which
>    sounds like a burst of noise at the head of every imported clip. Odd-sized
>    chunks carry a pad byte, and the test that proves this uses a deliberately
>    9-byte chunk. *(The first draft of that test used a 10-byte body and
>    appended a pad anyway — the parser correctly rejected it. The test was
>    wrong, which is the right way round.)*
> 2. **Splice is half-open `[from, to)`.** This is the answer to the classic
>    click: with an inclusive end, cuts `0–500` and `500–1000` both contain
>    sample 500, so joining them repeats it — a one-sample step, audible
>    precisely because it is a discontinuity. Pinned by a test that splits a
>    ramp in two and asserts the rejoin equals the original *exactly*.
> 3. **Every sample write goes through one clamp.** Rounding a scaled sample can
>    land a step outside int16, and a wrapped sample is not mild distortion — it
>    is a full-scale sign flip. The normalize test drives int16's asymmetric
>    negative rail (−32768, which has no positive counterpart) at three
>    different targets.
>
> Fades land on true zero at both edges by construction (`i / (n-1)`), because a
> clip cut from the middle of a voicemail starts mid-waveform, and a
> mid-waveform start is a step from silence to full amplitude.
>
> **Not carried out:** normalizing the bundled 16 (Risk 5). The function exists
> and is tested; applying it rewrites 16 committed WAVs and is the operator's
> call, not a side effect of building the tool.

The editing math, entirely in Elixir, entirely without a subprocess: parse a WAV
header into `{sample_rate, channels, bits, data}`; splice by millisecond in/out;
fade in/out; peak-normalize; concatenate; render back through `SoundGen`'s
existing header writer. Plus `Studio.import/1` — the one `afconvert` call,
guarded so a missing or failed decode reports "unsupported source" rather than
crashing.
*Acceptance:* a bundled WAV survives parse→render byte-identically; a splice's
sample math is pinned at both boundaries (off-by-one at the out point is the
classic click); a fade lands on true zero; normalize never clips; import of a
44.1 kHz stereo mp3 yields 22.05 kHz mono; import of a text file fails cleanly.

### Phase 2 — The `sound` command surface

New `lib/buster_claw/commands/catalog/sound.ex` — the front door Part V named.
`sound_list` (both layers, showing which wins), `sound_import`, `sound_trim`,
`sound_apply` (write into the library and route a key to it), `sound_delete`.
Read verbs `:safe`; anything writing the library `:restricted`, since a sound
effect is a file the app will later play unattended.
*Acceptance:* a voicemail becomes a routed sound effect end to end, from the CLI
alone, with no UI involved; `Sound.route_keys/0` is the validation source, so a
typo'd key is refused at the verb.

### Phase 3 — The Studio surface (Home sub-tab) — **SHELL SHIPPED 07-31**

> **Reshaped by the operator, 07-31: the Studio is not a fifth tab — it is the
> Music tab, renamed and repurposed.** Sidebar of every audio source down the
> left, the selected one open on the right, tools along the bottom. `"music"` →
> `"studio"` in the tab list, the `select_home_tab` whitelist, and the `:if`.
>
> Shipped: `SoundStudioComponent` with three sidebar groups (Sounds — both
> layers merged, Recordings — voicemails, Music — tracks), and a detail pane
> carrying the waveform, a preview player, and **facts read by
> `SoundStudio.import_source/1` rather than guessed from the filename**: length,
> peak in dBFS, rate/channels, size. 8 new tests; the 23 music-library tests
> kept, re-pointed. 482 web tests green, credo clean.
>
> **All three Part V landmines were live in this phase and all three are
> honoured by construction:**
> 1. Selection lives in `StatusLive`'s `@studio_source`, not the component —
>    pinned by a test that selects, leaves for Chat, returns, and asserts the
>    selection survived. This is the one that demos perfectly and loses real work.
> 2. The preview `<audio>` points at a route; a test `refute`s `blob:`.
> 3. The waveform id is keyed by source id — a test asserts two files produce
>    two ids, because `AudioClip` decodes `data-src` exactly once at mount.
>
> **No music functionality was lost.** The library manager (upload, queue,
> play-all, delete) is the first entry in the Music group and renders
> `MusicComponent` in the detail pane — a rename should not silently delete a
> shipped feature.
>
> **A real bug the tests caught:** `aria-current={boolean}` renders as a *bare*
> attribute in HEEx, but `aria-current` is a token attribute — bare, it is
> invalid ARIA and announces nothing. It needs the explicit `"true"`.
>
> **Second pass, same day — import, a folder, and the blur:**
>
> - **`<workspace>/studio/` is a new folder, deliberately NOT `sounds/`.** That
>   one is the effects library, where a file overrides a bundled chime *by
>   basename* — so importing a three-minute voicemail into it would silently
>   enlist that recording as `voicemail.wav`. `studio/` holds raw material;
>   `sounds/` holds finished effects; "save as chime" is the deliberate step
>   between them. Created at boot with a README beside the other `ensure/0`
>   calls, so it is visible in the Workspace tab and in Finder.
> - **The import gate is a DECODE, not an extension.** `SoundStudio.store/2`
>   runs `import_source/1` before writing anything, so the studio only ever
>   holds files it can actually edit — a `.wav` full of prose is refused at the
>   door instead of becoming a sidebar entry that breaks on selection. Pinned
>   by test, along with hostile-name reduction and `-2` collision suffixes.
> - **`/studio/file/:name` goes through `RangeResponse`**, not a bare
>   `send_file` — imported material is long enough to scrub, and `RangeResponse`
>   is also the only thing in the app that sends `nosniff`, which matters most
>   exactly here, on bytes the user just handed us (see the LEFTOVERS item).
> - **The blur is `ic-panel`**, not a bespoke class: on the homepage,
>   `.ic-home .ic-panel` is already 70% base-100 with a 10 px backdrop blur —
>   the same frosted treatment the chat panel gets.
> - Landmine 3 was live again and is honoured again: the picker takes `audio/*`,
>   never `SoundStudio.accepted_extensions/0`, because `.m4a` has no registered
>   MIME type and passing the real list raises **on mount**.
>
> **Third pass — the Sounds group is OUR SET, and a bug underneath it:**
>
> - **`Sound.bundled_list/0` was returning 32 entries, not 16.** `mix
>   phx.digest` writes a content-hashed copy of every static asset beside the
>   original (`alarm.wav` → `alarm-85cf46bf….wav`), and the listing counted
>   both. That filled the Studio sidebar with what reads as system junk **and
>   had been doubling the routing menu in Settings → Notify since Phase 0** —
>   `alarm-85cf46bf….wav` was a selectable routing target. Now filtered by shape
>   (`-<32 hex>` before the extension), which is safe because we author every
>   byte in that directory, and unlike a hardcoded list of sixteen names it
>   cannot silently drop a seventeenth chime.
> - **The sidebar lists the `sounds/` folder plus any built-in not yet copied
>   into it**, deduped by basename and marked `yours` or `built-in`. It briefly
>   listed only the canonical sixteen, on the theory that stray audio was the
>   clutter — wrong diagnosis, corrected the same day. The clutter was entirely
>   the digest duplicates; the operator's own files (a Wilhelm scream, a bongo
>   hit) are exactly the raw material this tab exists to cut up.
> - **`Sound.install_bundled/0`** puts the set on disk so it is editable and
>   visible in Finder. **Offered, never automatic**: Part III rule 1 forbids
>   *seeding*, and that reason still holds — a copy that reappears at boot is
>   how "delete that sound" becomes a bug report. The operator asking once is a
>   different act from the app deciding, and the button retires itself when
>   nothing is missing. It never overwrites, so a restore cannot clobber an
>   edit. Pinned by a test asserting `ensure/0` does **not** seed.
> - Consequence, and a good one: once a chime lives in the workspace, deleting
>   it there falls back to the bundled copy — so "delete my edit" is a
>   restore-to-default rather than a hole.
>
> 17 component tests, 33 core tests. **Full suite 1972 green.**
>
> **Fourth pass — the trim tool:**
>
> - **A DOM overlay, not shader work** — Risk 2 said to try that first, and it
>   held. Four absolutely-positioned divs (two shades, two edges) over the
>   existing canvas; `clipwave.js` was never touched. The overlay sits under
>   `phx-update="ignore"` because the hook owns its inline styles outright — a
>   LiveView patch mid-drag would snap the selection back to wherever the server
>   last thought it was — so server→client changes (Clear, a new source) arrive
>   as `studio:trim` events instead of re-rendered markup.
> - **The geometry is a bun-tested lib module** (`assets/js/lib/trim.js`), same
>   split as `dtmf.js` and for the same reason: this arithmetic decides what gets
>   cut out of someone's audio. 13 JS tests covering clamping past both edges
>   (which is how "select to the end" works), leftward drags normalizing, the
>   click-vs-drag threshold, and a NaN duration collapsing to 0 rather than
>   handing `NaN..NaN` to a splice.
> - **Trim writes a NEW file** into `studio/` and opens it — design rule 2,
>   read-only in, new file out. Trimming twice keeps both takes (`-trim`,
>   `-trim-2`). A 2 ms/6 ms fade is applied on save: a cut from the middle of a
>   file starts mid-waveform, and that is a step from silence to full amplitude.
>   This is *de-clicking*, not shaping — the fade tool still owes the shaping.
> - **Preview plays the real element and stops early** — no blob, no temp file,
>   no round trip, no new CSP surface.
> - **The trim is parent state**, like the source: it survives leaving the tab
>   (pinned by test) and is dropped when the source changes, because one file's
>   in/out points applied to another's waveform is nonsense.
>
> 25 component tests, 92 JS tests, **full suite 1980 green.**
>
> **Still to come here:** fade, normalize, and save-as-chime — the three that
> are buttons now that a selection exists.



A fifth entry in the `status_live.ex:1066` tab list — **and the matching
`select_home_tab` guard clause at `status_live.ex:322`, which is a whitelist**
(Part V) — plus a `SoundStudioComponent` beside `MusicComponent`. Source picker
(recordings from the Library, sounds from both layers), `clipwave` waveform with
an **in/out selection overlay**, preview of the selection, and "apply to key"
handing off to the routing already built in `NotifySettingsLive`.

Per Part V landmine 2, the working edit — source, in point, out point — is held
in **`StatusLive`'s assigns**, not the component's.
*Acceptance:* select a region of a voicemail by dragging, hear only that region,
apply it to `voicemail`, and have it ring on the next inbound call — without
touching the CLI or Settings. **Then: make a selection, switch to Chat, come
back — the selection is still there.** The tab is opened in tests by clicking
the real button, not by asserting the button exists.

### Phase 4 — The chime designer

`SoundGen`'s tone-spec language as an editor: frequency, onset, duration,
amplitude, octave partial — the five fields `tone/5` already takes. Live render
on change, preview, save to `<workspace>/sounds/` plus the spec JSON. The
shipped 16 load as starting points, so tuning an existing chime is the common
path rather than starting from a blank canvas.

**Preview goes through WebAudio, not a `blob:` URL** (Part V landmine 1) — the
spec is small enough to render client-side into an `AudioBuffer` on every nudge,
which is both the CSP-legal path and the only one fast enough to feel like an
instrument. `dtmf.js` is the precedent.
*Acceptance:* nudging a bundled chime's frequency and saving overrides it with
no routing change (basename override); reopening the design restores the spec;
a spec that would clip is refused or auto-attenuated, not written.

### Phase 6 — The multi-lane arranger — **SHIPPED 07-31**

> **Operator scope, 07-31:** create a track, add clips to it, move them around.
> Several stacked lanes; free positioning on a time ruler; no trimming inside a
> track yet.
>
> `Notifications.StudioTrack` — lanes, clips, and one JSON file per track under
> `<workspace>/studio/tracks/`. `SoundStudio.mixdown/1` places clips at
> millisecond offsets and **sums** them, which is the difference between an
> arrangement and `concat/1`: two clips at the same offset are heard together,
> which is the entire reason lanes exist. 19 track tests, 8 mixdown tests, 13
> component tests, 12 JS tests. **Full suite 2018 green.**
>
> **Decisions that carry weight:**
>
> - **A clip stores a catalog id, never a path or bytes.** An arrangement stays
>   small and diffable, survives its sources being re-edited, and a source that
>   *vanished* is a clip reporting itself missing rather than a track that will
>   not open. `duration_ms` is cached for layout only — a render re-reads the
>   real file, so a stale cache changes how wide a block draws, never what you
>   hear.
> - **A missing source fails the whole render, loudly.** Quietly dropping the
>   clip would produce a mix that sounds finished while missing a layer, and
>   nobody would know what was lost.
> - **A cross-lane move is a pop and a re-add**, not an in-place mutation —
>   doing it as one operation is how a clip ends up on two lanes at once.
>   Pinned by a test asserting exactly one copy survives.
> - **The open track is read from disk, and every mutation writes straight
>   back.** That makes Part V landmine 2 a non-issue here *for free*: the
>   component being discarded on a tab switch costs nothing, because the
>   arrangement was never only in memory.
> - **Layout maths lives in Elixir, pointer maths in JS**, with no overlap. The
>   ruler length, tick marks, and every clip position are server-rendered; the
>   hook is told only the ruler length. The first cut of `arrange.js` had
>   `viewMs`/`positionPct`/`ticks` too — the same formulas in two languages,
>   free to drift — and they were deleted before they could.
> - **The mix clamps.** Four sounds at −6 dBFS on the same beat sum past full
>   scale; `normalize/2` afterwards is the honest fix, which is why the arranger
>   offers Render and not silent attenuation. Pinned by a test that would catch
>   a wrap as a full-scale sign flip.
> - **A five-minute ceiling** on a render: the mix is assembled as integer
>   lists, so length is memory, and a clip dragged to the far end of a ruler
>   should report rather than swap the machine to death.
>
> **A real bug the tests caught:** a hook's `pushEvent` goes to the parent
> LiveView, not the live_component that rendered it — so `move_clip` would have
> crashed `StatusLive` with a `FunctionClauseError` on the first real drag.
> Fixed with `phx-target` plus `pushEventTo`. (`WaveTrim` pushes to `StatusLive`
> *by design*, because the trim state lives there — the two hooks differ on
> purpose, not by accident.)
>
> **Not built, deliberately:** trimming inside a track (operator deferred), clip
> gain, and drag-from-the-sidebar. Adding a clip is a plain form, because one
> control that always works beats a gesture that only works from certain rows.

### Phase 7 — Arranger keybindings: copy, paste, undo — **SHIPPED 07-31**

> **Operator scope, 07-31:** copy/paste and undo. Undo covers arranger actions
> only; copy/paste acts on clips, which required a selection model first.
>
> `⌘Z` / `⇧⌘Z` (and `⌃Y`) undo and redo · `⌘C` / `⌘V` copy and paste a clip ·
> `⌫` removes the selected one. Undo and redo are buttons too, because a
> keyboard-only feature is an invisible one and the stack depth needs somewhere
> to show. 10 component tests, 8 JS tests. **Full suite 2028 green.**
>
> **Selection had to exist first.** Clips were draggable but not selectable —
> `pointerdown` started a drag, full stop. Now a press that moves less than 4 px
> is a *click* and selects; anything more is a drag. That threshold is in
> `arrange.js` with the rest of the pointer maths, because a selection that only
> works if you hold perfectly still feels broken.
>
> **This also fixed a gap:** `remove_clip` had existed since Phase 6 with **no
> UI trigger at all** — a clip could be added and moved but never removed.
> Selection plus `⌫` is its first reachable caller.
>
> **Scoping the chords is the whole difficulty.** These are OS-level bindings,
> so two guards keep them from stealing anything: the hook is mounted *inside*
> the arranger, so nothing binds `⌘Z` anywhere else in the app; and typing
> contexts are excluded, because `⌘Z` in the "New track…" field must undo your
> typing. That predicate was already written for the music player's Space
> handling and is now shared as `lib/keys.js` rather than copied — two copies of
> "is the user typing?" drift, and the failure is quiet.
>
> **Undo rewrites the file, not the screen.** Every arranger mutation already
> writes straight to disk, so undo restores a previous arrangement *and saves
> it*. The stacks live in `StatusLive` (bounded at 50) because an undo history
> that evaporates when you glance at Chat reads as the feature being broken. A
> new edit after undoing abandons the redo branch — the standard contract, and
> the alternative lets redo overwrite work done since.
>
> **Two behaviours worth keeping:** the clipboard holds a *spec*, not the clip,
> so a paste is a genuinely new clip with its own id that can be moved and
> deleted independently; and re-selecting the already-open source is now a
> no-op, because without that guard clicking the open track threw away its undo
> stack.
>
> **The bug this shipped with, found by the operator within the hour — and the
> testing lesson under it.** Clicking a clip never selected it in a browser, so
> copy and paste did nothing while undo worked fine. Cause:
> **LiveView resolves a hook's `pushEvent` against the `phx-target` on the
> hook's own element.** The arranger carries one so `move_clip` reaches the
> component — which makes *every* event from that hook component-bound, whether
> or not it wants to be. `select_clip` was handled only in `StatusLive`, so each
> click hit a `FunctionClauseError`. The fix is to receive it in the component
> and forward it up.
>
> The tests missed it because **`render_hook(view, ...)` addresses the LiveView
> directly and skips `phx-target` resolution entirely** — it cannot see this
> class of bug by construction. Worse, the honest failures were there first: the
> original tests crashed with exactly this error, and switching them to
> `render_hook(view, ...)` "fixed" them by making them stop testing the real
> path. **Drive a hook event through `element(...) |> render_hook(...)`**, which
> resolves the target the way a browser does. The tests now do.
>
> **A test bug worth recording:** `~r/phx-click="studio_undo"[^>]*disabled/`
> matched the Tailwind class `disabled:opacity-30`, which is on the button in
> *both* states — so the assertion could never fail correctly. Match the bare
> attribute, not a substring that a class name also contains.

### Phase 8 — The DAW day: identity, color, and a transport — **SHIPPED 08-01**

> **Operator scope, 08-01, arriving in six pulls over one session:** rename to
> DAW vocabulary; Pro Tools-style control clusters left of each track; New
> audio / Import audio inline with the home tab bar; blue and green joining
> the hazard orange; mute and solo; and a way to hear the edit before
> rendering it.
>
> Six commits, `0e1cf1a` → `208f7c9`. 54 component tests, 27 schema tests, 120
> JS tests across 11 suites at close.
>
> **The vocabulary swap ran through the whole stack** — module, struct,
> events, hook params, tests — with the v1 disk format as the one deliberate
> exception (see the banner at the top). Leaving code where "track" meant the
> opposite of what the UI says would have made every future Studio session
> start with a translation table.
>
> **The Pro Tools shape, and the geometry rule under it.** Each track is a
> left control cluster (label, M, S, delete — the color strip too) beside a
> clip region. `[data-track]` is ONLY the region, never the row: the drag
> hook divides pointer X by that rect, and a row-wide rect would land every
> drop early by exactly one cluster width. The ruler gained a matching spacer
> for the same reason. "+ Track" sits under the stack — where the new row
> appears is where the button is — and disables at the cap instead of
> silently no-opping.
>
> **The tab bar's right side is an action slot.** New audio and Import audio
> render there (a stateless `toolbar/1` function component in `StatusLive`'s
> row), reaching the live_component via a `phx-target` **selector**
> (`#studio-panel`) and a client-side `JS.dispatch` click on the hidden file
> input. Imports switched to `auto_upload` to make the button honest:
> choosing files IS the import — a second submit hidden in a sidebar would
> have been a trap from a toolbar.
>
> **Color is a language with two axes.** Tracks cycle a three-color palette
> (`#FF4D1C` / `#1C9BFF` / `#2FD068`) as *identity* — cluster strip, label,
> clips — hanging off the **label letter**, not the list position, so a color
> survives its neighbor's deletion (pinned by test). The detail pane's
> waveform takes the same triad by source *kind* (sounds hazard, imports
> blue, music green; recordings deliberately share hazard), with the kind
> badge tinted to be its own legend. **Hazard alone still means attention**:
> selection ring, drag target, trim edges. Logged in the design-identity
> memory as a scoped exception to the single-accent rule.
>
> **Mute and solo are the DAW contract, exactly:** any solo → only soloed
> tracks sound; otherwise everything unmuted sounds; **solo beats mute on the
> same track** (the Pro Tools/Logic resolution, pinned by a test named for
> it). The render mixes `audible_clips/1`, silenced regions dim to 40%, and
> all-clips-silenced gets its own refusal — "unmute or solo something first"
> — because "add a clip" would be a wrong diagnosis. Flags persist as
> `"muted"`/`"soloed"` in the v1 entries, read with `== true` so a
> hand-edited `"muted": "yes"` is ignored rather than honored.
>
> **The transport (Play) is the Pro Tools model:** press Play and the
> timeline sounds; Render stays the bounce. The DOM is the score — the server
> renders each clip's `data-src` (the same route the sidebar plays) and each
> region's `data-audible` (carrying `audible?/2`, so mute/solo are read by
> JS, never recomputed) — and the `StudioAudition` hook schedules decoded
> buffers on one AudioContext clock, sweeping a playhead by rAF. Stopping
> closes the context, which silences everything with zero node bookkeeping;
> the hook is keyed by the open audio so switching arrangements can never
> leave a stale score sounding. Two divergences from Render, both toward
> usefulness: a vanished source is *skipped* by Play but still *refuses*
> Render, and WebAudio sums floats where the render saturates int16 — audible
> only in a mix already clipping. Scheduling maths is pure (`lib/audition.js`,
> 10 tests), per the house split.
>
> **Testing lessons paid for today:** a page-wide `=~ "opacity-40"` assertion
> can never fail — that class styles disabled buttons all over the app; scope
> to `[data-track].opacity-40`. And the double-hyphen guard pattern from the
> morning repeated its lesson here in miniature: every guard needs a passing
> input tested, not only a failing one.
>
> **Phase 5's packaged walk grew a clause:** the transport is a
> click-initiated AudioContext, which should pass WKWebView's autoplay
> policy — but "should" is exactly what that walk exists to verify.

### Phase 5 — The packaged-app walk — **acceptance MET 08-01; autoplay note open**

`SOUND_ROADMAP` Risk 2: confirm the Tauri webview's actual autoplay posture, and
confirm the studio's `afconvert` shell-out works inside the sandboxed packaged
app — a system binary is present, but the app's entitlements decide whether we
may execute it. **This is the phase most likely to surprise us**, which is why
it is named rather than assumed.
*Acceptance:* import works in a packaged build, or the entitlement gap is
documented with a decision.

> **08-01, operator walk of the packaged 0.1.0 bundle: "import audio works
> great" — `afconvert` executes under the packaged app.** The acceptance
> criterion is met; the phase's scary half is dead. What the walk surfaced
> instead: a 20-minute import showed *length unknown / too large to analyse* —
> the 8 MB inline-decode cap nulled every fact. Fixed same day: facts over the
> cap now header-probe via `/usr/bin/afinfo` (afconvert's O(header) sibling),
> so length and format always render and trim keeps its duration; only peak
> stays unmeasured. Still to observe, with the R1 QA pass: the autoplay
> posture note, and a seek test on a long track (the byte-range LEFTOVER).

---

## Part V — Inherited findings (already paid for, once)

Harvested from `MUSIC_ROADMAP` and `SOUND_ROADMAP` when they were archived. These
are not general wisdom — each one is a specific trap this build's design walks
into, with the phase it hits.

### The three landmines

**1. `blob:` URLs are forbidden in production — and fine in dev.** *(Music
Finding 3 → Phases 3 and 4.)* `content_security_policy.ex` declares no
`media-src`, so media falls back to `default-src 'self'`, which — unlike
`img-src` — does **not** include `blob:` or `data:`. The obvious way to build
"preview my edit before saving" is to render the edit in JS and hand `<audio>` a
`blob:` URL. That is blocked in the shipped app. And because CSP is Report-Only
in dev and enforced only in `config/prod.exs`, **it works perfectly through the
entire build and fails only in the packaged artifact.**

Two legal channels, both already in use here:
- **Serve the preview from a route** (through `RangeResponse`, which also sends
  `nosniff` — see below). This is the `MusicController` posture.
- **Play it through WebAudio with no URL at all** — `decodeAudioData` on fetched
  bytes, or synthesized oscillators. `dtmf.js` already makes sound this way, and
  `clipwave.js` already decodes fetched audio. `media-src` never enters into it.

The second is the better fit for the designer's live re-render on every slider
nudge — no round trip, no temp file, no CSP surface.

**2. `:if` deletes the tab's DOM, and the component's state with it.** *(Music
Finding 2 → Phase 3.)* Home sub-tabs render as `<div :if={@home_tab == "music"}>`
(`status_live.ex:1117`), and `:if` **removes** the DOM rather than hiding it. A
`live_component` that stops being rendered is discarded, state included. Music
escaped this by moving the player into the sticky dock; **the Studio cannot** —
an editor does not belong in the dock beside a transport.

So the rule for Phase 3: **in-progress edit state lives in `StatusLive`'s
assigns, not in `SoundStudioComponent`.** Source, in/out points, and the working
tone spec must survive the tab being switched away and back. This fails in the
direction that looks like it works — the tab demos perfectly, and you lose an
edit the first time you glance at Chat. *A playing preview stopping on tab-switch
is accepted and correct; a lost selection is not.*

**3. `allow_upload`'s `:accept` raises on mount for `.m4a`.** *(Music Phase 4 →
Phase 3.)* LiveView's `:accept` only takes extensions the `mime` package has a
registered type for. `.m4a` has none, so passing an extension list containing it
**raises during mount and the tab does not render at all.** If the Studio grows
an import picker, it takes `audio/*` and `Studio.import/1` stays the real gate —
which is the right shape anyway: a file the picker allows gets a *reason* from
the server, a file it blocks is one you cannot even try.

### The rest

| Finding | Source | Applies to |
|---|---|---|
| **Calling a resolver inline in HEEx is permanently stale.** `Sound.resolved(key)` in a template only re-renders when a *tracked assign* changes; `row` never changed, so every row resolved once, at mount. Materialize into an assign. | Sound Phase 2 | Phase 3 — the Studio will show "this key currently resolves to X" and is the same shape exactly. |
| **Key the waveform container by source.** `AudioClip` decodes `data-src` **once, at mount**; a fixed DOM id freezes the wave on the first file forever. | Music Phase 5 | Phase 3 — the Studio switches source constantly, and must also redraw after a trim, so the id keys on source *and* edit revision. |
| **`select_home_tab` is a whitelist guard** (`status_live.ex:322`) — a tab button with no matching clause is a silent no-op. Test by clicking the real button, not by asserting it exists. | Music Phase 4 | Phase 3 — the exact line this build edits. |
| **Never seed the workspace.** A boot-time copy resurrects files the operator deleted, which is how "delete that sound" becomes a bug report. | Sound Part III.1 | Phases 1–4 — the Studio writes on explicit save only. |
| **Sanitize wider than `Sound` does, and pin it with hostile names.** `safe_name/1` read the extension from a *trimmed* basename while `store/2` read the *original*; `"   .mp3"` trims to `".mp3"`, which Elixir reads as a dotfile with no extension — so an upload succeeded, landed as `track`, and `list/0` ignored it. Success message, no file. | Music Phase 2 | Phases 1–2 — every file the Studio writes. Reuse `Music.safe_name/1` and `available_name/1` rather than re-deriving. |
| **Probe test databases through real tests.** `MIX_ENV=test mix run -e` runs with **no sandbox** and commits straight into `buster_claw_test.db`, failing unrelated tests on state nothing in the suite wrote. | Sound Phase 2 | All phases — a diagnostic habit, not a design. |
| **An accepted format that will not play is worse than a rejected one.** WKWebView's codec support is not Chrome's. | Music Risk 2 | Phase 1 — **largely dissolved here**: `afconvert` normalizes everything to PCM16 WAV at import, so the Studio only ever plays back its own format. Import breadth and playback breadth are decoupled. |
| **`RangeResponse` sends `nosniff`.** Pipeline-less media routes get no secure-browser headers and no CSP. | Music Part VII | Phase 3 — any preview route the Studio adds goes through `RangeResponse` to inherit it, rather than a bare `send_file`. |

---

## Part VI — Risks

1. **The packaged sandbox may refuse the subprocess.** Everything above rests on
   being allowed to run `/usr/bin/afconvert` from inside the app bundle. Phase 5
   tests it, but Phase 1 should keep `import/1` behind a single function so the
   fallback — decode in the browser via WebAudio, which `clipwave.js` already
   does at `decodePeaks`, and upload the PCM — is a swap rather than a rewrite.
   *That fallback is the reason this risk is survivable: the client can already
   decode everything the server can.*
2. **`clipwave` was built to display, not to interact.** It renders an envelope
   texture with no notion of a cursor or a selection. The likely answer is a DOM
   overlay above the canvas rather than shader work, and Phase 3 should try that
   first before touching WGSL.
3. **Scope gravity.** The designer is the most fun part and the least necessary
   one, which is exactly how a studio becomes a six-week DAW. It is Phase 4
   deliberately: the splicer earns its keep on real voicemails first.
4. **Sound fatigue, still.** Making sounds easier to author makes it easier to
   over-sound the app. The Never list in `SOUND_ROADMAP` Part II remains a
   decision, not an omission — a studio does not reopen it.
5. **The set has no loudness normalization** (found in Phase 0). Peaks span
   8.6 dB and nothing enforces a relationship between them, so a re-tuned or
   operator-supplied chime can land far louder than its neighbours with no
   warning. The studio *creates* this problem at scale — every sound it writes
   is a new peak nobody balanced. **A peak-normalize step on write (Phase 1
   already builds one) is the cheap structural answer**, and applying it to the
   bundled set would resolve the `order`/`security` inversion as a side effect
   rather than by hand-tuning amplitudes.
