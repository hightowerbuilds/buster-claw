# Music in Buster Claw — Roadmap V.1

**Date:** 2026-07-28 · **Status:** SCOPED, not started · **Scope of this document:**
upload music into the DataZone and play it from a new home tab beside Chat,
Calendar, and Notes. Nothing further.

> **The headline:** most of this is already built. Buster Claw has a working
> audio library, two audio-serving controllers, an upload flow that lands files
> in the DataZone, and a WGSL waveform renderer that decodes real audio. The
> genuinely new work is **one piece of HTTP infrastructure** (byte-range
> requests) and **one architectural decision** (where the player lives). The
> rest is assembly.

---

## Contents

- [Part I — What already exists](#part-i--what-already-exists)
- [Part II — The three findings that shape the build](#part-ii--the-three-findings-that-shape-the-build)
- [Part III — Decisions](#part-iii--decisions)
- [Part IV — The phases](#part-iv--the-phases)
- [Part V — Deliberately out of scope](#part-v--deliberately-out-of-scope)
- [Part VI — Risks](#part-vi--risks)

---

## Part I — What already exists

Verified against HEAD (`b36e25e`) by reading the code, not by memory. This
inventory is the reason the phase list is short.

| Prior art | Where | What it gives us |
|---|---|---|
| **A working audio library** | `lib/buster_claw/notifications/sound.ex` | `list/0`, `path_for/1`, `delete/1`, `ensure/0`, extension allowlist, content-type map, a README seeded into the workspace. The music library is this module at a larger scale. |
| **Allowlist-as-path-guard** | `sound.ex:75` | `path_for/1` resolves only names that appear in `list/0`, so raw input is never joined into a path. **Copy this posture exactly.** |
| **Audio upload into the DataZone** | `lib/buster_claw_web/live/notify_settings_live.ex:104-150` | `allow_upload(accept: ~w(audio/*))` → `consume_uploaded_entries` → extension re-check → sanitized, collision-free destination (`available_name/1`, suffixes `-2`, `-3`). This is the upload phase, already written. |
| **Two audio-serving controllers** | `notify_sound_controller.ex`, `telephony_recording_controller.ex` | The serving posture: no pipeline, loopback-only, content-type by extension, `send_file`. Both are the template — and both share the gap in Finding 1. |
| **Real waveform rendering** | `assets/js/hooks/audio_clip.js` + `assets/js/audio/clipwave.js` | Fetches audio, `decodePeaks`, renders a WGSL waveform, with an IntersectionObserver so off-screen clips don't run render loops, and a CSS fallback when WebGPU is absent. Directly reusable. |
| **An inline `<audio>` player** | `lib/buster_claw_web/live/phone_live.ex:854` | Voicemail playback already works in a LiveView. |
| **The DataZone path helper** | `lib/buster_claw/library/artifact.ex:37` | `workspace_path/1` is the single source of truth for "this lives under the workspace root". |
| **A persistent surface** | `lib/buster_claw_web/live/dock_live.ex` | Mounted `sticky: true` in `Layouts.app`, so it "runs in its own process and persists across page navigation." This is Finding 2's answer. |

**What this means:** we are not building a music subsystem from nothing. We are
generalizing `Notifications.Sound` from *short chimes* to *long tracks*, and the
difference between those two things is almost entirely Finding 1.

---

## Part II — The three findings that shape the build

### Finding 1 — Nothing in the app supports HTTP byte ranges — **this is the real work**

`grep` for `range` / `206` / `accept-ranges` across `lib/` returns nothing but
calendar date ranges. Both audio controllers do the same thing:

```elixir
|> send_file(200, path)
```

A whole-file `200` is fine for what they serve today — a notification chime is a
second long, a voicemail a few dozen. It is **not** fine for a five-minute track:

- **Seeking breaks.** Dragging the scrubber makes the browser re-request from
  byte 0 and re-download the whole file.
- **WKWebView is the strict case.** The Tauri shell renders in WKWebView, whose
  media stack issues `Range: bytes=0-` and expects `206 Partial Content` with
  `Accept-Ranges: bytes` and a correct `Content-Range`. A `200` can leave the
  element unable to report duration or seek at all — the failure is
  platform-specific, so **it will look fine in a plain browser tab and misbehave
  in the packaged app.**
- The existing controllers should be migrated onto the same helper once it
  exists, which fixes voicemail scrubbing as a free side effect.

This is one small, well-understood, highly testable module. It is also the only
part of this roadmap that does not already have a working precedent in-repo, so
it goes first and gets real tests: valid range, open-ended range, suffix range,
multiple/unsatisfiable/malformed ranges, `HEAD`, and a zero-byte file.

### Finding 2 — A player inside the tab stops when you leave the tab

The home tabs render with `:if`:

```elixir
<div :if={@home_tab == "notes"} class="...">
```
`status_live.ex:1097`

`:if` **removes the DOM**. An `<audio>` element inside the Music tab is
destroyed the moment you click back to Chat, and playback stops. Given the
feature's whole point is music *alongside* chat, calendar, and notes, that is a
failure of the requirement, not a detail.

Worse, it fails in the direction that looks like it works: the tab demos
perfectly, and the bug only appears when someone does the normal thing.

**The answer is already in the codebase.** `DockLive` is mounted `sticky: true`
in `Layouts.app` precisely so "a timer set on the homepage stays visible from
/browse or /terminal." A sticky LiveView's DOM survives live navigation. So:

- **the player** (the `<audio>` element, transport state, current track) lives in
  a sticky dock LiveView — it keeps playing across tab switches *and* across
  navigation to `/browse`, `/terminal`, `/trading`;
- **the Music tab** is a *library and queue browser* that sends commands to the
  player and renders its state.

That split is why the player is built before the tab (Phase 3 before Phase 4) —
building it the other way means building it twice.

**Known limit, accepted:** `/split` renders through `Layouts.bare/1`, which drops
the dock entirely, so playback does not survive entering split view. Note it in
the UI rather than fixing it; split is a two-pane work mode, not a listening one.

### Finding 3 — CSP already allows this, and quietly forbids one design

`content_security_policy.ex` has no `media-src` directive, so media falls back to
`default-src 'self'`. Audio served from our own loopback route is allowed —
**no CSP change is needed.**

But the fallback is `'self'` *only*: it does not include `blob:` or `data:`
(unlike `img-src`, which lists both). So any design that decodes audio in JS and
hands the element a `blob:` URL is blocked in prod — and, since CSP is
Report-Only in dev and enforced only in prod (`config/prod.exs`), **it would work
all the way through development and fail in the shipped app.** Serve from a route
and this never comes up. Recorded so nobody "optimizes" into it later.

---

## Part III — Decisions

| Decision | Call | Why |
|---|---|---|
| Where the files live | `<workspace>/music/` via `Artifact.workspace_path("music")` | Sibling of `sounds/`. It's the DataZone, it's the user's disk, `grep` and Finder both work. |
| Library module | New `BusterClaw.Music`, modeled on `Notifications.Sound` | Don't overload the notification library — different lifecycle, different size class, different UI. Shared helpers can be extracted later *if* duplication proves real. |
| Metadata source | **Filename first.** No ID3 parsing in V.1 | There is no bundled ID3 parser and this repo declines dependencies for cosmetics (see lightweight-charts, 07-28). `Artist - Title.mp3` parses to two fields; anything else displays its filename. Honest and zero-risk. ID3 is a candidate for V.2, in Elixir, only if the display is genuinely poor. |
| Formats | `.mp3 .m4a .aac .wav .ogg .flac` | The first five match `Notifications.Sound`; FLAC is added because people who own music files own FLACs. Codec support is the webview's business — Phase 1 probes what WKWebView actually plays and the answer gets written down. |
| Upload size cap | 100 MB per file | Between notify's small cap and workspace import's 200 MB. A long FLAC clears it; a video does not. |
| Player state owner | The sticky dock LiveView (server), not the client | Matches DockLive's posture and means the Music tab renders real transport state instead of guessing. |
| Playback position | Client-owned, server told on a throttle | Per-frame `timeupdate` over the socket is waste; DockLive's precedent is client-side ticking from `data-*` attributes. |

---

## Part IV — The phases

Each phase is committable on its own and leaves the app working.

### Phase 0 — `BusterClaw.Music`: the library and the DataZone folder

Create the context: `dir/0`, `list/0`, `path_for/1`, `delete/1`, `content_type/1`,
`accepted_extensions/0`, `ensure/0` (folder + README, best-effort, never raises —
copy `Sound.ensure/0`), and `track_info/1` for filename-derived metadata. Wire
`ensure/0` into `Application.start/2` beside the other `ensure` calls
(`application.ex:76-93`).

*Acceptance:* `<workspace>/music/` exists with a README on boot; `list/0` returns
only real audio files sorted; `path_for/1` refuses a name outside `list/0`,
including `../` traversal attempts; unit tests cover empty dir, non-audio files
present, and the traversal refusal.

### Phase 1 — Byte-range streaming — *the load-bearing phase*

A small `BusterClawWeb.RangeResponse` helper: parse `Range`, emit `206` with
`Content-Range` + `Accept-Ranges: bytes`, `416` on unsatisfiable, fall through to
`200` when absent or malformed. Then `MusicController` on top of it, and migrate
`TelephonyRecordingController` onto the same helper.

*Acceptance:* controller tests for absent / valid / open-ended / suffix /
unsatisfiable / malformed ranges, `HEAD`, and a zero-byte file. **Plus a manual
check in the packaged app, not just a browser tab** — per Finding 1 this is the
one behavior that differs by webview, and per the 07-28 build blocker, "the tests
pass" is not a claim about the artifact.

### Phase 2 — Upload

`allow_upload` in the Music tab with the accept list and cap from Part III;
`consume_uploaded_entries` re-checking the extension server-side; sanitized,
collision-free destination via the `available_name/1` pattern
(`notify_settings_live.ex:139`). Progress, per-entry errors, cancel, and delete.

*Acceptance:* a file with a hostile name (`../../etc/x.mp3`, unicode, spaces)
lands as a safe basename inside `<workspace>/music/`; two uploads of the same
name coexist as `song.mp3` / `song-2.mp3`; a `.pdf` renamed to `.mp3` is rejected
by the server-side check, not only by the picker.

### Phase 3 — The player (sticky dock)

`MusicPlayerLive`, mounted `sticky: true` in `Layouts.app` beside `DockLive`. Owns
the `<audio>` element, current track, queue, play/pause/next/prev/seek/volume,
and broadcasts state on PubSub so the Music tab can render it. A `MusicPlayer`
hook bridges element events to the server on a throttle.

*Acceptance:* start a track, switch to Chat, navigate to `/browse`, come back —
**still playing, position intact.** Ending a track advances the queue. No audio
present → the dock shows nothing rather than a dead player.

### Phase 4 — The Music tab

Add `"music"` to the tab list (`status_live.ex:1055`) and to the `select_home_tab`
guard (`status_live.ex:317`) — note that guard is a whitelist, so **missing it is
a silent no-op**, which is exactly the kind of thing that eats twenty minutes.
Then a `MusicComponent` live_component: library list, click to play, queue view,
upload affordance, delete, empty state that says how to add music.

*Acceptance:* the tab lists what's on disk, clicking plays through the dock
player, the tab reflects transport state it does not own, and an empty library
reads as an invitation rather than a bug.

### Phase 5 — Waveform and polish

Reuse `AudioClip`/`clipwave.js` for a now-playing waveform, with the existing CSS
fallback when WebGPU is absent. Keyboard control, the `/split` limitation noted in
the UI, and a pass on the empty/error states.

*Acceptance:* no WebGPU → fallback bars, never a broken canvas; a corrupt file
fails to one track with a message, not a dead player.

---

## Part V — Deliberately out of scope

Named so they are decisions rather than omissions, and because the user has said
more will be added to this roadmap.

- **Sound effects.** Mentioned in the same breath as music, but the app already
  has an SFX system: `Notifications.Sound` routes per-event sounds with a
  settings UI. Extending *that* is a different, smaller job than this one and
  shouldn't be tangled into it. Its own section, later.
- **Agent control of playback** ("play something quiet"). Natural and cheap once
  Phase 3 exists — the player is already a GenServer-ish surface and the command
  catalog is the front door. Deferred so V.1 is a music player before it is an
  agent capability.
- **Playlists, ratings, play counts, search.** Wait for the library to be big
  enough to need them.
- **Streaming services, DRM, network sources.** Never. The DataZone is the
  product; a file the user owns is the whole model.
- **ID3/metadata parsing.** Per Part III, revisit only if filenames read badly.
- **Bundled music.** No audio ships with the app, matching `Sound.ensure/0`'s
  stance that the chime is operator-provided. Licensing alone decides this.

---

## Part VI — Risks

1. **Range handling is easy to get subtly wrong** (off-by-one on the inclusive
   end byte is the classic). Mitigated by tests written before the controller,
   and by the fact that a wrong `Content-Range` fails loudly in WKWebView.
2. **Codec support in WKWebView is not the same as in Chrome.** FLAC and OGG are
   the likely gaps. Phase 1 probes the packaged app and the answer is written
   into `Music.accepted_extensions/0` — an accepted format that won't play is
   worse than a rejected one.
3. **Library size.** A few hundred tracks in one LiveView list is fine; a few
   thousand is not. If it lands, paginate — do not stream every file's metadata.
4. **`/split` drops the dock**, so playback dies there (Finding 2). Accepted and
   surfaced, not fixed.
5. **Disk.** The DataZone is the user's disk and music is the largest thing
   anyone will put in it. Show library size in the tab; add no quota.
