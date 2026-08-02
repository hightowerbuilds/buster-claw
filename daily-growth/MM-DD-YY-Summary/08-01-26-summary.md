# 08-01-26 — One catalog, two surfaces

Settings → Appearance had two background pickers that didn't know about each
other: five image slots that only the terminal could use, one separate image
file that only the homepage could use, and the whole shader list rendered twice.
It is now **one catalog, shown once**, with a shared image pool either surface
can point at — and the two surfaces sit beside it as live previews of what they
are actually running.

Then a small bug with a bigger lesson: the Notify sub-tab was escaping Settings
and opening its own top-level tab, because the sub-tab list is declared twice
and one copy drifted (§8).

Then the workspace itself: a review found a folder nobody had ever described,
and the first three phases of the rebuild cut a fresh install from **sixteen
top-level entries to eight**, with all audio consolidated under `sounds/` (§9).

Three commits on main. Suite at close: 2078 tests, 110 JS, 34 Rust, credo strict
clean, `mix precommit` green. Five iterations on the layout, one feature built
and then deleted on operator testing.

## 1. The model: one pool, one grammar

The old storage was per-surface and it was the reason the UI had to be two
pickers. Terminal images lived in `terminal_background_<n>_path` (slots 1–5)
plus a `terminal_background_active` pointer; the homepage image lived in a
separate `home_background_image_path` with no slot at all. Nothing could be
shared, so nothing was.

Now there is one 8-slot pool (`background_image_<n>_path`) and **one mode
grammar for both surfaces**: `off`, a shader name, or `image:<n>`. Everything
below the API is written against a `@surfaces` config table — mode key, custom
key, colors key, topic, broadcast message, default — so there is one code path
and two configurations rather than two parallel implementations. The immediate
payoff: the same image can back the homepage and the terminal at once, which was
simply unrepresentable before.

Defaults differ per surface and that is deliberate: the homepage falls back to
`smoke`, the terminal to `off`. An empty homepage reads as broken; an empty
terminal reads as plain.

## 2. The migration rewrites settings, never files

`Appearance.ensure/0` runs at boot beside the other `ensure` calls, marker-
guarded and idempotent. Terminal slots keep their numbers; the homepage image
takes the first free slot; the old `"image"` mode plus its active-slot pointer
becomes an explicit `image:<n>`. An unset terminal mode with an active slot
still means image — that was the pre-shader install's implicit behavior and
dropping it would have silently cleared someone's background.

**It touches no files.** Only `Settings` keys are rewritten, so an image adopted
from the old layout keeps its old name on disk and simply answers to a pool slot
now. `clear_image/1` therefore deletes the file the slot actually points at,
then sweeps the canonical names — because a migrated slot's file is not named
what the current code would have named it. Both operations stay fenced to the
appearance dir by the existing containment guard.

Seven migration tests, including the fresh-install case that must migrate
nothing.

## 3. The blast radius that wasn't

`terminal_background/0` and `home_background_state/0` still return the exact
same shapes — `kind`, `mode`, `shader`, `source_url`, `image_url`, `custom`,
`colors`. The *stored* grammar changed; the *resolved* shape did not. So
`StatusLive`, `TerminalLive` and `SplitLive` needed **zero changes** despite
sitting directly on this data. Worth remembering as a shape: pick the seam at
the resolved value, not the storage, and a storage rewrite stops being a
cross-cutting change.

The controller collapsed to one route — `/appearance/image/:slot`. A slot isn't
owned by a surface any more, so a per-surface route had nothing left to mean.

## 4. Drag-and-drop: built, then cut

The first design was drag-a-tile-onto-a-surface, with a delegated hook modeled
on `file_tree_dnd.js` (private MIME type, one listener set on the section root,
`pushEvent` on drop) and click buttons as the accessible fallback. It worked,
it was tested, and on real use the operator's verdict was that HTML5 DnD "doesn't
work out so well" — which matches what this codebase already knows about
WKWebView and drag events (see `tab_strip.js`, which hit the same wall from the
`contextmenu` side).

So it was **removed entirely**, not disabled: the hook file deleted and
unregistered, the CSS drop states deleted, `draggable` / `data-bg-filled` /
`data-bg-surface` / the drop-hint overlay stripped from the markup, and every
line of copy that promised dragging rewritten. Verified `BackgroundDnd` is
absent from the built bundle.

The server contract never changed — `assign_background` was always the single
event behind both the drag and the buttons. Removing the drag removed a *caller*,
not behavior, and the buttons that remain were never a fallback bolted on; they
were the same path all along. That is the only reason the cut was cheap.

## 5. A shader is named, not pictured

Catalog tiles first painted a static gradient built from each shader's palette,
mirrored into Elixir from `assets/js/smoke/palettes.js`. Two problems: the
mirror was a drift risk I had to write a comment about, and the gradients were a
fiction — they are not what the shader looks like.

Cut. Shaders are now plain named rows; only images carry a thumbnail, because a
thumbnail is the only way to tell one image from another. The palette table went
with it, so the drift risk is gone rather than documented.

The reason there is no live canvas per row stands and is worth recording:
`createSmoke` requests its own adapter and device per canvas, so a gallery of
live previews means a GPU device per tile. Only the two surface panels animate —
the same count the old page had.

## 6. The layout, in four passes

Two columns: catalog left, the two surface panels stacked right. Then, in order:
previews capped with `max-h-40`; the themes moved *below* the backgrounds; images
and their upload zone moved *above* the shader list (the upload zone had to move
with the grid it feeds, or it would have been orphaned); shaders one per row.

The last pass was the interesting one. A fixed `lg:max-h-[30rem]` on the catalog
looked absurd next to a right column whose height varies with state — a surface
on a shader renders palette controls, one that's `off` doesn't. The fix is CSS
Grid's default `align-items: stretch`, but stretch alone would have done the
*opposite* of what was wanted: the row sizes to the tallest item's content, so a
long option list would have driven the height and the surfaces would have
stretched to match it.

So the catalog panel is taken **out of flow** — a `relative` wrapper is the grid
cell, and from `lg` up the panel is `absolute inset-0` inside it. The wrapper
contributes no content height, the row is sized purely by the two stacked
panels, and the panel fills exactly that. Out-of-flow is the whole trick.
Below `lg` nothing is positioned and the columns stack normally.

Equal heights made the sticky right column pointless; it came out.

## 7. Tests

Context tests went 344 → 481 lines, LiveView tests 56 → 268. Beyond the
migration set: one image backing both surfaces, surface independence, the
shaderface fence enforced at the boundary for *both* surfaces (not just the
picker), `option_key/1` round-tripping as the inverse of `set_background/2`,
removal degrading only the surfaces that were using a slot, and crafted events
naming an unknown surface or a non-numeric slot no-opping instead of crashing.

Two pre-existing helpers in `split_live_test` and `terminal_live_test` wrote the
legacy settings keys directly and had to move to the pool keys — the only places
outside Appearance that knew the old storage.

One test-only trap worth writing down: `Appearance.ensure/0` runs at application
boot and commits its marker to the test DB *before* the sandbox opens, so every
migration test started life already migrated. The fix is a `setup` that deletes
the marker inside the test's transaction. Any future boot-time `ensure` with a
persisted guard will hit this.

## 8. A settings sub-tab that escaped its group

Clicking **Notify** in Settings opened a new tab in the top browser-style strip,
labelled with the bare string `/notify-settings`. It should have stayed inside
the Settings tab like every other sub-tab.

Not a logic error — a drift. The Settings sub-tabs are declared **twice**: in
`BusterClawWeb.SettingsTabs` (Elixir, 8 paths) and in `TAB_GROUPS` in
`assets/js/lib/tabs.js` (JS, 7 paths). Notify was added to the nav and never
added to the JS group. So `canonicalGroupKey("/notify-settings")` returned null,
`currentKey()` fell through to the raw path instead of collapsing to
`/settings`, `sync()` found no matching tab and made one — and the label was the
path itself, because `labelForPath` falls back to the path when the route isn't
in `@tab_labels` either.

The fix is one line. Two things came free with it: Notify now inherits the
group's `href` memory, so leaving Settings and returning reopens Notify rather
than the canonical default; and the bug **self-heals** for anyone who already
tripped it, because `sync()` prunes any tab whose path belongs to a group but
isn't the group key — a stray `/notify-settings` tab in localStorage is dropped
on next load, no migration needed.

The one-liner was not the whole job. Two hand-maintained lists that must agree
will drift again the next time a sub-tab is added, so `SettingsTabs.paths/0` is
now public and `BusterClawWeb.SettingsTabsTest` reads `tabs.js`, extracts the
group's Set, and diffs it **both ways** — missing entries and stale ones — in
the same spirit as the Rust `acl_lockstep` suite. The guard was verified by
reverting the fix and watching it go red with the path named in the message.

That is the second cross-language mirror this session (the first being the
shader palettes in §5, which got deleted rather than guarded). The pattern to
watch for: a list that exists in both Elixir and JS and is kept in step by
memory. Either delete one copy or hold them in lockstep with a test — never
leave it to a comment.

## 9. The workspace: sixteen entries, seven of them empty

The workspace is the product's one durable promise — *everything is markdown on
your disk, `grep` works*. It is also the first thing a new user sees, and what
they saw was a filing cabinet of empty labelled drawers. Full write-up in
`archive/08-01-26-workspace-review-roadmap.md`; the short version:

**Nothing declared the layout.** Creation was scattered across four trigger
contexts — nine calls in `application.ex`, **three more hidden inside
`Jobs.ensure/0`** (skills, shaders, cmd-list), a *different and smaller* set of
four in `WorkspaceLive.set_workspace_root/1`, and the rest lazily on first use.
Tracing every `workspace_path/1` call found **twenty** possible top-level
entries, not the thirteen visible on this machine. That is the finding: no two
installs had the same layout, and which one you got depended on which features
you happened to use.

Downstream of that, a real bug nobody had noticed: **moving your workspace
folder gave you a broken one.** `set_workspace_root/1` created four things; jobs,
skills, sounds, music, studio, journal, shaders, cmd-list and the trusted-sender
policy template did not exist until the next app restart. Boot papered over it.

Also found: `sources/` and `analysis/`, scaffolding the code's own comment admits
is dead ("reserved for file exports" — since the rewrite); `notes/`, an orphan
**no code in `lib/` creates**, superseded by `journal/` and never swept; and
`INTRODUCTION.md`, 861 lines and 57 KB, regenerated each launch, self-described
read-only — the largest, loudest thing in the user's folder and not for them.

### What shipped

**Phase 0.** `BusterClaw.Workspace` declares all twenty entries — name, kind,
tier, owner, seeder, and a plain-language note. Boot and `set_workspace_root/1`
now call the same `ensure/0`, so that bug is gone by construction. A lockstep
guard walks `lib/` and fails the build on any undeclared top-level path; it found
two things on its first run (a real undeclared legacy file, and a doc example
naming a file that doesn't exist).

**Phase 1.** Dropped the dead scaffolding, plus a sweep for leftovers that
removes them **only when empty** — a non-empty one is kept and logged, because
decluttering does not outrank not destroying someone's files.

**Phase 2.** Tiered the registry. `ensure/0` seeds `:core` only; every
`:on_demand` folder is created by the surface that owns it — opening the Music
tab makes `music/`, Settings → Appearance makes `shaders/`, Settings → Notify
makes `sounds/`. That is "create at the point of use" with no new UI: the folder
exists the moment the app is telling you what to put in it, and never before. A
generated `README.md` replaces four scattered stub READMEs, built *from the
registry* so its folder list cannot drift from what the app creates.

**Phase 2b — audio is one folder.** Operator call: consolidate to `sounds/` and
`shaders/`. `music/` and `studio/` are no longer top-level; they are
`sounds/music/` and `sounds/studio/`, with the chimes at `sounds/` and track
JSONs at `sounds/studio/tracks/`. Checked before moving anything that
`Sound.list/0` filters on `File.regular?`, so the nested directories can't
pollute the chime picker — a flat merge would have made the notification
dropdown list your entire music library.

The migration moves an existing install's folders and **merges rather than
clobbers**: a name collision leaves both copies in place and logs it, because we
do not get to pick which of a user's two files survives. Six test files had
fixture paths rewritten; the migration's own tests deliberately still write the
old layout.

**Measured, not asserted:**

| | before | after |
|---|---|---|
| fresh install | 16 entries, 7 of them empty | **8**, none empty |
| after using every feature | 16 | **12**, audio in one folder |

### Two lessons

The suite caught a wiring mistake that was a genuine design error, not a typo. I
had made *opening* the Cmd List editor write `catalog.json` — but the terminal
falls back to built-ins when the file is absent, and the save path already
`mkdir_p`s, so the folder should appear when you customize, not when you browse.
Five tests asserting "a rejected save persists nothing" failed and were right to.
Reverted; `cmd-list` now has no seeder at all.

And a test-hygiene one, paid for twice today: `WorkspaceTest` ran `async: true`
while mutating the global `:workspace_root`, and handed its temp folder to two
unrelated suites mid-run. Every other workspace-touching test in this repo is
already `async: false` with a comment saying why. Read the neighbours first.

### The shared working tree bit back

Mid-way through the audio consolidation the tree stopped compiling, and it was
not mine: **another session was live in the same checkout**, running a
lane→track rename (`StudioTrack` → `StudioAudio`, file renamed and staged) with
four consumers not yet updated.

Two things worth recording. First, their file replacement **silently reverted a
one-line edit of mine** — the `sounds/studio/tracks` nesting — which would have
resurrected a top-level `studio/` that the registry no longer declares. The
layout guard from Phase 0 would have caught that on the next run, which is the
first time one of today's guards paid for itself against something no human
would have noticed. Second, the right move was to *wait*, not to fix their
half-done refactor: two agents editing the same lines is worse than a few
minutes of idling. I re-applied only my own line and armed a poll.

The poll condition was wrong the first time — it watched `lib/` only, fired
while two test files still referenced the old module, and had to be re-armed
against `lib/` **and** `test/`. When waiting on someone else's refactor, the
condition is "the whole tree is consistent", not "the part I happened to look
at."

## 10. Open

**No visual pass was done.** Everything here is verified by the suite and by
reading the generated CSS (the arbitrary `calc()` normalization, and that
`lg:absolute`/`lg:inset-0` emit inside `@media (width >= 64rem)`), but the page
was never opened in a browser — the dev server is operator-run. The equal-height
grid behavior and the two live WebGPU previews sitting side by side are exactly
the kind of thing that reads fine in markup and surprises you on screen. First
launch should look at those two things.

**The workspace rebuild is 3 phases of 5.** *(Written mid-day; the later
sessions below closed all five — the roadmap was archived 08-02. Kept as
written, because what the remaining phases looked like from here is the record.)*
Remaining, in `archive/08-01-26-workspace-review-roadmap.md`:

- **Phase 3 (naming/grouping)** was deliberately deferred until the real list was
  visible. At eight entries it is now visible, and the recommendation is to
  *decline* the nesting option — grouping under `media/` buys tidiness at the
  cost of the flat, greppable folder that makes this thing worth having. Worth a
  decision, not more work.
- **Phase 4** moves `INTRODUCTION.md` out of the user's eyeline. Cheap, but easy
  to do incompletely: the guide, the skills and the job descriptions all name
  that path, and models orient by it.
- **Phase 5** is the acceptance test for all of it — point dev's
  `workspace_root` somewhere that is not the repo's parent (today it resolves to
  `~/Developer`, so we develop against a layout we would never ship), then walk
  a *packaged* install and count what a new user actually sees. Every phase
  above is judged by that one number and it has never been observed on a real
  install.

---

# Also 08-01, from the release-and-studio session

Two workstreams, one keyboard: the morning readied Apple distribution, the
afternoon turned the Studio's arranger into a small DAW.

## A. Apple: enrollment cleared, and the gate split in two

Enrollment cleared today — the constraint moved from *waiting on Apple* to
*doing the work*, and the next action is the Developer ID certificate (the
account sits at the certificates page; `~/Desktop/apple-dev-skills/` now holds
the walkthrough, including the CSR steps and the export-with-private-key trap).

- **`LAUNCH_ROADMAP.md` re-scoped around two releases** (operator call): R1 = a
  signed, notarized DMG for both arches handed to people we can email, ~1 week;
  R2 = the public download, where the updater, telemetry, download page, and
  privacy policy become mandatory. Every gate item tagged [R1]/[R2]. No feature
  freeze — so the gate prefers CI assertions, which survive merges, over manual
  checklists, which are only true for the commit they ran against.
- **CI now proves the artifact, not just the source.** `smoke_release_boot.sh`
  boots the bundled release headlessly (no GUI, Keychain, Chromium, or network)
  before signing and upload — verified to catch BLOCKER-1's exact shape. The
  full GUI smoke passed against a real 76 MB bundle: native bridge round trip,
  live render, headless Chrome over CDP, 157 commands.
- **The advertised macOS floor was a three-version lie** — declared 11.0 while
  all 24 OTP binaries require 14.0, so macOS 11–13 got a shell that launches
  and a VM dyld refuses. Corrected to 14.0 and asserted on every build
  (`check_macos_floor.sh`), because the floor is inherited from whichever
  Erlang built the release and moves silently with the toolchain.
- Also: tauri-cli aligned to 2.11.4 after finding the CI pin *could not take
  effect* (existence-guarded install + persistent cache), and the
  entitlements double-hyphen guard fixed — it matched `<!--` itself, so it
  could never pass. Every guard needs a passing input tested.

Pushed through `76c5ac4` this morning.

## B. The Studio's DAW day

Six commits, `0e1cf1a` → `208f7c9`, full detail in
`SOUND_STUDIO_ROADMAP.md` Phase 8. The shape of it:

- **Vocabulary swapped to DAW terms** through the whole stack — you create an
  **audio** and add **tracks** to it (`StudioTrack` → `StudioAudio`); the v1
  disk format keeps the old words on purpose, files being hand-editable.
- **Pro Tools clusters** left of each track (label, M, S, delete), with the
  geometry rule that `[data-track]` is only the clip region — a row-wide rect
  would land every drop early by one cluster width.
- **New audio / Import audio ride the home tab bar**, the row's right side now
  being the active tab's action slot; imports went `auto_upload` so choosing
  files IS the import.
- **Color became a language:** a three-color track palette (hazard / `#1C9BFF`
  / `#2FD068`) hanging off the label letter so a color survives its neighbor's
  deletion; waveforms colored by source kind with the kind badge as legend;
  hazard alone still means attention.
- **Mute and solo** with the exact DAW contract (solo beats mute, any-solo
  isolates), rendered honest: the mix uses `audible_clips/1`, silenced regions
  dim, and all-silenced earns its own refusal.
- **A transport.** Play performs the timeline the way Pro Tools does on the
  spacebar — WebAudio schedules the same routes the sidebar plays, at the
  offsets the server rendered, playhead swept by rAF; Render stays the bounce.
  Needs a human ear pass, and the packaged walk (Phase 5) now owes the
  WKWebView-autoplay check one more clause.

At close: 54 component / 27 schema / 120 JS tests green, credo strict clean.
The studio commits were held locally until the workspace relocation landed —
the import tests assert `sounds/studio/` paths that only exist with both
sessions' work in the tree.

## Session three — the workspace gets its names (Phases 3–5a)

The morning's registry work turned out to have quietly shipped Phases 0–2;
this session closed the rest of the roadmap on top of it.

- **Phase 3 decided (operator: option A, flat renames) and shipped.**
  `job-descriptions/` → `jobs/`, `appearance/` → `backgrounds/`,
  `shift/Dispatch.md` → a top-level `Dispatch.md`. The dated dispatch diary is
  machine bookkeeping, so it moved to `.buster-claw/dispatch/<date>/` rather
  than keeping a `shift/` folder alive for it.
- **Phase 4 shipped.** `INTRODUCTION.md` installs at
  `.buster-claw/INTRODUCTION.md`; the stale root copy is deleted by the layout
  migration, the onboarding prompts state the new path, and `README.md` is now
  the loudest file in the folder — which is the point.
- **Existing installs relocate safely.** The audio-consolidation `relocate`
  generalized into one `@relocations` table (merge-don't-clobber, keep-and-log
  on collision); machine-regenerated files (`INTRODUCTION.md`, the old fridge)
  are deleted rather than carried.
- **One real bug caught by its own test:** Appearance's workspace-relative
  Settings pointers must be prefix-rewritten *before* the image-pool migration
  runs — `next_empty_slot` trusts those pointers, and a stale `appearance/`
  prefix made a filled slot read as empty, landing the migrated home image on
  top of a terminal slot.
- **Phase 5a shipped.** Dev's `workspace_root` is `tmp/dev-workspace`
  (repo-local, gitignored, deletable-to-rescaffold) instead of `~/Developer` —
  we can finally look at what we ship. The packaged first-open walk remains,
  pinned to the R1 QA pass with the other packaged-build leftovers.
- The introduction's layout section stopped advertising `analysis/` and
  `projects/`, and now tells the agent not to invent top-level folders.

At close: full suite 2,095 tests, 0 failures. The workspace roadmap is done
except for the packaged walk.

### Addendum — the build, and the count

`build_desktop.sh` produced the unsigned 0.1.0 bundle + DMG (signing waits on
G-2, the Developer ID cert). `smoke_release_boot.sh` PASS — the bundle boots,
serves 157 commands, 401s a bad token. Then the walk the whole roadmap was
judged by: booting the packaged release against an empty folder scaffolds
**seven visible entries, every one with content** — README.md, buster-claw,
Dispatch.md, jobs/, library/, memory/, skills/ — machine files hidden in
.buster-claw/ and .claude/. Down from sixteen with seven empty. The workspace
roadmap is COMPLETE; only the setup-wizard/Finder formality rides with R1 QA.
