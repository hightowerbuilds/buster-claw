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
2. **Each number lives in exactly one map.** `G-1`–`G-20` in Apple, `G-21`–`G-24`
   in Website, `G-25`–`G-35` in Trust and Support, `G-36`–`G-41` in Release Gate.
   A number in two places is precisely the old failure mode — check before adding
   one.
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
├── shell/ ·················· Part I    TERMINAL_THEME · TERMINAL_PAINT
├── surfaces/ ··············· Parts II–III  STUDIO · IMAGE_SHADER · LEFTOVERS_SURFACES
├── agent-core/ ············· Part V    LEFTOVERS_AGENT_CORE
├── integrations/ ··········· Part VI   CLINCH · BUSTERPHONE (+NUMBER_VENDING) · GOOGLE_VERIFICATION
├── platform/ ··············· Part VII  APPLE · RELEASE_GATE · TRUST_AND_SUPPORT · QA_BACKLOG · LEFTOVERS_PLATFORM
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

1. **[The Clinch](#part-vi--integrations)** — Phase 3 next; it unblocks BusterPhone.
2. **[BusterPhone](#part-vi--integrations)** — the only paid thing.
3. **[Apple](#part-vii--platform--release)** — **a signed DMG exists 08-10** and is with the notary. What is next is not code: **an Apple Silicon Mac.**
4. **[Studio → Voice](#part-ii--home)** — needs a person at a microphone.
5. **[The Dialyzer gate](#part-vii--platform--release)** — red on `main`, blocking nothing.

Two of those wait on the operator rather than an agent: the `getUserMedia` spike
needs a permission dialog clicked at a packaged build, and **`G-4` needs an Apple
Silicon Mac** — a dependency this repo had recorded backwards until 08-10.

**First movement on the release path since 08-01.** `G-2` and `G-2b` both landed
08-10: a Developer ID certificate (team `KD977J8NF6`, valid to 2031) and App Store
Connect notary credentials (key `SAKNAF6YLA`). **All five release secrets are set**,
`HAVE_APPLE_CERT` is `true`, and CI produces signed builds with no workflow edit.

**Then the pipeline itself ran, and passed on the first attempt.** A signed `.app`
and a signed **27 MB x86_64 DMG** were built from current `main`, and six of the
eight machine-checkable III.J assertions are green: valid signature, hardened
runtime, full chain to Apple Root CA, `allow-jit` on `beam.smp` itself, native
single-arch, and **24 of 24 Mach-O objects signed** — a count the map had predicted
exactly. The DMG is with the notary awaiting a verdict.

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

---

## Part I — The shell

| Section | Where | State | Map |
|---|---|---|---|
| Dock navigation | `DockNavLive` | SHIPPED | — |
| Dock strip (chips, sticky player) | `DockLive`, `MusicPlayerLive` | SHIPPED | — |
| First-run onboarding | `SetupLive` `/setup` | SHIPPED | [`FRONT_DOOR`](distribution/FRONT_DOOR_ROADMAP.md) — the wizard is one of four surfaces that must agree |
| Appearance — skins, text size, backgrounds | `AppearanceLive` `/appearance` | SHIPPED | — |
| Terminal themes | `TerminalTheme` | SHIPPED · operator walk open | [`TERMINAL_THEME`](shell/TERMINAL_THEME_ROADMAP.md), gate `G-40` |
| Terminal paint — the agent recolours itself | — | **SCOPED** | [`TERMINAL_PAINT`](shell/TERMINAL_PAINT_ROADMAP.md) |

---

## Part II — Home

`StatusLive` at `/`. Eight sub-tabs plus a corner widget with three of its own.

| Section | Where | State | Map |
|---|---|---|---|
| Chat | `ChatPanel`, `status/chat.ex` | SHIPPED | [`LEFTOVERS_SURFACES`](surfaces/LEFTOVERS_SURFACES.md) — the live-CLI attachment walk |
| Notes | `NotesComponent` | SHIPPED | [`LEFTOVERS_SURFACES`](surfaces/LEFTOVERS_SURFACES.md) — renaming orphans `[[wiki links]]` |
| Pockets | `PocketsPanel` | SHIPPED | — |
| Calendar | `CalendarComponent` | SHIPPED | — |
| Phone | `PhoneComponent` | surface SHIPPED, leg **ACTIVE** | [`BUSTERPHONE`](integrations/BUSTERPHONE_ROADMAP.md) |
| **Studio → Mix** | `SoundStudioComponent` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](agent-core/LEFTOVERS_AGENT_CORE.md) — no `sound_*` CLI verbs |
| **Studio → Voice** | `Studio.Registry` | **PLACEHOLDER** | [`STUDIO`](surfaces/STUDIO_ROADMAP.md) Parts V–VI |
| Explained | `ExplainedPanel` | SHIPPED | [`LEFTOVERS_SURFACES`](surfaces/LEFTOVERS_SURFACES.md) — two errands, five tiles |
| Activity | `ActivityComponent` | SHIPPED | — |
| Widget → Time & Place | `status/weather.ex` | SHIPPED | — |
| Widget → Contacts | `BusterClaw.Contacts` | SHIPPED | — |
| Widget → Notify | `NotifyLive` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](agent-core/LEFTOVERS_AGENT_CORE.md) — the chime designer |
| Background shader | `Shaders` | SHIPPED | — |
| Image-reactive shaders | — | **SCOPED** | [`IMAGE_SHADER`](surfaces/IMAGE_SHADER_ROADMAP.md) |
| The home screen's primary action | `StatusLive` | SHIPPED, **says the wrong thing** | [`FRONT_DOOR`](distribution/FRONT_DOOR_ROADMAP.md) `VI-a` |

**Studio → Voice is the only unbuilt surface in Home.** The binding constraint is
measured: **144 of 237 words are single-take**, none ever hand-corrected. Both
halves — recording and the dictionary to browse and correct — share one tab
because neither is built; splitting them later is one edit in `Studio.Registry`.

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
| Scene3D | `Scene3D` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](agent-core/LEFTOVERS_AGENT_CORE.md) — polish, waiting on evidence |
| Shaders — the authoring machinery | `Shaders` | SHIPPED | — |
| Library, analyzer, ingest, journal | `Library`, `Analyzer`, `ingest/` | SHIPPED | — |

---

## Part VI — Integrations

| Section | Where | State | Map |
|---|---|---|---|
| **The Clinch — credentials** | `Clinch`, `ClinchPanels`, Tauri `clinch_*` | **ACTIVE — Phase 3 next** | [`CLINCH`](integrations/CLINCH_ROADMAP.md) |
| **Twilio / BusterPhone** | `Telephony` | **ACTIVE — the money leg** | [`BUSTERPHONE`](integrations/BUSTERPHONE_ROADMAP.md) |
| The relay (Supabase) | `telephony/relay.ex` | SHIPPED | [`LEFTOVERS_PLATFORM`](platform/LEFTOVERS_PLATFORM.md) — confirm the rotated DB password landed |
| Google Workspace | `Google` (16 modules) | SHIPPED | [`GOOGLE_VERIFICATION`](integrations/GOOGLE_VERIFICATION_ROADMAP.md) — restricted scopes, CASA |
| Operational — GitHub, Sentry, Umami | `Integrations` | SHIPPED | — |
| Web search & data sources | `catalog/web.ex`, `Search` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](agent-core/LEFTOVERS_AGENT_CORE.md) — persisting macro series |
| Weather | `Weather` | SHIPPED | — |
| Notes That Float / Shadiox | outside this repo | **SCOPED** | — |

**The Clinch's Phase 3 unblocks BusterPhone, which is the entire paywall.** That
is the one dependency chain on this page; everything else is parallel to it.
BusterPhone's next actions are the operator's, in order: upgrade Twilio → wire
the Voice webhook → set `SUPABASE_URL` / `SERVICE_ROLE_KEY` → call it.

---

## Part VII — Platform & release

| Section | Where | State | Map |
|---|---|---|---|
| Tauri desktop shell | `desktop/tauri/` | SHIPPED | — |
| **Apple — sign, notarize, staple** | CI, `scripts/codesign_release.sh` | **ACTIVE — signed DMG built 08-10, at the notary; needs an arm64 Mac** | [`APPLE`](platform/APPLE_ROADMAP.md) |
| **The release gate** | — | **ACTIVE** | [`RELEASE_GATE`](platform/RELEASE_GATE_ROADMAP.md) |
| **Trust claims & support** | `Sentinel`, — | **ACTIVE** | [`TRUST_AND_SUPPORT`](platform/TRUST_AND_SUPPORT_ROADMAP.md) |
| CI gates | `scripts/check_*.sh` | SHIPPED, **one red** | — |
| Code health | — | SHIPPED | [`LEFTOVERS_PLATFORM`](platform/LEFTOVERS_PLATFORM.md) — hotspots, guards, no DOM harness |
| QA debt (blocks nothing) | — | OPEN | [`QA_BACKLOG`](platform/QA_BACKLOG.md) |

**🔴 The Dialyzer gate is red on `main`** — exits 2 with 56 findings; 44 are
accepted-class noise, **12 can be real defects**. There are no PRs here, so it
blocks nothing: a gate everyone believes is running, isn't. **It has no map and
should get one.**

---

## Part VIII — Distribution

Who gets it, what they pay, and how we find out whether anyone wants it.

| Section | Where | State | Map |
|---|---|---|---|
| **Tiers, margin, the paid pitch** | — | **ACTIVE** | [`DISTRIBUTION`](distribution/DISTRIBUTION_ROADMAP.md) |
| **Concept testing** — five falsifiable claims | — | **ACTIVE, can start today** | [`DISTRIBUTION`](distribution/DISTRIBUTION_ROADMAP.md) `IX.1`–`IX.5` |
| The front door — one sentence, four surfaces | README, site, `SetupLive`, `StatusLive` | **ACTIVE, nothing done** | [`FRONT_DOOR`](distribution/FRONT_DOOR_ROADMAP.md) |
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
| `/` homepage | separate repo (Vercel) | 200, **wrong headline** | [`WEBSITE`](website/WEBSITE_ROADMAP.md) `G-23` · [`FRONT_DOOR`](distribution/FRONT_DOOR_ROADMAP.md) |
| `/download` | — | **404** | [`WEBSITE`](website/WEBSITE_ROADMAP.md) `G-21` |
| `/privacy` | — | **404** | [`WEBSITE`](website/WEBSITE_ROADMAP.md) `G-22` |
| `/terms` | — | **404** | [`WEBSITE`](website/WEBSITE_ROADMAP.md) `G-22` |
| Stated floor + Claude requirement | — | not stated | [`WEBSITE`](website/WEBSITE_ROADMAP.md) `G-24` |
| The landing-page test | — | **SCOPED** | [`WEBSITE`](website/WEBSITE_ROADMAP.md) `IX.2` |

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
