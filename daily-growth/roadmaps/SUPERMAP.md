# The Supermap

**Every part of Buster Claw, once, with the live map that governs it.**

Scoped 2026-08-09. Read this first to answer one question: **where is the build?**

---

## How to read it

Organised by the app, not by the roadmap folder — because a folder cannot show
absence. A section with no map is not a defect; it is a part of the product that
nothing currently plans, stated as a fact instead of discovered later.

**Only live maps appear here.** They live in `daily-growth/roadmaps/`. Closed
work is in `daily-growth/archive/` on purpose and is deliberately not linked —
if a section says `—`, there is nothing in flight, whatever was written before.

| State | Meaning |
|---|---|
| **SHIPPED** | built and in the app, nothing in flight |
| **ACTIVE** | a live map with unfinished phases |
| **SCOPED** | a map exists, no code |
| **PLACEHOLDER** | the surface exists and honestly says it is empty |

---

## This file is the spine

There is no separate release document. `LAUNCH_ROADMAP` was one 1,671-line file
until 08-09; it became seven maps, and then its remaining spine — status, order
and cost — dissolved into them too. **`LEFTOVERS` went the same way**, into three
maps filed by section. Nothing was lost; both are in git history if you want to
read how they read.

**This page is what replaced them.** It is the only index, and the only place
that answers *where is the build?*

That merits a warning, because the launch document carried one: **it had been
four files once before, and they disagreed with each other and with the code.**
Three rules keep that from recurring —

1. **No identifier changed.** Every `G-n` and `III.x` kept its number and its
   wording through both splits. Scripts and CI cite `III.E/F/G/J` by name
   (`codesign_release.sh`, `build_desktop.sh`, `Entitlements.plist`,
   `release-desktop.yml`); commits cite `G-n`. **Nothing was renumbered.**
2. **Each number lives in exactly one map.** `G-1`–`G-17` and `G-47` in Apple, `G-21`–`G-24` and `G-45`
   in Website, `G-25`–`G-35` in Trust and Support, `G-36`–`G-41` in Release Gate,
   and **`G-18`–`G-20` (incl. `G-19a`/`G-19b`), `G-42`–`G-44` and `G-46` in Update**. A number in two places is
   precisely the old failure mode — check before adding one.

   > **`G-18`–`G-20` moved from Apple to Update on 08-16, keeping their numbers.**
   > That is rule 1 and rule 2 working together rather than against each other:
   > a gate may change *home* when its subject does, but it never changes
   > *name* — commits and checklists cite `G-n`, and renumbering would break
   > every one of them. **Next free number: `G-48`.** (`G-45` claimed 08-18 by `WEBSITE`, for two false claims in the public `documentation.md`; `G-46` and `G-47` claimed 08-22 by `UPDATE` and `APPLE` — see [The R1 path](#the-r1-path--the-ordered-list-08-22).)
3. **Status has one home, and this is it.** What disagreed last time was *what
   state we are in*. Every map states its own phase; this page states which of
   them is next.

### The folder is the map

**Reorganised 08-09: `roadmaps/` now mirrors the parts below.** A map lives in
the folder of the section it governs, so the directory listing answers "what is
in flight for this area?" without opening anything.

```
roadmaps/
├── SUPERMAP.md ·············· this file — the only index
├── shell/ ·················· Part I    TERMINAL_PAINT
├── surfaces/ ··············· Parts II–III  STUDIO · SKETCH · IMAGE_SHADER · LEFTOVERS_SURFACES
├── agent-core/ ············· Part V    LEFTOVERS_AGENT_CORE
├── integrations/ ··········· Part VI   CLINCH · BUSTERPHONE (+NUMBER_VENDING) · PHONE_INTAKE · PHONE_ACCESS · GOOGLE_VERIFICATION
├── platform/ ··············· Part VII  APPLE · UPDATE · RELEASE_GATE · TRUST_AND_SUPPORT · QA_BACKLOG (+FRESH_MACHINE_WALK) · LEFTOVERS_PLATFORM
├── distribution/ ··········· Part VIII DISTRIBUTION · FRONT_DOOR
└── website/ ················ Part IX   WEBSITE
```

**Only this file sits at the root**, because it is an index *over* the folders —
filing it inside one would be a lie about its scope. Everything else lives in the
folder of the section it governs.

**Part IV — Settings has no folder.** Nothing is in flight there, and an empty
directory would read as an oversight rather than a fact.

**Two maps span sections and are filed by their primary owner**, not duplicated:
`FRONT_DOOR` is in `distribution/` though it also touches the shell's onboarding
wizard and the website's homepage, and `TRUST_AND_SUPPORT` is in `platform/`
though it also governs Settings → Security and Sentinel. **A map has one home;
the section tables below point at it from wherever else it applies.**

---

## Where the build is

1. **[The Clinch](#part-vi--integrations)** — **Phases 0–4 complete 08-10; Phase 5 is as far as an agent can take it.** Its preconditions are pinned (`18af12e`) and every remote-mode notice is guarded (`d26c4ad`). **What remains is the tunnel spike, and it needs a person with two machines** — the roadmap forbids the gateway and the panel until a real tunnel survives a WebSocket upgrade, an upload, a long Chat response and a laptop sleep.
2. **[BusterPhone](#part-vi--integrations)** — the only paid thing. **Inbound is live and carrying real traffic** (verified in the app 08-14, not inferred); the gap is vending a number to someone who is not the operator. **Scope narrowed 08-18: the phone becomes intake-only** and every outbound capability is deleted — a Twilio rejection made the price of sending legible, and the operator chose to stop paying it rather than resubmit. [`PHONE_INTAKE`](integrations/PHONE_INTAKE_ROADMAP.md) is the map; the paid tier is untouched.
3. **[Apple](#part-vii--platform--release)** — **`G-1`–`G-3` DONE 08-10: a notarized, stapled DMG exists.** ~~What is next is not code — an **Apple Silicon Mac**.~~ **Corrected 08-22: what is next IS code.** The first real rehearsal of the pipeline found three defects and a cycle — the floor was wrong on both arches (`G-16b`, fixed), the DMG was never notarized by anything but a human hand (III.H, fixed), and **`G-19` turns out to block every tagged release**. The Apple Silicon Mac is still needed, but only for `G-4`, which is now seventh on the list rather than next. See [The R1 path](#the-r1-path--the-ordered-list-08-22).
4. **[Studio → Voice Library](#part-ii-b--the-studio)** — built 08-16; **needs a person at a microphone.** Everything except capture is done and tested: banks, audition, sentence preview, and both recording paths. What has never run is V.4a — `getUserMedia` in a packaged build — and until someone clicks that dialog the recorder is honest rather than working.
5. **[The Dialyzer gate](#part-vii--platform--release)** — **GREEN, exit 0, verified 08-16.** The baseline is a rule rather than a file list (`1d52cff`) and that fix has held; the three unreachable `refusal/2` clauses that 08-15 added were deleted 08-16 rather than baselined. Part VII records what the deletion cost.
6. **The whole-codebase review (08-13)** — **ARCHIVED 08-15**, [`CODE_REVIEW_08-13-26.html`](../archive/CODE_REVIEW_08-13-26.html): every part with its argument, every large file diagnosed feature-sized vs overloaded, 21 ranked findings. **The top four landed same-day** — the gmail attachment fence (`1728e64`), both `chat.ex` contract bugs (`20a36a9`), the dead Trading hooks plus a both-directions hook guard (`577085e`). Everything else is **filed, not floating**: by section into the LEFTOVERS maps — [agent-core](agent-core/LEFTOVERS_AGENT_CORE.md), [platform](platform/LEFTOVERS_PLATFORM.md), [surfaces](surfaces/LEFTOVERS_SURFACES.md), and the shell's first, [`LEFTOVERS_SHELL`](shell/LEFTOVERS_SHELL.md), created for it. The review's two structural conclusions: the size gate covers no core/JS/Rust file (its §12 has the 19-file proposed inventory), and `commands/sound.ex` at 2,514 is the one file where the 08-08 "commands/ is correct" ruling no longer holds.

7. **The two product reviews (08-16)** — **FILED AND ARCHIVED the same day.**
   [Novice](../archive/NOVICE_AI_APP_REVIEW.md) and
   [year-one](../archive/YEAR_ONE_SURVIVAL_REVIEW.md). Five of the novice
   review's seven P0 items turned out to be **rediscoveries** of `VI-a`/`VI-e`/
   `VI-f` and `G-30` by a reader with no access to these maps — good evidence the
   maps aim at real things, and equal evidence that **writing an item down does
   nothing for it**. Three findings were new (`VI-h`/`VI-i`/`VI-j`). The year-one
   review ended Scene3D and is otherwise deliberately unfiled: it asks for a Home
   rebuild and then says the product needs usage data first, which is the
   argument against acting on it yet.

8. **[The Sketch Pad](#part-ii-b--the-studio)** — **Phases 0–4 built 08-16, none of it walked.** The Studio's third tab became a surface the operator and the model share: strokes, images and text as addressable elements, six `sketch_*` commands, and a boundary drawn by **authorship rather than tier** — the model may change and delete what the model drew, and asking about yours. Three things only the parallel build found: **no command had ever known its caller** (`D13`), a `gated` flag would have made the feature impossible, and the gate **did not actually surface** until the refusal was wired into Sentinel.
9. **[The update path](#part-vii--platform--release)** — **`G-42` and `G-18` shipped 08-16; `G-44`'s first half shipped 08-18.** The seed-rot phase stopped being a `[R2]` design note the day BusterPhone's deletion left every existing workspace holding a job brief that named a deleted command — `BusterClaw.Seed` now upgrades a seed whose bytes still match any version we shipped, and leaves an edited one alone. Jobs' four files are converted; Skills and TerminalCommands are not, and `policy.md` is deliberately excluded. **`G-42` and `G-18` shipped 08-16.** The app can finally say what version it is, and CI can publish a signed feed. **Neither has run**: the workflow is tag-only, and the minisign keypair does not exist yet. `G-19` — the button itself — is next, and its one sharp edge is already written down (the release monitor will respawn the BEAM into a bundle being swapped unless `shutting_down` is set first).

**Seven of those wait on the operator rather than an agent**, and the list grew
again on 08-18 rather than shrank:

- the `getUserMedia` spike needs a permission dialog clicked at a packaged build
- **`G-4` needs an Apple Silicon Mac** — a dependency this repo had recorded
  backwards until 08-10
- the **minisign keypair** must be generated and **backed up offline before the
  first signed release**. There is no revocation: the public key is compiled into
  every shipped binary, so a rotated key is *rejected* by the installs it was
  meant to reach
- the update feed's endpoint needs a **rewrite in the website repo**, which
  nothing here can add and nothing here fails without
- the Sketch Pad needs someone to watch a model be **refused** — the one
  behaviour its whole design exists for
- BusterPhone's **toll-free verification must be withdrawn** — it is a live
  application for a capability that was deleted on 08-18. Tidiness rather than
  urgency: verification governs *messaging*, so the number answers calls either
  way
- someone must **text the toll-free number once** and confirm it lands in the
  app. Inbound voice is certain; inbound SMS on an unverified toll-free number
  is the one claim in the intake-only cut that was reasoned to rather than
  walked, and the last confirmed inbound walk was 08-14 on a number released the
  next day

**Six of the seven are unblockable by any amount of code**, which is the honest
reading of where the build is: the writing is ahead of the walking.

**First movement on the release path since 08-01.** `G-2` and `G-2b` both landed
08-10: a Developer ID certificate (team `KD977J8NF6`, valid to 2031) and App Store
Connect notary credentials (key `SAKNAF6YLA`). **All five release secrets are set**,
`HAVE_APPLE_CERT` is `true`, and CI produces signed builds with no workflow edit.

**Then the pipeline itself ran, and passed on the first attempt.** A signed `.app`
and a signed **27 MB x86_64 DMG** were built from current `main`, Apple returned
**`Accepted` / "Ready for distribution" with zero issues**, and both artifacts were
stapled.

> ### Corrected 08-22 — two of the sentences above described an afternoon, not a pipeline
>
> This block used to end: *"All eight machine-checkable III.J exit tests pass …
> `stapler validate` on the `.app` and the `.dmg`,"* and *"A distributable macOS
> app exists — it opens on a stranger's Intel Mac with no dialog."*
>
> **Both were true of 08-10 and neither was true of the build system.** The `.dmg`
> was stapled that day because the operator ran `notarytool` and `stapler` by hand
> after `build_desktop.sh` finished; those commands were never scripted, so **every
> CI build since produced an un-stapled image.** Caught 08-22 by the III.J
> assertion running in CI for the first time, on both architectures. Fixed in
> `44e8bd6`. See [`APPLE`](platform/APPLE_ROADMAP.md) III.H.
>
> And no stranger's Mac has ever opened it. The 08-10 artifact was verified on the
> machine that built it, which is the one machine where Gatekeeper proves least —
> see `FM-2` and `DL-1` in
> [`FRESH_MACHINE_WALK`](platform/FRESH_MACHINE_WALK.md).
>
> **The generalisable failure**, because it has now happened twice in this file:
> a manual step taken during a successful milestone gets written down as a
> property of the system. Anything done by hand to make a gate pass has to land in
> a script in the same sitting, or it becomes a claim with a date on it that
> outlives its truth.

---

## The R1 path — the ordered list, 08-22

**Why this section exists.** The first real rehearsal of the release pipeline
(three runs, 08-22) found three defects and one *cycle*, and the cycle spans
three maps. Rule 3 above puts sequencing here rather than in any of them.

**The destination is one sentence: a stranger downloads Buster Claw and it
opens.** Everything below is ordered by what blocks what, not by importance.

### The cycle, first — it is the thing that changed

> A `v*` tag fails closed without `TAURI_SIGNING_PRIVATE_KEY` → setting that
> secret flips `build_desktop.sh:146` to `createUpdaterArtifacts` → that requires
> a `plugins.updater` block → that block is **`G-19`**, unbuilt.
>
> **A tagged release requires the key, the key requires the plugin, the plugin is
> `G-19`.** It was tracked as an R2 product feature — a button in Settings. It is
> a prerequisite for shipping anything at all.

### The path

| # | Step | Blocked by | Map |
|---|---|---|---|
| 1 | **An artifact exists** — signed, notarized, stapled, both arches | *in flight 08-22* | [`APPLE`](platform/APPLE_ROADMAP.md) |
| 2 | **Walk it on a machine that has never seen it** | 1 | [`FRESH_MACHINE_WALK`](platform/FRESH_MACHINE_WALK.md) |
| 3 | **`G-46` — make the trap loud** | nothing | [`UPDATE`](platform/UPDATE_ROADMAP.md) |
| 4 | **`G-19a` — make a tag possible** | nothing | [`UPDATE`](platform/UPDATE_ROADMAP.md) |
| 5 | **Tag → a real Release with a real URL** | 4 | [`APPLE`](platform/APPLE_ROADMAP.md) |
| 6 | **`G-21` / `G-24` / `G-45` — the site stops lying and points at 5** | 5 (partly) | [`WEBSITE`](website/WEBSITE_ROADMAP.md) |
| 7 | **`G-4` — the arm64 walk on real hardware** | an Apple Silicon Mac | [`RELEASE_GATE`](platform/RELEASE_GATE_ROADMAP.md) |
| — | **`G-47` — credential hygiene** | nothing | [`APPLE`](platform/APPLE_ROADMAP.md) |

**Steps 3, 4 and `G-47` are unblocked right now** and are the only things on this
list that a session can start without waiting for a machine, a person, or Apple.

### Two notes that change the size of the work

**`G-19` should be split, and step 4 is why.** Producing a valid updater artifact
needs the `plugins.updater` config and a compiled-in pubkey. It does **not** need
the button, the `shutting_down` race, the database backup, or the swap sequence —
that is `G-19`'s Phase 3 and it is the expensive half. Splitting off **`G-19a`
(the config exists and a tag can build)** from **`G-19b` (the button works)**
unblocks releasing without buying the whole feature.

> **`G-19a` is a one-way door and must not be treated as a config tweak.** The
> pubkey compiles into every binary and there is no revocation, so the keypair
> chosen at that moment is permanent for every install that follows. The pair
> generated 08-22 is the candidate; **confirm it is backed up offline before the
> block is written**, not after.
>
> **Unverified and worth ten minutes before starting:** whether the config block
> alone satisfies the bundler, or whether `tauri-plugin-updater` must also be a
> Cargo dependency and registered in `main.rs`. That answer decides whether
> `G-19a` is an hour or a day, and it is cheap to establish with one
> `workflow_dispatch`.

**Step 6 is not all blocked on step 5.** The download *URL* needs a release, but
three of the site's false claims need nothing: the macOS floor (now **15.0**,
moved twice in three weeks), *"Linux — Supported, AppImage, .deb"*, and the
paragraph promising background auto-updates through a *"Tauri updater plugin"*
that does not exist. Those are wrong today and stay wrong until edited. **Fix the
lies before building the link.**

**Next free number after this section: `G-48`.**

**The Apple map's "exercised" column went from empty to five marks in one day**
([`APPLE`](platform/APPLE_ROADMAP.md) III.0), each earned by running the thing.

**Two findings outrank the green checks.** First, **current `main` still packages** —
the staging assertion held against a tree 254 commits and +50k/−15k lines past the
last packaged build, which nobody had verified. Second, **the architecture dependency
was recorded backwards**: the dev machine *is* the Intel Mac, and what is missing is
an **Apple Silicon** one — the majority slice, never built outside CI, never signed,
never launched.

**What remains has no prior.** The pipeline was a strong prior and it held; **first
launch on a machine that did not build the app is not** — the TCC prompt, no-`claude`,
no-Homebrew and offline paths have never been watched by anyone.

**And one measured surprise: notarization took about five and a half hours**, against
published guidance of "minutes to an hour", with the notary service green throughout
and zero issues in the verdict. Budget hours per release, not minutes
([`APPLE`](platform/APPLE_ROADMAP.md) III.H).

---

## Part I — The shell

| Section | Where | State | Map |
|---|---|---|---|
| Dock navigation | `DockNavLive` | SHIPPED | — |
| Dock strip (chips, sticky player) | `DockLive`, `MusicPlayerLive` | SHIPPED | — |
| **The visible brake** | `DutyLive`, `Orchestration.stand_down/1` | **SHIPPED 08-16 — `G-30`, promoted R2 → R1.** A fourth sticky dock LiveView: invisible when idle, a **Stand down** button whenever a shift runs. Stops new work at once; a run in flight finishes, and the surface says so | [`TRUST_AND_SUPPORT`](platform/TRUST_AND_SUPPORT_ROADMAP.md) `G-30` |
| First-run onboarding | `SetupLive` `/setup` | SHIPPED | [`FRONT_DOOR`](distribution/FRONT_DOOR_ROADMAP.md) — the wizard is one of four surfaces that must agree |
| Appearance — skins, text size, backgrounds | `AppearanceLive` `/appearance` | SHIPPED | — |
| **The macOS Dock icon** | `Pockets.AppIcon`, `app_icon_set` | **BUILT 08-15** — drop an image in `pockets/app-icon/` and apply it; keyed to the file's bytes, so replacing it reverts to the shipped icon. The bundle icon stays sealed by the signature. **The native half is unwalked** — see [`QA_BACKLOG`](platform/QA_BACKLOG.md) | archived 08-17 · the unwalked native half is [`QA_BACKLOG`](platform/QA_BACKLOG.md)'s |
| Terminal themes | `TerminalTheme` | SHIPPED · operator walk open | archived 08-17 · the walk is [`RELEASE_GATE`](platform/RELEASE_GATE_ROADMAP.md)'s, gate `G-40` |
| Terminal paint — the agent recolours itself | — | **SCOPED** | [`TERMINAL_PAINT`](shell/TERMINAL_PAINT_ROADMAP.md) |

---

## Part II — Home

`StatusLive` at `/`. **Seven** sub-tabs plus a corner widget with three of its own.

> **The Studio left Home on 08-16** and is its own route now (`StudioLive` at
> `/studio`), so its three tabs moved to Part II-b below. This heading said
> "eight sub-tabs" and listed Studio here for most of a day after that stopped
> being true — the drift a route change makes, found while filing the Sketch Pad
> rather than by reading.

| Section | Where | State | Map |
|---|---|---|---|
| Chat | `ChatPanel`, `status/chat.ex` | SHIPPED | [`LEFTOVERS_SURFACES`](surfaces/LEFTOVERS_SURFACES.md) — the live-CLI attachment walk |
| Notes | `NotesComponent` | SHIPPED | [`LEFTOVERS_SURFACES`](surfaces/LEFTOVERS_SURFACES.md) — renaming orphans `[[wiki links]]` |
| Pockets | `PocketsPanel` | SHIPPED | archived 08-17 — the Dock walk is [`QA_BACKLOG`](platform/QA_BACKLOG.md)'s |
| Calendar | `CalendarComponent` | SHIPPED | — |
| Phone | `PhoneComponent`, `Phone.CallAction` | SHIPPED — **the keypad dials as of 08-15**, gated and confirmed once before the first ring | [`BUSTERPHONE`](integrations/BUSTERPHONE_ROADMAP.md) |
| Explained | `ExplainedPanel` | SHIPPED | [`LEFTOVERS_SURFACES`](surfaces/LEFTOVERS_SURFACES.md) — two errands, five tiles |
| Activity | `ActivityComponent` | SHIPPED | — |
| Widget → Time & Place | `status/weather.ex` | SHIPPED | — |
| Widget → Contacts | `BusterClaw.Contacts` | SHIPPED | — |
| Widget → Notify | `NotifyLive` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](agent-core/LEFTOVERS_AGENT_CORE.md) — the chime designer |
| Background shader | `Shaders` | SHIPPED | — |
| **Agent-applied shaders** | `Appearance.ShaderApproval` | **COMPLETE 08-15** — a workspace shader applies by command once the operator has applied its exact bytes themselves; editing withdraws it. Existing shaders backfilled. The property kept: GPU code no human has looked at cannot reach the screen from a command | archived 08-17 |
| **The corner widget's sky** | `Widget.PlacePanel`, `Appearance` surface `:widget` | **COMPLETE 08-15, all five phases** — `home_widget.ex` decomposed 699 → 135 (FROZEN → HELD), `:widget` is a real surface with `daycycle` as a default nothing can select, the panel follows it live, and `data-daylight` derives from the SHADER so daycycle keeps its clock anywhere. `default` is a mode on every surface and the only way back to the sky | archived 08-17 |
| Image-reactive shaders | `ShaderCanvas`, `Appearance.image_shader_options/0` | SHIPPED — Phase 4 (the skill) open | [`IMAGE_SHADER`](surfaces/IMAGE_SHADER_ROADMAP.md) |
| The home screen's primary action | `StatusLive`, `ChatPanel` | **SHIPPED — and says the right thing as of 08-16.** One of four surfaces now carrying the front-door sentence; guarded by `front_door_test.exs` | [`FRONT_DOOR`](distribution/FRONT_DOOR_ROADMAP.md) `VI-a` DONE |

**Every surface in Home renders something real.** *(The Voice Library sentence
that used to close this paragraph moved to Part II-b with its subject.)*

**Two things it can do that nothing else in the app could.** A word recorded on
its own is the corpus's first `:manual` origin at confidence 1.0 (all 655
existing takes are `:aligned`, a proportional guess capped at 0.9). A whole
sentence recorded in one take is V.8's donor session in miniature — far faster
per word, and every interior boundary an estimate, which the surface says.

**What is unproven is the microphone itself.** V.4a has never been run, so the
capability gate reports what the browser actually answered rather than claiming
either way; in Chrome and `cargo tauri dev` it may work today, and a packaged
build will name what stopped it. `Entitlements.plist` is deliberately untouched
— see the note under Part VII on what granting it costs the embedded browser.

---

## Part II-b — The Studio

`StudioLive` at `/studio`. Three tabs, one rail. Moved out of Home on 08-16.

| Section | Where | State | Map |
|---|---|---|---|
| **Studio → Mix** | `SoundStudioComponent` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](agent-core/LEFTOVERS_AGENT_CORE.md) — `commands/sound.ex` is owed a split |
| **Studio → Voice Library** | `Studio.VoiceLibrary`, `Studio.VoiceState`, `Studio.RecorderState` | **BUILT 08-16 — one tab, sidebar over Words / Sentence / Record.** Voice banks (V.0), audition (VI.1 pane 2), sentence build-and-play through the same `Cutup.Sentence` an agent uses, and a recorder for a word *or* a whole sentence. **The microphone is unproven** — V.4a has never run, so the capability gate reports what the browser found rather than claiming | `STUDIO` (map deleted 09-02-26 — the cut-up engine is its own project now) |
| **Studio → Sketch Pad** | `SketchComponent`, `Sketch.*`, `commands/sketch.ex` | **PHASES 0–4 COMPLETE 08-16, and UNWALKED.** A drawing the operator and the model share. Strokes, images and text as **addressable elements** — the substrate reversed from a canvas, because you cannot delete a stroke from a bitmap. Drop/paste/drag images, undo, autosave to `sketches/*.json`. Six `sketch_*` commands: the model reads a sketch as elements **and** a rendered PNG, and draws on it bounded by **authorship, not tier** | [`SKETCH`](surfaces/SKETCH_ROADMAP.md) |

**Voice Library is now the whole loop rather than half of it**: browse the words,
hear a take, build a sentence, hear that, record what was missing. The binding
constraint is still measured — **144 of 237 words are single-take**, none ever
hand-corrected — and the recorder is what changes it.

**Two of the three are built and unwalked, for different reasons.** Voice Library
needs a person at a microphone (`getUserMedia` has never run in a packaged
build). The Sketch Pad needs a person to watch the one thing its whole design is
for — a model trying to delete the operator's mark and being **gated, not
obeyed**. Both are asserted in code; neither has been seen.

---

## Part III — Full-screen surfaces

| Section | Where | State | Map |
|---|---|---|---|
| Workspace | `WorkspaceLive` `/workspace` | SHIPPED | — |
| Browser | `BrowseLive` `/browse`, `BrowserControl` | SHIPPED | [`LEFTOVERS_SURFACES`](surfaces/LEFTOVERS_SURFACES.md) · gate `G-34` — the payment gate is unwalked |
| Split view | `SplitLive` `/split` | SHIPPED | — |
| Terminal | `TerminalLive` `/terminal` | SHIPPED | — |
| The Manual | `UserGuideLive` `/manual` | SHIPPED | [`LEFTOVERS_SURFACES`](surfaces/LEFTOVERS_SURFACES.md) — no test, worst drift of any surface |
| Music library | `MusicComponent` (inside Studio → Mix) | SHIPPED | [`LEFTOVERS_SURFACES`](surfaces/LEFTOVERS_SURFACES.md) · gate `G-35` — `nosniff`, **HIGH** |

---

## Part IV — Settings

Seven sub-tabs, one literal in `SettingsTabs`. All shipped, none in flight.

| Section | Where | State | Map |
|---|---|---|---|
| Appearance | `AppearanceLive` | SHIPPED | — |
| Voice (TTS only) | `VoiceLive` | SHIPPED | — |
| Notify | `NotifySettingsLive` | SHIPPED | — |
| Integrations | `IntegrationsLive` | SHIPPED | — |
| Configuration | `SettingsLive` | SHIPPED | — |
| Cmd List | `CmdListLive` | SHIPPED | — |
| Security | `SecurityLive` | SHIPPED, **buried** | [`TRUST_AND_SUPPORT`](platform/TRUST_AND_SUPPORT_ROADMAP.md) `G-32` |

---

## Part V — The agent core

Not surfaces. The machinery every surface sits on.

| Section | Where | State | Map |
|---|---|---|---|
| Command surface & catalog | `Commands`, `commands/catalog/` | SHIPPED | — |
| Agent runner & backends | `AgentRunner`, `AgentBackend` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](agent-core/LEFTOVERS_AGENT_CORE.md) — `agent/chat.ex` owed a cut |
| Model policy | `ModelPolicy` | SHIPPED | — |
| Policy engine & trust tiers | `PolicyEngine`, `AgentToolPolicy` | SHIPPED | — |
| Sentinel — audit & notify | `Sentinel` | SHIPPED, **claims outrun it** | [`TRUST_AND_SUPPORT`](platform/TRUST_AND_SUPPORT_ROADMAP.md) `G-29`–`G-31` |
| Dispatch, orchestration, swarm | `Dispatch`, `Orchestrator`, `swarm/` | SHIPPED | — |
| Skills | `Skills` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](agent-core/LEFTOVERS_AGENT_CORE.md) — two seeds uncombed |
| Memory | `Memory` | SHIPPED | — |
| Shaders — the authoring machinery | `Shaders` | SHIPPED | — |
| Library, analyzer, ingest, journal | `Library`, `Analyzer`, `ingest/` | SHIPPED | — |

---

## Part VI — Integrations

| Section | Where | State | Map |
|---|---|---|---|
| **The Clinch — credentials** | `Clinch`, `ClinchPanels`, Tauri `clinch_*` | **ACTIVE — Phases 0–4 COMPLETE 08-10; Phase 5 guarded 08-13, now waiting on the operator's tunnel spike** | [`CLINCH`](integrations/CLINCH_ROADMAP.md) |
| **Reaching it from a phone** | the relay, as a control channel | **PARKED 08-13 — research done, starts after the desktop app ships** | [`PHONE_ACCESS`](integrations/PHONE_ACCESS_ROADMAP.md) |
| **Twilio / BusterPhone** | `Telephony` | **ACTIVE — the money leg. Inbound LIVE (verified in the app 08-14).** As of 08-18 the phone is **deliberately intake-only**: it answers, records, transcribes, files, and archives inbound text, and sends nothing. That is now the design rather than a limitation — see the row below. What remains is vending a number to somebody else | [`BUSTERPHONE`](integrations/BUSTERPHONE_ROADMAP.md) · [`PHONE_INTAKE`](integrations/PHONE_INTAKE_ROADMAP.md) |
| **BusterPhone becomes intake-only** | `Telephony`, `Explained.Phone` | **SHIPPED 08-18 (`e08d1cd`) — Phases 1, 2, 4, 5 the same day; Phase 0 and 3 are the operator's. Supersedes the three rows below.** Twilio rejected the toll-free verification 08-17 (`30484`, business name); rather than resubmit, **every outbound capability is deleted** — SMS *and* calling. Deletes the whole compliance stack with it: the verification, the consent disclosure, the public opt-in page, `SMS_DISCLOSURE` unbuilt. **47 files, +1,161/−2,752**, six deleted whole, 217 → 215 commands, 4,187 tests green. The paid tier is unaffected — 07-12 already ruled voice/voicemail shippable with no A2P | [`PHONE_INTAKE`](integrations/PHONE_INTAKE_ROADMAP.md) |
| Outgoing texts | `sms_send`, kill-switched | **TO BE DELETED — superseded 08-18.** ~~Built, blocked on paperwork; 10DLC abandoned 08-15 for toll-free verification, `HH0fb442c8…` IN_REVIEW.~~ That verification was **REJECTED 08-17** (`30484` — *Business Name Must Match Official Records*; filed as `hightowerbuilds`, which is on no government record). Not resubmitting | [`PHONE_INTAKE`](integrations/PHONE_INTAKE_ROADMAP.md) Phase 1 |
| **The SMS consent story** | `Explained.Phone` | **CANCELLED UNBUILT + ARCHIVED 08-18.** Its subject stopped existing with outbound SMS. Its Part II inventory of false claims was **consumed, not orphaned** — it is the map that rewrote `Explained.Phone` (701 → 591), and the one claim it said to preserve, that inbound traffic is still A2P-*classified*, is still on the page under `[data-phone-a2p]` | archived 08-18 |
| Outgoing calls | `phone_call`, `Phone.CallAction` | **TO BE DELETED — superseded 08-18.** Shipped 08-15 and needed no A2P at all; it is being cut on **product** grounds, not paperwork — a distinction `PHONE_INTAKE` Part I exists to keep straight | [`PHONE_INTAKE`](integrations/PHONE_INTAKE_ROADMAP.md) Phase 2 |
| The relay (Supabase) | `telephony/relay.ex` | SHIPPED — **now erases, 08-10** | [`BUSTERPHONE`](integrations/BUSTERPHONE_ROADMAP.md) — pre-08-10 backlog sweep · [`LEFTOVERS_PLATFORM`](platform/LEFTOVERS_PLATFORM.md) — rotated DB password |
| Google Workspace | `Google` (16 modules) | SHIPPED | [`GOOGLE_VERIFICATION`](integrations/GOOGLE_VERIFICATION_ROADMAP.md) — restricted scopes, CASA |
| Operational — GitHub | `Integrations` | SHIPPED | — |
| Web search & data sources | `catalog/web.ex`, `Search` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](agent-core/LEFTOVERS_AGENT_CORE.md) — persisting macro series |
| Weather | `Weather` | SHIPPED | — |
| Notes That Float / Shadiox | outside this repo | **SCOPED** | — |

**The Clinch's Phase 3 landed 08-10, so BusterPhone is no longer blocked on it.**
Twilio and Supabase credentials now live in the Clinch and can be entered from
Settings → Configuration, which is what makes the paid tier configurable in a
packaged build at all — a double-clicked `.app` inherits launchd's environment,
not your shell's.

~~BusterPhone's remaining actions are the operator's, in order: upgrade Twilio →
wire the Voice webhook → enter the credentials → call it.~~ **All four are done,
and this page did not know it until someone opened the app on 08-14.**

**The inbound leg is live and carrying real traffic.** The Message Machine shows
voicemails from Jul 30, Aug 08 and Aug 11 with Twilio transcripts, durations and
**per-message cost** (\$0.0525 each, \$0.63 tracked), plus an inbound SMS. So the
whole chain — Twilio → the Supabase relay → `Telephony.Drain` → the surface —
works end to end on the operator's own number, which is the thing this map spent
weeks describing as pending.

**What that does and does not prove.** It proves inbound voice, inbound SMS and
cost sync. It does **not** prove the product: **nobody has ever been vended a
number**. (Outbound calling was unbuilt when this was written; `phone_call` and
the keypad's Call button both shipped 08-15 — see `archive/08-17-26-outbound-voice.md`.
Outbound *SMS* is still blocked on A2P, which is a different registration and a
different problem.) The
paid tier is "we are the phone company for someone who is not you," and every
step verified here happened on the operator's own line.

> Recorded plainly because it is the second time in two days a map described
> shipped work as pending. The status was knowable in about ninety seconds by
> clicking the Phone tab, and nobody had. **Credentials still belong in the app
> rather than the environment** — a double-clicked `.app` inherits launchd's
> environment, not your shell's — and entering them starts the drain on its next
> 30-second tick.

> **Rotation works: `./buster-claw clinch rotate --confirm`.** A CLI verb rather
> than a catalog command, because rotation is credential *management* and no agent
> should reach it. The new key is printed before anything is re-encrypted, and
> writing it to the Keychain stays the operator's step — stated in the output, not
> hidden.
>
> **And the in-app terminal now has its own token.** It ran on the full one, so an
> agent at that prompt could manage credentials — the thing the Clinch exists to
> prevent. It is trusted-equivalent for commands (the dispatch loop is untouched)
> and refused for management. **Phase 5 can start.**

---

## Part VII — Platform & release

| Section | Where | State | Map |
|---|---|---|---|
| Tauri desktop shell | `desktop/tauri/` | SHIPPED | — |
| **Apple — sign, notarize, staple** | CI, `scripts/codesign_release.sh` | **`G-1`–`G-3` DONE 08-10 (x86_64). `G-4` blocked on an arm64 Mac** | [`APPLE`](platform/APPLE_ROADMAP.md) |
| **Updating a running install** | `BuildInfo`, Settings → About, `release-desktop.yml`, `main.rs` release monitor | **`G-42` + `G-18` SHIPPED 08-16 — the app says what it is, and CI can publish a feed.** Took `G-18`–`G-20` from `APPLE` §III.I keeping their numbers; `G-42`–`G-44` new — and **`G-44`'s Jobs half landed 08-18** (`BusterClaw.Seed`), four months ahead of its `[R2]` slot, because the intake-only cut turned it from a slow-rot design note into a live correctness bug. **The pipeline has never run** (tag-only), and four things are the operator's: generate the minisign keypair, **back the private key up offline — there is no revocation**, set the two repo secrets, add the Vercel rewrite in the *website* repo. `G-19` (the button) is next | [`UPDATE`](platform/UPDATE_ROADMAP.md) |
| **The release gate** | — | **ACTIVE** | [`RELEASE_GATE`](platform/RELEASE_GATE_ROADMAP.md) |
| **Trust claims & support** | `Sentinel`, — | **ACTIVE** | [`TRUST_AND_SUPPORT`](platform/TRUST_AND_SUPPORT_ROADMAP.md) |
| CI gates | `scripts/check_*.sh` | SHIPPED, **all green** — Dialyzer included, 08-16 (below) | — |
| Code health | — | SHIPPED | [`LEFTOVERS_PLATFORM`](platform/LEFTOVERS_PLATFORM.md) — hotspots, guards, no DOM harness |
| QA debt (blocks nothing) | — | OPEN | [`QA_BACKLOG`](platform/QA_BACKLOG.md) |

**🟢 The Dialyzer gate is green — exit 0, `Total errors: 298, Skipped: 298`,
measured 08-16.** It was red that morning with 3, and this row said 56; the build
list said green. All three numbers were true once, which is why the fix was to
*run it* rather than pick a line to believe.

- **08-13 (`1d52cff`) really did take it to exit 0**, by making the baseline a
  *rule* rather than a list of 76 files. That fix held throughout — every one of
  the 298 skips is the rule doing its job.
- **What broke it was 08-15's appearance work**: three `refusal/2` fallback
  clauses in `commands/appearance.ex` that `Appearance.set_background/2` could
  never reach, since it returns exactly
  `:empty_slot | :invalid_mode | :not_image_reactive` — and `set/2` catches
  binary reasons in its own clause first. **Deleted 08-16** (operator call);
  the gate went green with no baseline entry added.

> **One thing the deletion cost, measured rather than assumed.** A fourth error
> reason was introduced on `appearance.ex:617` as a probe, and **neither gate
> caught it** — Dialyzer stayed at exit 0 and all 28 `commands/appearance_test.exs`
> tests passed, while `refusal/2` would have raised `FunctionClauseError` at
> runtime. The trade was taken knowingly: three clauses that can never run are not
> worth a red gate everyone learns to ignore. The comment at the deletion site
> records it, and `appearance_test.exs:237` is where a guard goes if that stops
> looking right.

---

## Part VIII — Distribution

Who gets it, what they pay, and how we find out whether anyone wants it.

| Section | Where | State | Map |
|---|---|---|---|
| **Tiers, margin, the paid pitch** | — | **ACTIVE** | [`DISTRIBUTION`](distribution/DISTRIBUTION_ROADMAP.md) |
| **Concept testing** — five falsifiable claims | — | **ACTIVE, can start today** | [`DISTRIBUTION`](distribution/DISTRIBUTION_ROADMAP.md) `IX.1`–`IX.5` |
| The front door — one sentence, four surfaces | README, site, `SetupLive`, `ChatPanel` | **`VI-a` DONE 08-16** — *"An assistant on your Mac that uses your tools, keeps working, and shows you what it did."* All four say it; three are guarded, the website is not and cannot be from here. `VI-d`/`VI-h`/`VI-i`/`VI-j` closed with it | [`FRONT_DOOR`](distribution/FRONT_DOOR_ROADMAP.md) |
| The bill | — | measured | [`DISTRIBUTION`](distribution/DISTRIBUTION_ROADMAP.md) |
| Anything paid | — | **not started, on purpose** | [`DISTRIBUTION`](distribution/DISTRIBUTION_ROADMAP.md) |
| **Source model** | `LICENSE`, `TRADEMARK.md`, README | **RELICENSED 08-10 — PolyForm Shield 1.0.0** | [`DISTRIBUTION`](distribution/DISTRIBUTION_ROADMAP.md) |

**Free beta first, charge later** is a locked decision — nobody needs to be able
to pay for either release to succeed. The one thing worth charging for is a phone
number, because it costs us real money per user per month, which is what honestly
earns a recurring price. **Everything else is free by construction:** `on-duty`
runs on the user's own machine against their own Claude, and Google Workspace is
goodwill.

**The cheapest high-leverage work in the whole build lives here.** `VI-a` — make
the README, the website, the wizard and the home screen say one sentence — is
hours of deletion and rewording, and `IX.1` measures whether it worked for the
cost of an afternoon.

**And the front-door problem has already cost something real.** On 08-10 the
public repo and the public website were found stating **opposite legal terms**:
the site had said *"source-available, not open source — redistribution is not
granted"* since 07-27, while `LICENSE` shipped MIT and the README said *"fork it,
sell it, build on it."* Resolved the same day in the site's favour (PolyForm
Shield 1.0.0), **but the MIT grant already published cannot be withdrawn** and
that window is permanent. **No test in this repo could have caught it** — the
contradicting statement lived in another repository. Four surfaces telling four
stories is usually a marketing problem; here it was a licensing one.

---

## Part IX — busterclaw.lol

The website, where the public finds the app. **A separate repo** — which is why
it kept getting deferred inside a roadmap about signing binaries.

| Section | Where | State | Map |
|---|---|---|---|
| `/` homepage | separate repo (Vercel) | 200 — **headline already matches the README**; body copy had four false claims, **fixed 08-16, undeployed** | [`WEBSITE`](website/WEBSITE_ROADMAP.md) `G-23` · [`FRONT_DOOR`](distribution/FRONT_DOOR_ROADMAP.md) |
| The download page | `#/downloads/busterclaw` | **EXISTS — and its button points at `DOMAIN-TBD.invalid`** | [`WEBSITE`](website/WEBSITE_ROADMAP.md) `G-21` |
| Privacy + terms | `/busterphone/*.html` | **200, BusterPhone-scoped** — site-wide versions still owed | [`WEBSITE`](website/WEBSITE_ROADMAP.md) `G-22` |
| Path routes (`/download`, `/privacy`) | — | **404 by construction** — the site is hash-routed with no rewrites | [`WEBSITE`](website/WEBSITE_ROADMAP.md) `G-21` |
| Stated floor + Claude requirement | — | not stated | [`WEBSITE`](website/WEBSITE_ROADMAP.md) `G-24` |
| The landing-page test | — | **SCOPED** | [`WEBSITE`](website/WEBSITE_ROADMAP.md) `IX.2` |

> **Part IX was measured against the live site on 08-16 and three of its five
> rows were wrong** — all in the optimistic-to-pessimistic direction, which is
> the rarer and less dangerous way to be wrong, but wrong. The download page and
> both legal pages existed; this map had guessed their addresses and recorded the
> guesses as 404s. **What it missed instead was worse than what it invented: a
> live Download button resolving to `.invalid`, and four false capability claims
> on the homepage.**
>
> The lesson is the one this repo keeps relearning at this exact seam: **the site
> is a fifth front-door surface, in another repository, that no test here
> renders.** It cost two weeks of contradictory licence terms in August. Checking
> it took ninety seconds of `curl`.

**It sits on two critical paths, not one.** `/privacy` at a matching domain is a
hard prerequisite for Google OAuth brand verification, so the website gates
[Google Workspace](#part-vi--integrations) as well as the public download.

**All of it is R2.** Release 1 hands a DMG to people we can email; none of this
is needed for that. It becomes mandatory the moment a stranger can arrive — which
is the definition of Release 2.

---

## Rules for this file

1. **Every surface and integration appears exactly once.** Two homes, one row.
2. **Only live maps are linked.** When a map is archived its links come out and
   the row goes to `—`; the row itself stays. An empty Map column is the correct
   answer for much of the app.
3. **A row is deleted only when the feature is.**
4. **State claims are checkable** — either a live map's own header, or a module
   that exists.
5. **Don't restate a map here.** Rows are one line. The reasoning lives in the
   roadmap and stays there.
6. **A gate number (`G-n`) is cited, never redefined.** Its definition lives in
   exactly one map; this page only points at it.
