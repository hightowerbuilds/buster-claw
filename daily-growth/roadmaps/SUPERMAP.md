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

### The live maps

`CLINCH_ROADMAP` · `LAUNCH_ROADMAP` · `STUDIO_ROADMAP` · `TERMINAL_THEME_ROADMAP`
· `TERMINAL_PAINT_ROADMAP` · `IMAGE_SHADER_ROADMAP` ·
`phone-maps/BUSTERPHONE_ROADMAP` · `LEFTOVERS`

Eight documents. Everything else on this page is done.

---

## Where the build is

1. **[The Clinch](#part-vi--integrations)** — Phase 3 next; it unblocks BusterPhone.
2. **[BusterPhone](#part-vi--integrations)** — the only paid thing.
3. **[Launch](#part-vii--platform--release)** — G-2, the Developer ID cert.
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
| First-run onboarding | `SetupLive` `/setup` | SHIPPED | — |
| Appearance — skins, text size, backgrounds | `AppearanceLive` `/appearance` | SHIPPED | — |
| Terminal themes | `TerminalTheme` | SHIPPED · operator walk open | [`TERMINAL_THEME_ROADMAP`](TERMINAL_THEME_ROADMAP.md), LAUNCH G-40 |
| Terminal paint — the agent recolours itself | — | **SCOPED** | [`TERMINAL_PAINT_ROADMAP`](TERMINAL_PAINT_ROADMAP.md) |

---

## Part II — Home

`StatusLive` at `/`. Eight sub-tabs plus a corner widget with three of its own.

| Section | Where | State | Map |
|---|---|---|---|
| Chat | `ChatPanel`, `status/chat.ex` | SHIPPED | [`LEFTOVERS`](LEFTOVERS.md) — the live-CLI attachment walk |
| Notes | `NotesComponent` | SHIPPED | [`LEFTOVERS`](LEFTOVERS.md) — renaming orphans `[[wiki links]]` |
| Pockets | `PocketsPanel` | SHIPPED | — |
| Calendar | `CalendarComponent` | SHIPPED | — |
| Phone | `PhoneComponent` | surface SHIPPED, leg **ACTIVE** | [`BUSTERPHONE_ROADMAP`](phone-maps/BUSTERPHONE_ROADMAP.md) |
| **Studio → Mix** | `SoundStudioComponent` | SHIPPED | — |
| **Studio → Voice** | `Studio.Registry` | **PLACEHOLDER** | [`STUDIO_ROADMAP`](STUDIO_ROADMAP.md) Parts V–VI |
| Explained | `ExplainedPanel` | SHIPPED | [`LEFTOVERS`](LEFTOVERS.md) — two errands, five tiles |
| Activity | `ActivityComponent` | SHIPPED | — |
| Widget → Time & Place | `status/weather.ex` | SHIPPED | — |
| Widget → Contacts | `BusterClaw.Contacts` | SHIPPED | — |
| Widget → Notify | `NotifyLive` | SHIPPED | — |
| Background shader | `Shaders` | SHIPPED | — |

**Studio → Voice is the whole of Part II's open work.** The binding constraint is
measured: **144 of 237 words are single-take**, none ever hand-corrected. Both
halves — recording (V.6–V.8) and the dictionary to browse and correct (VI.1–VI.3)
— share one tab because neither is built; splitting them later is one edit in
`Studio.Registry`.

---

## Part III — Full-screen surfaces

| Section | Where | State | Map |
|---|---|---|---|
| Workspace | `WorkspaceLive` `/workspace` | SHIPPED | — |
| Browser | `BrowseLive` `/browse`, `BrowserControl` | SHIPPED | [`LEFTOVERS`](LEFTOVERS.md) · LAUNCH **G-34** (the payment gate is unwalked) |
| Split view | `SplitLive` `/split` | SHIPPED | — |
| Terminal | `TerminalLive` `/terminal` | SHIPPED | — |
| The Manual | `UserGuideLive` `/manual` | SHIPPED | [`LEFTOVERS`](LEFTOVERS.md) — no test, worst drift of any surface |
| Music library | `MusicComponent` (inside Studio → Mix) | SHIPPED | [`LEFTOVERS`](LEFTOVERS.md) — `nosniff` on four media routes, **HIGH** |

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
| Security | `SecurityLive` | SHIPPED | — |

---

## Part V — The agent core

Not surfaces. The machinery every surface sits on.

| Section | Where | State | Map |
|---|---|---|---|
| Command surface & catalog | `Commands`, `commands/catalog/` | SHIPPED | — |
| Agent runner & backends | `AgentRunner`, `AgentBackend` | SHIPPED | [`LEFTOVERS`](LEFTOVERS.md) — `agent/chat.ex` owed a cut |
| Model policy | `ModelPolicy` | SHIPPED | — |
| Policy engine & trust tiers | `PolicyEngine`, `AgentToolPolicy` | SHIPPED | — |
| Sentinel — audit & notify | `Sentinel` | SHIPPED | — |
| Dispatch, orchestration, swarm | `Dispatch`, `Orchestrator`, `swarm/` | SHIPPED | — |
| Skills | `Skills` | SHIPPED | [`LEFTOVERS`](LEFTOVERS.md) — two seeds uncombed |
| Memory | `Memory` | SHIPPED | — |
| Scene3D | `Scene3D` | SHIPPED | [`LEFTOVERS`](LEFTOVERS.md) — polish, waiting on evidence |
| Shaders | `Shaders` | SHIPPED | — |
| Image-reactive shaders | — | **SCOPED** | [`IMAGE_SHADER_ROADMAP`](IMAGE_SHADER_ROADMAP.md) |
| Library, analyzer, ingest, journal | `Library`, `Analyzer`, `ingest/` | SHIPPED | — |

---

## Part VI — Integrations

| Section | Where | State | Map |
|---|---|---|---|
| **The Clinch — credentials** | `Clinch`, `ClinchPanels`, Tauri `clinch_*` | **ACTIVE — Phase 3 next** | [`CLINCH_ROADMAP`](CLINCH_ROADMAP.md) |
| **Twilio / BusterPhone** | `Telephony` | **ACTIVE — the money leg** | [`BUSTERPHONE_ROADMAP`](phone-maps/BUSTERPHONE_ROADMAP.md) |
| The relay (Supabase) | `telephony/relay.ex` | SHIPPED | [`LEFTOVERS`](LEFTOVERS.md) — confirm the rotated DB password landed |
| Google Workspace | `Google` (16 modules) | SHIPPED | — |
| Operational — GitHub, Sentry, Umami | `Integrations` | SHIPPED | — |
| Web search & data sources | `catalog/web.ex`, `Search` | SHIPPED | — |
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
| **Apple signing & notarization** | — | **ACTIVE — G-2 is next** | [`LAUNCH_ROADMAP`](LAUNCH_ROADMAP.md) |
| Distribution & go-to-market | — | **ACTIVE** | [`LAUNCH_ROADMAP`](LAUNCH_ROADMAP.md) |
| CI gates | `scripts/check_*.sh` | SHIPPED, **one red** | — |
| Code health | — | SHIPPED | [`LEFTOVERS`](LEFTOVERS.md) — decompose the hotspots |

**🔴 The Dialyzer gate is red on `main`** — exits 2 with 56 findings; 44 are
accepted-class noise, **12 can be real defects**. There are no PRs here, so it
blocks nothing: a gate everyone believes is running, isn't. **It has no map and
should get one.**

---

## Rules for this file

1. **Every surface and integration appears exactly once.** Two homes, one row.
2. **Only live maps are linked.** When a map is archived its links come out and
   the row goes to `—`; the row itself stays. An empty Map column is the correct
   answer for most of the app.
3. **A row is deleted only when the feature is.**
4. **State claims are checkable** — either a live map's own header, or a module
   that exists.
5. **Don't restate a map here.** Rows are one line. The reasoning lives in the
   roadmap and stays there.
