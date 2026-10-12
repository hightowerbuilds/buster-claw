# The cut-up engine — deletion

**Archived 2026-10-11.** VoxCPM has been removed from the working application under [VOX_REMOVAL](../roadmaps/surfaces/VOX_REMOVAL_ROADMAP.md). Native chat speech, existing audio, and phone intake remain. Unfinished synthesis work and recorder walkthroughs below are cancelled, not marked passed. The following is a historical development record.

**Scoped and SHIPPED 09-19-26. One item open: the Vox2B recorder walk (Part IV).**

| Phase | | |
|---|---|---|
| 0 | Retire the shipped skill seed | ✅ `Seed.retire/2`; guard broken on purpose and seen to fail |
| 1 | Delete the Voice Library tab | ✅ `/studio` is Mix alone, and draws no rail |
| 2 | Delete the 18 commands | ✅ 214 → 196, measured from `Catalog.entries/0` |
| 3 | Trim `Capture.Take`, delete the engine | ✅ 379 → 167; 16 modules and 14 test files gone |
| 4 | Copy, docs, counts | ✅ `check_docs_drift.sh` green at 196 |
| 5 | Close the record | ✅ committed 09-19. **Stays live until the Vox2B walk**, then archive |

70 files, **+653 / −20,684**. 38 files deleted whole, and the skill seed moved
to `test/fixtures/retired-seeds/`, where the retirement test needs its exact bytes. `lib/` 102,534 → 91,030
lines. `commands/sound.ex` 2,464 → 1,122, which retires the split the 08-13 and
09-05 reviews both called the headline debt — the Corpus third was deleted
rather than extracted. `mix precommit` green at 3,486 tests, 362 JS tests.

> **Corrected while shipping: the count was 214, not 213.** This map was scoped
> from `SUPERMAP`'s "219 → 213" and the README's 214, which disagreed; the
> catalog said 214. Every number below was then measured rather than derived.

> ### The one-sentence version
>
> **The cut-up engine leaves this repo whole — sixteen modules, eighteen
> commands, the Voice Library tab and the skill that taught them — and Vox2B,
> the Mix tab and every WAV on disk are untouched.**

> ### What forced it
>
> Nothing new. `STUDIO_ROADMAP` was deleted on 09-02 (`5fab0df`) with the
> sentence *"the cut-up engine is its own project now"*, and the code stayed. The
> 09-05 review named the cost: a subsystem with a decided exit and no exit date,
> so the size gate was protecting about fifteen thousand lines whose fate was
> deletion. On 09-19 the operator asked whether it was still here. It was.

---

## Part I — What Vox2B needs, and why it survives

This is the part that had to be established before anything was cut, because
"the voice feature" and "the voice library" share a directory, a recorder and a
word, and are otherwise unrelated.

**`BusterClaw.Voice.*` references no `Cutup` module. Not one.** Its three ties to
the Studio's audio code all sit *below* the engine:

| Vox2B uses | For | Relation to the engine |
|---|---|---|
| `Notifications.SoundStudio.read/1`, `write/2` | WAV parsing (`Voice.Reference`, `Voice.ReferenceQuality`) | the engine imports `SoundStudio`; `SoundStudio` imports nothing of the engine's |
| `Notifications.Capture.Take.decode/2` | turning the recorded reference into a clip | **shared file — see below** |
| the `VoiceRecorder` JS hook (`components/vox/create.ex`) | recording the reference | shared with the Studio recorder; the hook stays |

**The one file that is both.** `capture/take.ex` has two halves. `decode/2`
and the decoding helpers are Vox2B's (`format/0` had no caller left and went
too). `store/3`, `index_for/3`,
`aligned_words/2` and `index/3` are the corpus recorder's, and they are what
alias `Cutup.Align`, `Bank`, `Index` and `Vad`. **Trimmed, not deleted.**

## Part II — The inventory

### Goes

- **The engine.** `lib/buster_claw/notifications/cutup/` — 16 modules, 7,947
  lines — and `test/buster_claw/notifications/cutup/` — 14 files, ~6,100 lines.
- **Eighteen commands**, 214 → 196: `sound_transcript_search`,
  `sound_transcript_words`, `sound_corpus`, `sound_index_list`,
  `sound_index_words`, `sound_index_search`, `sound_index_import`,
  `sound_index_delete`, `sound_align`, `sound_find`, `sound_sentence`,
  `sound_assemble`, `sound_gaps`, `sound_record_save`, `voice_bank_list`,
  `voice_bank_create`, `voice_bank_select`, `voice_bank_delete`.
- **The Voice Library tab.** `components/studio/{recorder,sentence,
  voice_library,words}.ex`, `live/studio/{voice_state,recorder_state}.ex`, and
  `voice_library_test.exs`, `voice_state_test.exs`.
- **`skill-seeds/sound-cutup.md`**, and its copy in existing workspaces —
  Phase 0.

### Stays

- **The Mix tab**, `StudioMix`, `SoundStudio`, `StudioCatalog`,
  `Notifications.Studio.*`, and the `/studio` route. None reference the engine.
  Mix leaving is the spin-off's separate, larger cut and is not this map.
- **`sound_record`** — microphone capture through `ffmpeg`; no engine in it.
- **`voice_recorder.js`** (Vox2B) and **`voice_audition.js`** (Mix's clip
  inspector).
- **Everything on disk.** WAVs and `*.index.json` files under `sounds/studio/`
  are the operator's recordings. They become inert, not deleted.

### `sound_record_save` — deleted, and the argument for keeping it

It could survive without indexing, as "save a take into the studio". It goes
because its only UI caller is the recorder being deleted, and a command kept for
a caller that no longer exists is how the public surface got twice as wide as
its callers (09-05 review).

## Part III — The phases

### Phase 0 — retire the seed, first

`BusterClaw.Seed` upgrades an unedited seed and has **no way to remove one**.
Deleting `sound-cutup.md` from `skill-seeds/` would leave every existing
workspace holding a skill that teaches 24 verbs answering `unknown_command` —
the exact defect the 08-18 BusterPhone cut produced and `G-44` was built for.

The rule is the one `Seed` already uses, pointed the other way: **a file whose
bytes still match a version we shipped is ours to remove; an edited one is the
operator's and stays.** The shipped hash is already recorded in `skills.ex`.

### Phase 1 — the tab
Web first, so the commands and engine lose their callers before they go.
`StudioLive` and `StudioPanel` drop to a Mix-only surface.

### Phase 2 — the commands
`commands/sound.ex` loses roughly 1,260 of 2,464 lines; `sound_delete` keeps its
body and loses its index cleanup. `commands/sound_capture.ex` loses `sound_gaps`,
`sound_record_save` and the four bank verbs. Catalog entries and delegates go
with them.

### Phase 3 — the engine
Trim `capture/take.ex` to its Vox2B half, then delete the directory and its
tests.

### Phase 4 — copy, docs, counts
`Explained.Studio`, the Explained registry, `docs/COMMAND_SURFACE.md`,
`introduction/01` and `09`, the README's command count, `SUPERMAP`.

### Phase 5 — close
`mix precommit` green, numbers recorded here, map archived.

---

## Part IV — What the deletion found

**Four Mix tests went with a tab that was not Mix's.** They proved the
selection, the trim, the clipboard and the undo stacks survive leaving Mix —
which is why that state lives in `StudioLive` and not in the component
`StudioPanel` destroys behind its `:if`. They proved it by switching to the Voice
Library. With one tab there is nowhere to leave to, so the hazard cannot occur
and cannot be tested. **The design stays and the tests are owed back the day a
second sub-tab exists**; `sound_studio_component_test.exs` says so at the spot,
and they are in git at `98cbad8`. Do not move the state into the component
because nothing fails.

**`sound_delete` lost its one refusal.** It refused a source that still had a
word index (`source_indexed`). The index is gone, so the refusal and the
`delete_index` argument are. Index files already on disk are inert.

**The verb-lockstep test got wider, not narrower.** It guarded `sound-cutup`
alone. Rather than delete it with its subject it now covers every seeded skill,
which is what it should have done from the start.

**One thing is unwalked: Vox2B's recorder in the real app.** Its server path
(`Voice.Reference` → `Take.decode/2` → `SoundStudio.write/2`) is untouched code
under green tests, and the hook it shares names its own event
(`reference_take`). But nobody recorded a reference after the cut. Ninety
seconds in Chrome or a packaged build closes it — not the dev shell, where the
mount-time `getUserMedia` crashed the app on 09-13.
