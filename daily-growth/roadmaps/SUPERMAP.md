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

## The spine

**[`LAUNCH_ROADMAP`](LAUNCH_ROADMAP.md) is the release spine** — what the release
is, what is verified true at HEAD, the order to do it in, and the bill. It holds
*status*, and delegates every area to the map that owns it.

It was one 1,671-line file until 08-09. The split was made so each area could be
read from the section below that owns it, and it carries a warning worth
repeating: **this document was four files once before, and they disagreed with
each other and with the code.** Three things keep that from recurring —

1. **No identifier changed.** Every `G-n` and `III.x` kept its number. Scripts
   and CI cite `III.E/F/G/J` by name; commits cite `G-n`.
2. **Each number lives in exactly one map.** A number in two places is the old
   failure mode.
3. **Status stays in the spine.** What disagreed last time was *what state we are
   in*; that answer has one home.

### The eighteen live maps

| Spine | Release | Feature | Tail |
|---|---|---|---|
| [`LAUNCH_ROADMAP`](LAUNCH_ROADMAP.md) | [`APPLE`](APPLE_ROADMAP.md) · [`RELEASE_GATE`](RELEASE_GATE_ROADMAP.md) · [`TRUST_AND_SUPPORT`](TRUST_AND_SUPPORT_ROADMAP.md) · [`WEBSITE`](WEBSITE_ROADMAP.md) · [`DISTRIBUTION`](DISTRIBUTION_ROADMAP.md) · [`GOOGLE_VERIFICATION`](GOOGLE_VERIFICATION_ROADMAP.md) · [`FRONT_DOOR`](FRONT_DOOR_ROADMAP.md) | [`CLINCH`](CLINCH_ROADMAP.md) · [`STUDIO`](STUDIO_ROADMAP.md) · [`BUSTERPHONE`](BUSTERPHONE_ROADMAP.md) · [`TERMINAL_THEME`](TERMINAL_THEME_ROADMAP.md) · [`TERMINAL_PAINT`](TERMINAL_PAINT_ROADMAP.md) · [`IMAGE_SHADER`](IMAGE_SHADER_ROADMAP.md) | [`QA_BACKLOG`](QA_BACKLOG.md) · [`LEFTOVERS`](LEFTOVERS.md) → [surfaces](LEFTOVERS_SURFACES.md) · [agent core](LEFTOVERS_AGENT_CORE.md) · [platform](LEFTOVERS_PLATFORM.md) |

---

## Where the build is

1. **[The Clinch](#part-vi--integrations)** — Phase 3 next; it unblocks BusterPhone.
2. **[BusterPhone](#part-vi--integrations)** — the only paid thing.
3. **[Apple](#part-vii--platform--release)** — G-2, the Developer ID cert. Minutes of work, blocks everything.
4. **[Studio → Voice](#part-ii--home)** — needs a person at a microphone.
5. **[The Dialyzer gate](#part-vii--platform--release)** — red on `main`, blocking nothing.

Two of those wait on the operator rather than an agent: the `getUserMedia` spike
needs a permission dialog clicked at a packaged build, and G-2 needs a
certificate requested.

---

## Part I — The shell

| Section | Where | State | Map |
|---|---|---|---|
| Dock navigation | `DockNavLive` | SHIPPED | — |
| Dock strip (chips, sticky player) | `DockLive`, `MusicPlayerLive` | SHIPPED | — |
| First-run onboarding | `SetupLive` `/setup` | SHIPPED | [`FRONT_DOOR`](FRONT_DOOR_ROADMAP.md) — the wizard is one of four surfaces that must agree |
| Appearance — skins, text size, backgrounds | `AppearanceLive` `/appearance` | SHIPPED | — |
| Terminal themes | `TerminalTheme` | SHIPPED · operator walk open | [`TERMINAL_THEME`](TERMINAL_THEME_ROADMAP.md), gate `G-40` |
| Terminal paint — the agent recolours itself | — | **SCOPED** | [`TERMINAL_PAINT`](TERMINAL_PAINT_ROADMAP.md) |

---

## Part II — Home

`StatusLive` at `/`. Eight sub-tabs plus a corner widget with three of its own.

| Section | Where | State | Map |
|---|---|---|---|
| Chat | `ChatPanel`, `status/chat.ex` | SHIPPED | [`LEFTOVERS_SURFACES`](LEFTOVERS_SURFACES.md) — the live-CLI attachment walk |
| Notes | `NotesComponent` | SHIPPED | [`LEFTOVERS_SURFACES`](LEFTOVERS_SURFACES.md) — renaming orphans `[[wiki links]]` |
| Pockets | `PocketsPanel` | SHIPPED | — |
| Calendar | `CalendarComponent` | SHIPPED | — |
| Phone | `PhoneComponent` | surface SHIPPED, leg **ACTIVE** | [`BUSTERPHONE`](BUSTERPHONE_ROADMAP.md) |
| **Studio → Mix** | `SoundStudioComponent` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](LEFTOVERS_AGENT_CORE.md) — no `sound_*` CLI verbs |
| **Studio → Voice** | `Studio.Registry` | **PLACEHOLDER** | [`STUDIO`](STUDIO_ROADMAP.md) Parts V–VI |
| Explained | `ExplainedPanel` | SHIPPED | [`LEFTOVERS_SURFACES`](LEFTOVERS_SURFACES.md) — two errands, five tiles |
| Activity | `ActivityComponent` | SHIPPED | — |
| Widget → Time & Place | `status/weather.ex` | SHIPPED | — |
| Widget → Contacts | `BusterClaw.Contacts` | SHIPPED | — |
| Widget → Notify | `NotifyLive` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](LEFTOVERS_AGENT_CORE.md) — the chime designer |
| Background shader | `Shaders` | SHIPPED | — |
| The home screen's primary action | `StatusLive` | SHIPPED, **says the wrong thing** | [`FRONT_DOOR`](FRONT_DOOR_ROADMAP.md) `VI-a` |

**Studio → Voice is the only unbuilt surface in Home.** The binding constraint is
measured: **144 of 237 words are single-take**, none ever hand-corrected. Both
halves — recording and the dictionary to browse and correct — share one tab
because neither is built; splitting them later is one edit in `Studio.Registry`.

---

## Part III — Full-screen surfaces

| Section | Where | State | Map |
|---|---|---|---|
| Workspace | `WorkspaceLive` `/workspace` | SHIPPED | — |
| Browser | `BrowseLive` `/browse`, `BrowserControl` | SHIPPED | [`LEFTOVERS_SURFACES`](LEFTOVERS_SURFACES.md) · gate `G-34` — the payment gate is unwalked |
| Split view | `SplitLive` `/split` | SHIPPED | — |
| Terminal | `TerminalLive` `/terminal` | SHIPPED | — |
| The Manual | `UserGuideLive` `/manual` | SHIPPED | [`LEFTOVERS_SURFACES`](LEFTOVERS_SURFACES.md) — no test, worst drift of any surface |
| Music library | `MusicComponent` (inside Studio → Mix) | SHIPPED | [`LEFTOVERS_SURFACES`](LEFTOVERS_SURFACES.md) · gate `G-35` — `nosniff`, **HIGH** |

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
| Security | `SecurityLive` | SHIPPED, **buried** | [`TRUST_AND_SUPPORT`](TRUST_AND_SUPPORT_ROADMAP.md) `G-32` |

---

## Part V — The agent core

Not surfaces. The machinery every surface sits on.

| Section | Where | State | Map |
|---|---|---|---|
| Command surface & catalog | `Commands`, `commands/catalog/` | SHIPPED | — |
| Agent runner & backends | `AgentRunner`, `AgentBackend` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](LEFTOVERS_AGENT_CORE.md) — `agent/chat.ex` owed a cut |
| Model policy | `ModelPolicy` | SHIPPED | — |
| Policy engine & trust tiers | `PolicyEngine`, `AgentToolPolicy` | SHIPPED | — |
| Sentinel — audit & notify | `Sentinel` | SHIPPED, **claims outrun it** | [`TRUST_AND_SUPPORT`](TRUST_AND_SUPPORT_ROADMAP.md) `G-29`–`G-31` |
| Dispatch, orchestration, swarm | `Dispatch`, `Orchestrator`, `swarm/` | SHIPPED | — |
| Skills | `Skills` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](LEFTOVERS_AGENT_CORE.md) — two seeds uncombed |
| Memory | `Memory` | SHIPPED | — |
| Scene3D | `Scene3D` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](LEFTOVERS_AGENT_CORE.md) — polish, waiting on evidence |
| Shaders | `Shaders` | SHIPPED | — |
| Image-reactive shaders | — | **SCOPED** | [`IMAGE_SHADER`](IMAGE_SHADER_ROADMAP.md) |
| Library, analyzer, ingest, journal | `Library`, `Analyzer`, `ingest/` | SHIPPED | — |

---

## Part VI — Integrations

| Section | Where | State | Map |
|---|---|---|---|
| **The Clinch — credentials** | `Clinch`, `ClinchPanels`, Tauri `clinch_*` | **ACTIVE — Phase 3 next** | [`CLINCH`](CLINCH_ROADMAP.md) |
| **Twilio / BusterPhone** | `Telephony` | **ACTIVE — the money leg** | [`BUSTERPHONE`](BUSTERPHONE_ROADMAP.md) |
| The relay (Supabase) | `telephony/relay.ex` | SHIPPED | [`LEFTOVERS_PLATFORM`](LEFTOVERS_PLATFORM.md) — confirm the rotated DB password landed |
| Google Workspace | `Google` (16 modules) | SHIPPED | [`GOOGLE_VERIFICATION`](GOOGLE_VERIFICATION_ROADMAP.md) — restricted scopes, CASA |
| Operational — GitHub, Sentry, Umami | `Integrations` | SHIPPED | — |
| Web search & data sources | `catalog/web.ex`, `Search` | SHIPPED | [`LEFTOVERS_AGENT_CORE`](LEFTOVERS_AGENT_CORE.md) — persisting macro series |
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
| **Apple — sign, notarize, staple** | CI, `scripts/codesign_release.sh` | **ACTIVE — `G-2` is next** | [`APPLE`](APPLE_ROADMAP.md) |
| **The release gate** | — | **ACTIVE** | [`RELEASE_GATE`](RELEASE_GATE_ROADMAP.md) |
| **Trust claims & support** | `Sentinel`, — | **ACTIVE** | [`TRUST_AND_SUPPORT`](TRUST_AND_SUPPORT_ROADMAP.md) |
| CI gates | `scripts/check_*.sh` | SHIPPED, **one red** | — |
| Code health | — | SHIPPED | [`LEFTOVERS_PLATFORM`](LEFTOVERS_PLATFORM.md) — hotspots, guards, no DOM harness |
| QA debt (blocks nothing) | — | OPEN | [`QA_BACKLOG`](QA_BACKLOG.md) |

**🔴 The Dialyzer gate is red on `main`** — exits 2 with 56 findings; 44 are
accepted-class noise, **12 can be real defects**. There are no PRs here, so it
blocks nothing: a gate everyone believes is running, isn't. **It has no map and
should get one.**

---

## Part VIII — Distribution

Who gets it, what they pay, and how we find out whether anyone wants it.

| Section | Where | State | Map |
|---|---|---|---|
| **Tiers, margin, the paid pitch** | — | **ACTIVE** | [`DISTRIBUTION`](DISTRIBUTION_ROADMAP.md) |
| **Concept testing** — five falsifiable claims | — | **ACTIVE, can start today** | [`DISTRIBUTION`](DISTRIBUTION_ROADMAP.md) `IX.1`–`IX.5` |
| The front door — one sentence, four surfaces | README, site, `SetupLive`, `StatusLive` | **ACTIVE, nothing done** | [`FRONT_DOOR`](FRONT_DOOR_ROADMAP.md) |
| The bill | — | measured | [`DISTRIBUTION`](DISTRIBUTION_ROADMAP.md) |
| Anything paid | — | **not started, on purpose** | [`DISTRIBUTION`](DISTRIBUTION_ROADMAP.md) |

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

---

## Part IX — busterclaw.lol

The website, where the public finds the app. **A separate repo** — which is why
it kept getting deferred inside a roadmap about signing binaries.

| Section | Where | State | Map |
|---|---|---|---|
| `/` homepage | separate repo (Vercel) | 200, **wrong headline** | [`WEBSITE`](WEBSITE_ROADMAP.md) `G-23` · [`FRONT_DOOR`](FRONT_DOOR_ROADMAP.md) |
| `/download` | — | **404** | [`WEBSITE`](WEBSITE_ROADMAP.md) `G-21` |
| `/privacy` | — | **404** | [`WEBSITE`](WEBSITE_ROADMAP.md) `G-22` |
| `/terms` | — | **404** | [`WEBSITE`](WEBSITE_ROADMAP.md) `G-22` |
| Stated floor + Claude requirement | — | not stated | [`WEBSITE`](WEBSITE_ROADMAP.md) `G-24` |
| The landing-page test | — | **SCOPED** | [`WEBSITE`](WEBSITE_ROADMAP.md) `IX.2` |

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
