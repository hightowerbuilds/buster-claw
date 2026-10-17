# The Studio, removed

**Scoped 10-16-26, evening.** Operator: *"let's look at the buster claw studio. i
think we want to delete that actually. we don't need that feature."*

> ### The one-sentence version
>
> **The Sound Studio — the Mix editor and arranger at `/studio`, the five
> `sound_*` editing verbs, the four microphone verbs, and the music player that
> lives inside it — is roughly 13,000 lines (code, JS and tests) behind a route
> nothing has linked to since 09-05, and the operator's own workspace has never
> held a studio file. It goes whole; the chime library it was built beside
> stays.**

> ### Read this first
>
> The Studio was the **renamed Music tab** (07-31), so the music player's only
> surface is the Studio's catalog. The `/studio` route lost its dock tab on
> 09-02 and its last link on 09-05 (the Sketch Pad); today the single door is
> the Explained panel's Studio tutorial ("Open"). The dev workspace
> (`tmp/dev-workspace/sounds/`) holds no `studio/` and no `music/`: the feature
> has been shipped and unused. The namespace was moved to `BusterClaw.Studio.*`
> this afternoon (CODE_QUALITY_SWEEP Phase 10); that rename made this
> inventory a directory listing.

---

## Part I — What it is (measured 10-16)

| Piece | Where | Lines |
|---|---|---|
| Core: the WAV editor, mixes, catalog, effects, render, microphone capture | `lib/buster_claw/studio/` (`Editor`, `Mix`, `Catalog`, `Effects`, `Render`, `Capture`, `Capture.{Devices,Level}`) | 3,043 |
| Web: the route, the component, its seven sub-components, the panel + registry, preview, file controller | `studio_live.ex`, `sound_studio_component.ex`, `live/studio/mix_state.ex`, `components/sound_studio/*`, `studio_panel.ex`, `components/studio/registry.ex`, `studio/preview.ex`, `studio_file_controller.ex` | 3,468 |
| Commands: the editing verbs (`sound_import`, `sound_trim`, `sound_fade`, `sound_normalize`, `sound_concat`) and the microphone verbs (`sound_devices`, `sound_input_level`, `sound_input_level_set`, `sound_record`) | `commands/sound/edit.ex`, `commands/sound_capture.ex` | 478 |
| Commands, shared with the chimes: `sound_sources`, the decoded half of `sound_probe`, the studio-source branch of `sound_delete`/`sound_apply`, `Shared.peak_of`/`read`/`internal_format` | parts of `commands/sound/library.ex` (557), `shared.ex` (163), `catalog/sound.ex` (230) | ~250 |
| Music: the library module and the streaming controller (no commands, no other surface) | `music.ex`, `music_controller.ex` | 407 |
| Explained: the Studio tutorial and its registry row | `explained/studio.ex` | 338 |
| JS: eight hooks and three pure libs, the waveform renderer | `hooks/{audio_clip,wave_trim,track_arrange,studio_keys,studio_audition,voice_audition,studio_context_menu,studio_menu_bar}.js`, `lib/{arrange,audition,trim}.js`, `audio/clipwave.js` | 1,487 (+247 tests) |
| Tests | `test/buster_claw/studio/**`, `clip_actions_test`, `sound_studio_component_test`, `studio_live_test`, `studio_panel_test`, `sound_capture_test`, `music_test`, the editing half of `commands/sound_test.exs` (1,308) | ~4,900 |
| Workspace | `sounds/studio/` and `sounds/music/` (on-demand, created by `Editor.ensure/0` and `Music.ensure/0`), the `studio`/`music` → `sounds/*` relocations, `AudioName` (shared) | — |
| Gate rows | 15 entries in `check_file_sizes.sh`; ACL untouched (no Tauri command) | — |

Routes: `live "/studio"` and `get "/studio/file/:name"` (`:media` pipeline,
pinned by `media_nosniff_test`). Catalog: 16 `sound_*` entries today, 2 gated
(`sound_apply`, `sound_record`).

## Part II — The boundary

**Goes:** everything in Part I except the chime library. The Explained Studio
tab (the ninth tile) and its registry row; the route and the file route; the
eight hooks and the waveform renderer; the five editing verbs and the four
microphone verbs; `sounds/studio/`.

**Stays, untouched:** `Notifications.Sound` (the chime library in `sounds/`,
routing, cooldowns), `SoundGen`, `SoundBoard`, `Notify` settings and its
upload (`Sound.install_file`), `AudioName`, the sixteen bundled chimes, and the
chime verbs `sound_list`, `sound_routes`, `sound_apply`, `sound_delete`,
`sound_restore_defaults`.

**Stays, trimmed:** `sound_probe` keeps its header facts (`afinfo`) and loses
the decoded facts (duration, peak) that needed the WAV parser; `sound_sources`
goes (it listed the studio folder); `sound_apply`/`sound_delete` lose their
studio-source branch; `Commands.Sound` loses the `Edit` partition and `Shared`
shrinks to what `Library` still reads.

## Part III — Three decisions for the operator

- **D1 — Music playback goes with it.** The music library has no command, no
  other surface and no door but the Studio's catalog. Default: **delete**
  `Music`, the controller, `sounds/music/` and the relocation. (Keeping it
  would mean building a player somewhere, which is a feature, not a removal.)
- **D2 — The microphone verbs go with it.** `sound_record` lands recordings
  in `sounds/studio/` and nothing else reads them; `sound_devices` and the
  input-level verbs exist to drive it. The 09-13 mic-on-mount crash is one
  more reason not to keep a microphone path nobody uses. Default: **delete**.
- **D3 — `sound_probe` goes header-only.** The alternative is keeping a
  ~300-line WAV reader out of `Editor` for two facts the operator has never
  asked for. Default: **header-only**.

## Part IV — Phases

| Phase | Scope | Gate |
|---|---|---|
| 0 | This map. | — |
| 1 — The surface | Route + file route; `StudioLive`, `SoundStudioComponent`, `MixState`, the seven components, `StudioPanel` + registry, `Preview`, the controller; the eight hooks, three libs, `clipwave.js`, their index entries; the Explained tab + registry row + `@built`; the Studio's tests (web). | `mix precommit`; the catalog count and `@command_stats` re-measured; `explained_audit_test` stale-list gains `Studio`, `Mix tab`, `/studio`, `sound_import`, `sound_record`; the nosniff test drops the studio row. |
| 2 — The verbs | `commands/sound/edit.ex`, `sound_capture.ex`, the catalog entries, the studio branches in `Library`/`Shared`; `commands/sound_test.exs` loses its editing half; `sound_capture_test`. | precommit; CLI `./buster-claw run sound_list` still answers; `sound_probe` header-only pinned. |
| 3 — The core | `lib/buster_claw/studio/` whole and `test/buster_claw/studio/`; (D1) `Music` + controller + `music_test`; `sounds/studio` and `sounds/music` leave `Workspace` (the `sounds` entry's note, the relocations, `workspace_test`'s two cases); `AudioName`'s doc. | precommit; **boot the dev app and read the seed log** (D1 of the sweep: seed registries run at boot); `check_cycles.sh` still 2; 15 gate rows removed with reasons. |
| 4 — The record | SUPERMAP row; memory (`sound_studio_roadmap`, `music_roadmap_status`, `studio_corpus_roadmap` → DELETED, don't rebuild); the Explained `@command_stats`; the Manual if it names the Studio; `scripts/README.md`'s `gen_sounds` line stays (SoundGen stays). | the explained audit reads the rendered pages. |

Deletions first, by file; the compiler finds the stragglers
(`--warnings-as-errors`). After Phase 3, `refs_scan.py` for anything the
Studio was the last caller of (`AudioName.*`, `Sound.rename_file/5`'s second
caller, `RangeResponse` if the music controller was its last user).
