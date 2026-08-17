> ## ARCHIVED 2026-08-17 — built whole; the native half is owed a walk
>
> Scoped and built 08-15, Phases 0–4. Drop an image in `pockets/app-icon/` and
> apply it; keyed to the file's bytes, so replacing it reverts to the shipped
> icon. The bundle icon stays sealed by the signature.
>
> **Closed with one item OPEN and FILED, not resolved.** Every layer is tested
> except the one that talks to macOS: nothing has watched a Dock icon change,
> because there is no Dock in `mix test` and none in a browser. That needs a
> packaged walk and it lives in
> [`QA_BACKLOG`](../roadmaps/platform/QA_BACKLOG.md) — *"The Dock icon has never
> been seen to change"*. Archiving the map does not close that; it moves it to
> the list that tracks unwalked things.

# The app icon — the one piece of chrome that isn't ours

**Scoped 08-15-26 · Status: BUILT 08-15, Phases 0–4. One thing is unverified and
it is the one that matters — see below.**

> ### The native half has never run
>
> Every layer is tested except the one that talks to macOS. `app_icon_set` has
> unit tests for its path validation, but **nothing has watched a Dock icon
> change** — there is no Dock in `mix test` and none in a browser, so this needs a
> packaged walk. Filed in `QA_BACKLOG` beside the other two.
>
> Specifically unproven: that `setApplicationIconImage:` on Tauri's sync-command
> thread is in fact the main thread, that `NSImage initWithContentsOfFile:` reads
> what the operator dropped in, and that `nil` restores the bundle icon rather
> than clearing the tile.

Operator asked whether the icon macOS shows in the Dock could be a Pocket, so a
user can change what they see there while using the app they downloaded.

**Yes — one of them.** There are two icons wearing the same name, and the
distinction is the whole design.

---

## The fact that reorders everything

| | What it is | Can we change it |
|---|---|---|
| **The bundle icon** | `Contents/Resources/*.icns`, from `"icon": ["icons/icon.png"]`. Finder, Launchpad, and the Dock when the app is **not running** | **No, and not "not yet"** |
| **The running Dock tile** | `NSApplication.applicationIconImage`, live for the life of the process | **Yes, and it is exactly what was asked for** |

### Why the bundle icon is closed

`_CodeSignature/CodeResources` seals `Contents/`. Writing a new `.icns` into a
signed bundle invalidates the Developer ID signature, the hardened runtime, and
the notarization ticket in one move — the app would fail to launch on any machine
that did not build it, which is the only kind of machine that matters. An app
installed in `/Applications` also cannot write to itself without admin.

This is not an obstacle to route around. It is the property that makes the DMG
worth signing, and the first release (`R1`) depends on it more than on any
feature in this file.

> There is a third path — Finder's per-file custom icon, which lives outside
> `Contents/` — and it is **not** scoped here. It has not been verified against a
> hardened-runtime bundle, it requires manipulating the app from outside itself,
> and it would persist after uninstall. Named so nobody rediscovers it as
> "obvious"; if it is ever wanted it is its own roadmap with its own test.

### What the running tile actually gives

`applicationIconImage` sets the Dock icon for the lifetime of the process. It
touches no file, breaks no signature, needs no entitlement, and **reverts on
quit**. That last part is a feature, not a caveat: the operator's own art is what
they see while using the app, and the app they downloaded is what they see in
Finder. Nothing about the installed artifact changes.

---

## What is already here

This lands on unusually well-prepared ground, which is most of the argument for
doing it at all.

- **`Pockets.Brand` is the exact shape.** Six slots today — five in-app dock icons
  and the homepage banner. A seventh is one map in `@slots`. Its three-state model
  (`:default` / `:custom` / `{:error, :too_many, n}`), its fixed role→Pocket
  binding (D10, so an agent cannot shadow chrome by writing a manifest), and its
  move-don't-delete replacement rule all apply unchanged.
- **The change already broadcasts.** `Brand.topic()` publishes
  `:brand_art_changed`, and `ChromeHook` already subscribes on behalf of every
  LiveView. There is no new notification path to build.
- **The objc bridge exists.** `objc` is already a macOS dependency and
  `desktop/tauri/src/browser/ffi.rs` is the established pattern, with non-macOS
  stubs per function.
- **The invoke path exists.** `assets/js/hooks/voice.js` is the template: an
  always-mounted bridge in the layout, `window.__TAURI__?.core?.invoke` captured
  on mount, `handleEvent` for a server push, and a silent no-op in a plain
  browser. Copy its shape exactly.
- **The ACL trap is already guarded.** A command missing from `build.rs` is
  ACL-dead in a packaged build — the 07-17 co-presence bug, then `speak` on
  07-21 — but `tests/acl_lockstep.rs` now enforces the lockstep. This is the
  first new Tauri command since that test existed, which makes it a live check of
  whether the guard works.

---

## Phase 0 — May an agent change the icon the OS shows? *(operator, not code)*

Everything below inherits this, and it is not obvious.

The workspace is writable, so **an agent needs no command to fill a Pocket** — it
writes a PNG into `pockets/app-icon/` and the slot is filled. That is precisely
the D1 hole `background_set` opened on 08-15 and it was closed in the command
layer, not by making the surface refuse.

The nav-icon Pockets already have this property and it was accepted: an agent can
change the in-app dock's Home icon. **The escalation here is that this one leaves
the app's window.** An icon in the OS Dock is a trust signal — it is how a person
identifies which window belongs to which program, and it sits next to icons no
web page can touch.

Three ways to answer, and none is obviously right:

1. **Follow the Pocket, like every other brand slot.** Consistent, and the
   precedent already exists. An agent that can write the workspace can change
   what the Dock shows while the app runs.
2. **Follow the Pocket, but require a human to have chosen it.** A `selected`
   marker the operator sets in the Pockets panel, which an agent can write files
   past but not select. This is the `background_set` shape: the surface keeps
   working for a human, the command surface is the narrower one.
3. **Human-only, no automatic follow at all.** Safest, and least like the rest of
   Brand.

**DECIDED 08-15: option 2.** A file in the Pocket is not an icon. The operator
applies it, and only then does the Dock change.

**Implemented the way the shader gate was decided the same day: by content
hash.** A bare "selected" flag would name a file, and a name is forgeable — an
agent that can write the Pocket could replace the bytes under a selection the
operator made of something else. So applying records a SHA-256 of the image, and
the icon is set only while the file still matches. Replace the file and the Dock
falls back to the bundle icon until the operator applies it again.

That is a deliberate echo, not a coincidence: this is the same question as
`AGENT_APPLIED_SHADERS` — *may an agent put something the operator has never
looked at in front of them?* — and it deserved the same answer rather than a
second, weaker mechanism invented for it.

**What it costs:** an agent can still swap the file. It just cannot make anyone
look at the result. The failure mode is the Dock reverting to the shipped icon,
which is visible and recoverable, rather than an icon the operator never chose.

---

## Phase 1 — The native call ✅ BUILT 08-15 (unverified — see header)

One Rust command, one AppKit message.

- `app_icon_set(path: Option<String>)` — `Some` sets the image, `None` restores
  the bundle icon (AppKit does this when the property is set to nil, which is why
  there is no separate reset command).
- **THREADING CONTRACT, and it is the inverse of `ffi.rs`'s.** That module's
  contract is "anything round-tripping a completion handler must be called from
  an *async* command, or the main run loop deadlocks." `setApplicationIconImage:`
  has **no completion handler** and is a plain AppKit UI call, so it must run
  **on** the main thread — a sync command, or `run_on_main_thread`. Getting this
  backwards on the strength of the neighbouring module's comment is the most
  likely way to break this phase.
- **The path is validated in Rust, not trusted.** The invoke boundary is reachable
  from any JS running in the webview, so the command must refuse a path outside
  the app-icon Pocket. The server composing an honest path is not the same as the
  command only accepting one.
- Non-macOS stub returning `Ok(())`, matching `ffi.rs`'s per-function pattern.
- Register in `build.rs` **and** `capabilities/default.json`. `acl_lockstep.rs`
  should fail if either is missed; if it does not, that is a finding worth more
  than this feature.

**Exit:** invoking the command with a PNG path changes the Dock icon of the
running packaged app, and invoking it with `None` puts the original back.

---

## Phase 2 — The slot ✅ SHIPPED 08-15

- A seventh `@slots` entry: `role: "app_icon"`, `pocket: "app-icon"`,
  `label: "Buster Claw"`, and **no `default`** — see below.
- `Brand.image_path/1` beside `image_url/1`. The native layer needs a file on
  disk; `NSImage` cannot be handed a loopback URL the asset route would demand
  auth for.
- **`:default` means "do nothing", not "set the shipped PNG".** The bundle icon
  already *is* the default, so the default state is the absence of a call. This
  removes the only case that would have needed a path into `priv/static` from a
  release, which is the awkward half of `image_url/1`'s `default` field.

**Exit:** met on the second pass. The first shipped without an upload button —
the Pocket was fillable only from Finder — and the operator hit it in the first
minute: *"we need a simple add art button like the rest, the drag and drop isn't
working."* A Pocket you can only fill in Finder is a Pocket most people never
fill.

**Uploading through the picker applies immediately, and that is not a hole in the
gate.** The gate asks whether a *human* chose the image. A file input in the
app's own UI is not something an agent can drive; what the gate stops is a file
that appeared in the folder without anyone choosing it — dropped in Finder, or
written by a run — and that path still needs the button.

The picker itself is `BrandSlots.upload_form/1`, shared rather than copied. Its
four failure states are rendered once, and that file's own comment records what
happened the last time they were missing: a refused file looked exactly like a
file that had not been chosen, so the upload read as doing nothing.

---

## Phase 3 — The bridge ✅ SHIPPED 08-15

- An always-mounted `AppIcon` hook in the layout, modelled on `VoiceBridge`:
  capture `invoke` on mount, `handleEvent("bc:app-icon", …)`, no-op when
  `window.__TAURI__` is absent so the browser dev loop is unaffected.
- **Push on mount as well as on change.** A user who set their icon last session
  must see it at launch, not after they next touch the Pockets panel. This is the
  half that is easy to leave out, because the change path is the one being tested
  while writing it.
- `ChromeHook` already subscribes to `Brand.topic()`; the push hangs off the
  existing `:brand_art_changed` handler.

**Exit:** quit and relaunch the packaged app with a custom icon in the Pocket and
the Dock shows it without the operator touching anything.

---

## Phase 4 — The error state, which has no text to fall back on ✅ SHIPPED 08-15 — differently

`Brand`'s over-full rule is deliberate and documented: two or more images renders
**the text label**, because that looks different from both correct states, and
"the art disappearing is the notification."

**A Dock tile cannot render a text label.** So this slot needs its own answer, and
the two obvious ones both contradict something:

- Reverting to the bundle icon *hides the problem entirely* — the exact failure
  `Brand`'s moduledoc rejects for the other six slots.
- Leaving the previous custom icon up is worse: it shows art the operator can no
  longer explain from the folder's contents.

The proposal is **revert to the bundle icon and badge the tile**, via
`NSDockTile.badgeLabel` — the notification lands in the same place the art would
have. It preserves the principle (the failure is visible where the feature is)
using the only text channel a Dock tile has.

**Exit:** met by the words alone — **no badge was built.** `NSDockTile.badgeLabel`
was the proposal, and the build did not need it: the Pockets panel already has to
explain a *fourth* state this roadmap did not anticipate — `:replaced`, where the
operator applied an icon and the file changed afterwards — and once that sentence
exists, the over-full state is one more sentence in the same place. A badge would
put half the explanation somewhere the other half cannot go.

`:replaced` is the state worth naming. It looks exactly like a bug from outside:
the custom icon is gone, the file is still on disk, nothing was clicked. The panel
says what happened, **who could have done it** ("including the agent"), and what
to do. That sentence is the feature's honesty, and it is asserted by a test.

---

## Adjacent, and nearly free once Phase 1 lands

`NSDockTile.badgeLabel` is the same object Phase 4 needs. **Unheard voicemail
count on the Dock** is roughly ten lines on top of it and is the first thing this
app has ever had that is genuinely worth a badge — `Telephony.unheard_count/0`
already exists and already broadcasts. Not scoped here; named so it is not
rediscovered as a separate idea.

---

## Explicitly out of scope

- **The bundle icon.** See above. Closed, not deferred.
- **Finder's per-file custom icon.** Unverified against a hardened-runtime
  bundle, and it would outlive an uninstall.
- **An animated Dock tile.** `NSDockTile.contentView` takes a native `NSView`, so
  the app's WGSL cannot render into it — that would mean pushing `NSImage` frames
  into a 128px square from Elixir. A real build for very little.
- **Windows and Linux.** Taskbar icons are a different API on each, and both are
  behind macOS everywhere else in this repo. Non-macOS gets the stub.
- **A menu-bar / tray icon.** Different surface, different roadmap.

---

## Risks

| Risk | Weight | Mitigation |
|---|---|---|
| Threading contract taken from the neighbouring module and inverted | **High** | it is stated in Phase 1 and belongs in the code comment, not just here |
| New Tauri command is ACL-dead in the packaged build | Medium | `acl_lockstep.rs` exists now; this is its first real exercise |
| An agent changes the OS-visible icon unattended | Medium | Phase 0 decides; option 2 closes it the way `background_set` was closed |
| Untestable in the browser dev loop | Medium | there is no Dock in Chrome — this needs a packaged walk, and belongs in `QA_BACKLOG` beside the other two |
| A path from the webview reaches `NSImage` unvalidated | Medium | Phase 1 validates in Rust; the server being honest is not the guard |
