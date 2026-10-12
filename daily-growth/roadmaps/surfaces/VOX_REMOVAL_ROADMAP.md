# VoxCPM removal roadmap

**Implemented and automatically validated 2026-10-11. Manual audio/phone checks remain below. No release has been published.**

Remove VoxCPM from Buster Claw: the Vox2B surface, reference recording, speech generation, render queue, and commands that create or manage generated phrases. Buster Claw no longer discovers, configures, or operates this engine.

The removal keeps macOS chat read-aloud, ordinary notification sounds, Studio Mix, music playback, and BusterPhone. Existing recordings and generated audio remain the operator's files. A separate voice application is not a prerequisite, and this work adds no replacement engine, plugin, or service connection.

This decision supersedes the unfinished work in [VOICE](../../archive/VOICE_ROADMAP.md), [VOX_TAB](../../archive/VOX_TAB_ROADMAP.md), and [VOX_FROM_CHAT](../../archive/VOX_FROM_CHAT_ROADMAP.md). The recorder walkthrough left by [CUTUP_DELETION](../../archive/CUTUP_DELETION_ROADMAP.md) is superseded by this removal, rather than counted as a passed acceptance test. [SUPERMAP](../SUPERMAP.md) tracks the removal. The four superseded development maps are archived; their unperformed recording and phone walkthroughs are not counted as passes.

## Scope and surviving features

VoxCPM and macOS speech are separate implementations. Deleting every file whose name contains `voice` would remove working chat speech and the phone webhook as well as VoxCPM.

| Area | Outcome |
|---|---|
| Home → Vox2B, its tutorial, engine setup and quality controls | Remove |
| Reference recording, cloning, phrase generation, chime generation, spoken-message management | Remove |
| Seven `voice_clip_*` and `voice_message_*` commands | Remove from all command entry points |
| macOS chat read-aloud and its voice and speed preferences | Keep; move the picker to Configuration → Speech |
| Notification routing and playback of installed WAVs | Keep in Settings → Notify |
| Studio Mix, music, WAV editing and import, `sound_record` | Keep; these do not require VoxCPM |
| Existing published phone greeting and the phone service's default greeting | Keep; move custom-greeting status and reset to Phone |
| Workspace audio, manifests, saved preferences, external model installations | Preserve; no automatic deletion or uninstall |

## Code inventory

Paths below are relative to the repository root. This inventory records the deletion boundary; named removed files are historical paths.

| Area | Files and integration points | Change |
|---|---|---|
| Synthesis | `lib/buster_claw/voice/{engine,renderer,config,calibration,reference,reference_quality,clips,messages,chimes,greeting}.ex` | Delete these ten modules after the surviving phone controls have moved |
| Chat speech | `lib/buster_claw/voice/speech.ex`, `assets/js/hooks/voice.js`, `assets/js/lib/voice.js`, `desktop/tauri/src/voice.rs` | Retain; `Speech` prepares reply text for the native synthesizer |
| Runtime | `lib/buster_claw/application.ex` | Remove the `Voice.Renderer` supervisor child |
| Home host | `lib/buster_claw_web/live/status_live.ex` | Remove the `vox` tab, component ID, renderer subscription, render-result relay, and Vox task-result forwarding |
| Vox UI | `lib/buster_claw_web/live/{vox_component,voice_live}.ex`, `lib/buster_claw_web/components/vox/` | Move `reading.ex` into a neutral Speech settings component; delete the rest |
| Routes and tabs | `lib/buster_claw_web/router.ex`, `lib/buster_claw_web/components/layouts.ex`, `assets/js/lib/tabs.js` and tab-layout handling | Retire Vox links and labels; handle saved `/voice` tabs without a blank app |
| Voice media | `lib/buster_claw_web/controllers/voice_audio_controller.ex`, `/voice-audio/:name` | Delete the dedicated controller and route; keep generic workspace and notification media paths |
| Commands | `lib/buster_claw/commands.ex`, `lib/buster_claw/commands/notify.ex`, `lib/buster_claw/commands/catalog/notify.ex` | Remove the seven commands; retain the `notify_*` commands |
| Agent instructions | `lib/buster_claw_web/live/status/chat.ex`, `Voice.Clips.guide/0`, `introduction/` | Stop teaching agents to render voices or open Vox2B |
| Recorder | `assets/js/hooks/voice_recorder.js`, its registration in `assets/js/hooks/index.js`, `assets/js/lib/meter.js`, `lib/buster_claw/notifications/capture/take.ex` | Delete with their dedicated tests: the reference recorder is their only remaining production consumer |
| Tutorials and styles | `lib/buster_claw_web/components/explained/{vox,registry}.ex`, `lib/buster_claw_web/components/explained_panel.ex`, `.ic-vox*` in `assets/css/app.css` | Remove Vox-specific content and styles; restyle the moved speech controls independently |
| Phone | `lib/buster_claw/telephony/relay.ex`, Phone components, `supabase/functions/voice/index.ts` | Keep published audio playback and fallback; remove dependencies on render configuration |

The current [`PaneRoutes`](../../../lib/buster_claw_web/pane_routes.ex) whitelist already excludes `/voice`, despite older VoiceLive documentation describing it as a split pane. Preserve that boundary and test old saved split URLs as well as standalone tabs.

`VoiceRecorder` and `Capture.Take` were once shared with the cut-up recorder. That engine left in September; `Voice.Reference` was their final production consumer before this removal. The recorder's `meter.js` helper also had no other production import. `VoiceAudition`, `SoundStudio`, and the remaining `Notifications.Capture` modules still have independent uses and stay.

## Existing data and compatibility

| Existing state | Upgrade behavior |
|---|---|
| `sounds/voice/*.wav`, `sounds/voice/reference/`, `clips.json`, `messages.json` | Leave bytes and paths intact. Files remain accessible through the workspace and filesystem; manifests become historical data |
| Installed `sounds/message-*.wav`, `sounds/clip-*.wav`, and spoken chimes | Keep them in the ordinary sound library with their current routing |
| Pending notifications with `metadata["sound"]` or `metadata["voice_message"]` | Continue firing. Retain the generic per-notification sound override and missing-file fallback in `Notifications.Sound.for_notification/1` |
| `voice_engine_config`, `voice_calibration`, `voice_chime_lines`, `voice_greeting_text`, `voice_greeting_published_digest` in Settings | Leave inert values in place. Do not add a destructive migration solely to remove unused keys |
| macOS voice choice, rate and enabled state in browser localStorage | Preserve the existing keys and values when moving the picker |
| Remote `greeting/greeting.wav` | Leave published audio alone. Phone exposes its status and an explicit reset to the service's default greeting |
| `~/.buster-claw/voxcpm`, an explicitly configured executable, model caches and weights | Leave outside-app installations alone. No installer, boot task or update routine removes them |

VoxCPM was bring-your-own, as implemented by the removed `Voice.Engine`. Removing its integration should not be reported as reclaiming model-weight space from the application bundle.

No audio export is needed to keep these files. A future standalone voice tool can accept copies of the recordings and manifests. Buster Claw's existing `sound_import` and `sound_apply` remain the boundary for bringing an externally produced WAV back as an ordinary sound.

## Implementation phases

The implementation followed these boundaries across backend, UI and documentation work. The checklist records automated evidence separately from remaining manual device checks.

### Phase 0 Establish the upgrade fixtures

- [x] Recheck the inventory and record current command totals from `Commands.Catalog.entries/0`; the catalog is authoritative.
- [x] Prepare an isolated workspace with a reference recording, rendered clip, both manifests, an installed message sound, routed spoken chimes, and a pending notification using that sound.
- [x] Include existing speech preferences and saved standalone and split tabs containing `/voice`.
- [x] Represent published, absent, and unavailable phone-greeting states with relay test fixtures. Do not contact or change a live phone number to build a test fixture.
- [x] Establish that the survivor tests pass before changes, including chat speech, notification playback, WAV import, Mix, and phone intake.

**Exit:** representative existing state is covered, so deletion cannot pass solely on an empty installation.

### Phase 1 Move the independent controls

- [x] Move the native voice picker and rate controls out of `Vox.Reading` into Configuration → Speech, using the existing Settings registry, rail and render dispatch. Keep `VoicePicker`, `VoiceBridge`, `VoiceToggle`, native speech commands and localStorage behavior.
- [x] Move the speech assertions in `test/buster_claw_web/live/voice_live_test.exs` to the new settings surface and update `test/buster_claw_web/components/voice_picker_lockstep_test.exs` to read its new template path. Keep the hook-to-markup contract covered.
- [x] Put custom phone-greeting status and reset in Phone. Use the existing relay status/delete operations without calling `Voice.Config`, `Renderer`, or a synthesis-dependent digest.
- [x] Show an unavailable relay as unavailable, not as proof that no greeting exists. Keep reset operator-initiated with the existing confirmation behavior.
- [x] Keep notification sound routing in Notify and remove its link to Vox's spoken-message panel.

**Exit:** the retained settings are usable without mounting VoxComponent. Published audio still plays; no cloud deployment or automatic unpublish is required.

This phase does not add a new greeting editor or WAV uploader. Remove `Relay.upload_greeting/2` if its last production caller leaves with Vox; retain the operations needed to inspect and reset an existing greeting. A future upload feature is separate work.

### Phase 2 Remove the Vox surface

- [x] Delete the Home tab, VoxComponent, generation panels and Explained tutorial. Remove Vox-specific CSS and UI labels.
- [x] Remove Home's renderer subscription and result forwarding. Check ownership of the broad `{ref, result}` task clause before removing it; preserve any unrelated task handling.
- [x] Replace `/voice` with a small redirect to `/settings?tab=speech`, so old bookmarks reach the retained controls. It must not mount any Vox code.
- [x] Normalize saved `/voice` app tabs to the new destination and label; ensure a stale Home sub-tab falls back to Chat. Invalid legacy split panes must recover visibly without crashing or closing their other pane.
- [x] Remove `/voice-audio/:name` and its controller. Old media links return an ordinary 404; do not replace the allowlist with an unrestricted file-serving endpoint.
- [x] Delete the now-unused recorder hook, meter helper and their dedicated JS tests. Keep the PCM decoder until `Voice.Reference` leaves in Phase 4, so intermediate commits still compile. Keep generic recording, audition, playback and audio editing code.
- [x] Retire generation-specific LiveView/controller tests with their subjects and update shared Home-tab order, Pockets, tutorial, form-submit, remote-notice and hook-registration expectations. Keep coverage for the surviving features.

**Exit:** no navigation, page, hook or stylesheet exposes the Vox product, and saved tabs cannot blank the application.

### Phase 3 Remove commands and agent guidance

Remove these exact commands from catalog entries, delegates and implementations:

| Clips | Spoken messages |
|---|---|
| `voice_clip_make` | `voice_message_create` |
| `voice_clip_list` | `voice_message_list` |
| `voice_clip_delete` | `voice_message_fire` |
| | `voice_message_delete` |

- [x] Remove `Clips.guide/0` from chat's system prompt and replace its positive lockstep test with a guard against advertising removed commands.
- [x] Update the introduction, Manual, command documentation, README, tutorial registry and command-count snapshots in the same change. Derive the new total from the catalog; do not assume the checkout stayed at an old count.
- [x] Verify CLI/API discovery and the surviving MCP-tier API token omit the commands and receive the standard unknown-command response. The separate MCP server was removed before this work.
- [x] Regenerate the machine-owned workspace introduction on upgrade through its existing path. Inspect seed content for old instructions; if a shipped seed needs updating or retiring, use `Seed`'s version-aware behavior and preserve user-edited files.

No dedicated Vox skill seed is present in the current `skill-seeds/` directory. Do not invent a seed-retirement migration; add one only if the implementation-time audit finds an actual shipped seed.

**Exit:** neither discovery nor newly generated agent instructions promise voice generation. Historical transcripts and user-authored notes remain intact.

### Phase 4 Delete the engine integration

- [x] Remove the ten synthesis modules in the inventory and their dedicated tests. Retain `Voice.Speech` and its tests.
- [x] Delete `Notifications.Capture.Take` and its tests now that `Voice.Reference`, its last caller, is gone.
- [x] Remove the renderer from supervision and all render topics, subscriptions, config readers, calibration work, engine discovery and engine-install hints.
- [x] Remove obsolete comments from the generic notification sound and notification type code; preserve the per-notification sound behavior and types still used elsewhere.
- [x] Remove dead test fixtures, config overrides and file-size inventory entries. Ratchet shrinking files according to the existing gate; do not loosen caps to pass.
- [x] Audit desktop microphone permissions against the surviving recording paths. Do not remove a permission solely because the Vox UI is gone, or leave a Vox-specific capability without a caller.
- [x] Audit build and release scripts for engine references. Keep shared `ffmpeg`, audio assets, macOS speech and telephony support.

**Exit:** app startup and ordinary use work with no VoxCPM executable or model installation, and no dedicated code path can probe or enqueue synthesis.

### Phase 5 Verify the upgrade and close the roadmap

- [x] Run fresh-workspace and populated-upgrade scaffolding fixtures. Retained hashes, Settings rows, sound mappings and pending notifications are asserted; packaged fresh-release boot is tracked separately below.
- [x] Verify notification playback still uses an installed rendered WAV; deleting that fixture WAV must exercise the existing sound fallback rather than cause a crash.
- [ ] Verify native read-aloud, voice selection, speed, stop/barge-in and persistence in the desktop app. The browser must still show the native-speech unavailable state.
- [x] Exercise generic `sound_import` and `sound_apply`, Studio Mix and music through automated survivor tests. Audible desktop playback remains a manual device check.
- [x] Exercise the published-greeting and default-greeting branches through tests. A deployed phone-line walkthrough is a separate external check; changing or deleting published audio is not part of the upgrade.
- [x] Recover old `/voice` tabs, stale `vox` Home selection, and saved splits in browser/LiveView/JS tests. Browser walkthrough confirms working Speech/Settings panes and preserved preferences; native saved-tab and microphone-prompt walkthroughs remain manual.
- [x] Run `mix precommit`, `scripts/check_docs_drift.sh`, and the applicable desktop build and smoke checks. No new unit tests are needed for literal deletions; retain and extend tests that prove survivor and upgrade behavior.
- [x] Search shipping code, assets, instructions and command output for `VoxCPM`, `Vox2B`, `VoxComponent`, `voice_clip_`, `voice_message_`, `voice:renders`, and `voice_render`. Review every remaining hit; historical records and explicit removal tests may retain the names.
- [x] Record actual deletions, command totals and validation results here. Mark removal implemented in SUPERMAP and archive the superseded voice development roadmaps. Do not mark unperformed microphone or phone walkthroughs as passed.

**Exit:** VoxCPM is absent from the application while preserved speech, audio and phone behavior pass their checks.

## Implementation and validation record

- Ten synthesis modules, the renderer child, Vox UI/tutorial, seven voice commands, the recorder/meter and PCM take decoder are deleted. `Voice.Speech` is the only remaining module in `voice/`.
- The command catalog changed **199 → 192**: 78 read, 19 trigger, 95 mutate; 83 safe, 109 restricted, 21 gated. Trusted and MCP-tier calls to removed names return the ordinary unknown-command response.
- Configuration → Speech keeps the existing native hooks and localStorage keys. `/voice` redirects there, saved app tabs normalize on load, and legacy splits preserve the other pane. Settings rails are scoped per split pane.
- Phone → Greeting checks existing audio with HEAD and resets it only through the confirmed operator action. Missing, unconfigured and unavailable states are distinct. No real greeting was checked, replaced or deleted during implementation.
- No data migration, external engine uninstall, model-cache deletion or workspace cleanup was added. Tests compare completed/partial audio hashes, manifests, preferences, sound routing and pending notifications through upgrade scaffolding.
- The full Explained audit also corrected stale claims about cloned voices, Codex memory, harness defaults/policy gates, shader targets/WebGPU, browser history/audit, phone trust/PIN setup, duty queues and Studio editing. Every tutorial's links and displayed command names are checked against the current router/catalog.
- Microphone usage metadata remains for generic `sound_record` and potential browser media capture. The lockstep check includes the retained native capture command. No microphone permission was requested for this work.
- Focused suites passed: backend 155, original UI 178, split recovery 58, phone 32, Explained 100. These overlap; they are not an aggregate test count. Documentation drift passes against 192 commands; plist validation and the file-size inventory pass.
- Browser walkthrough passed: retired route/tab recovery, split Settings IDs, speech preference preservation, native-speech-unavailable state in a browser, all Explained navigation paths, and Phone Greeting without a remote request. No browser runtime exceptions were observed.
- `mix precommit` passed: **3,365 Elixir tests, 358 JavaScript tests, 52 Rust tests**, no failures (22 Elixir tests excluded). Run with `MIX_TEST_PARTITION=voxremoval ELIXIR_ERL_OPTIONS="+S 4:4"` to bound concurrency for the single SQLite test connection. Formatting, strict Credo, dependency cycles and file-size gates passed. The earlier run exposed a getUserMedia-only permission assertion and a 1-second Messages fixture budget; both were fixed, and the intentional timeout test remains unchanged. The Explained audit uses pure ExUnit component rendering without a database checkout. Package inspection caught an older `lib/buster_claw-0.1.0` directory retained by `mix release --overwrite`. The build now clears only the generated release directory before assembly, and the smoke gate rejects multiple application versions. The guard rejected the stale bundle. A clean unsigned app and DMG then built successfully; the bundle contains only `buster_claw-0.1.1`, and a recursive BEAM scan finds no retired Vox/engine/decoder modules. The isolated packaged boot smoke passed against a temporary database/workspace: health, API discovery (193 entries including composition skills), rejection of a bad token, onboarding redirect, and setup-page rendering. No real phone credentials were supplied.

Manual checks still open: audible native voice/rate/stop/barge-in, device capture consent, audible Mix/music/notification playback, and a deployed phone-line call. Their code paths remain covered by automated tests; those tests do not claim a hardware or cloud walkthrough. No external phone deployment is required for the deletion.

## Release and rollback

Ship the removal through a normal application restart, after any active render has finished or been deliberately stopped. Removing a supervised BEAM process is not proof that its external synthesis process has exited; identify any child started by this app before stopping it. Do not kill every machine-wide `voxcpm` or Python process.

The render queue is in memory. The release must not promise to resume unfinished synthesis after upgrading. Completed files remain in place, and no new startup cleanup should erase partial files or artifacts while silently calling that a successful render.

Rollback is a code rollback against the preserved workspace and Settings data. No schema drop, bulk deletion or cloud-storage mutation is required for the removal. This keeps reversal possible without making a second voice application part of Buster Claw's release process.
