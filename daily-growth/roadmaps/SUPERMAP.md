# The Supermap

**Every part of Buster Claw, once, with the roadmap that governs it.**

Scoped 2026-08-09. This is the index we read *first* from here on, to answer one
question: **where is the build?**

---

## Why this file exists

As of 08-09 there are 8 live roadmaps beside this one and 102 archived documents.
Between them they describe the app accurately — but only in pieces, and only to
someone who already knows which piece to open. A surface that never got a roadmap is invisible in that pile, and
a surface whose roadmap was archived looks finished whether or not it is.

So this file inverts the index. **It is organised by the app, not by the
documents.** Every surface and every integration gets a section whether or not
anything was ever written about it, which means the empty cells are the point:
they are the parts of the product nobody has planned, stated as a fact rather
than discovered later.

### How to read a section

Each one carries four things, and nothing else:

| Field | Meaning |
|---|---|
| **What** | one line, in product terms |
| **Where** | the module or route that *is* it — so the map can be checked against code |
| **State** | see vocabulary below |
| **Map** | the roadmap that governs it, or `— none —` |

### State vocabulary

- **SHIPPED** — built, in the app, and its roadmap is closed.
- **ACTIVE** — a live roadmap with unfinished phases.
- **SCOPED** — a roadmap exists; no code.
- **PLACEHOLDER** — the surface exists and honestly says it is empty.
- **UNMAPPED** — built and in use, governed by no document. Not a defect; a
  fact worth being able to see.
- **DELETED** — removed on purpose. Listed so nobody rebuilds it.

Live roadmaps are in `daily-growth/roadmaps/`; closed ones in
`daily-growth/archive/`. A link into `archive/` means *the thinking is settled* —
read it before changing that area, don't reopen it.

---

## At a glance

Names, not counts — a tally goes stale the moment a section is added, and does it
silently.

| Area | Everything not SHIPPED |
|---|---|
| [I — The shell](#part-i--the-shell) | Terminal themes (walk only) · Terminal paint (SCOPED) |
| [II — Home](#part-ii--home-the-primary-surface) | Studio → Voice (PLACEHOLDER) · Phone (blocked, see VI.3) |
| [III — Full-screen surfaces](#part-iii--full-screen-surfaces) | — all shipped — |
| [IV — Settings](#part-iv--settings) | — all shipped — |
| [V — The agent core](#part-v--the-agent-core) | Image-reactive shaders (SCOPED) |
| [VI — Integrations](#part-vi--integrations) | **The Clinch (Phase 3)** · **BusterPhone** · Shadiox (SCOPED) |
| [VII — Platform & release](#part-vii--platform--release) | **Apple / launch** · 🔴 the Dialyzer gate |

**The live fronts, in the order they matter:**

1. **[BusterPhone](#vi3--twilio--busterphone)** — the only paid thing. Blocked on Clinch Phase 3.
2. **[The Clinch](#vi1--the-clinch-credentials)** — Phase 3 next; it unblocks the above.
3. **[Launch](#vii2--apple-signing--notarization)** — G-2, the Developer ID cert, is the gate everything else waits behind.
4. **[The Studio's Voice tab](#ii6--studio)** — needs a person at a microphone, not an agent.
5. **[The Dialyzer gate](#vii4--ci-gates)** — red on `main`, and nothing is failing because of it.

---

# Part I — The shell

The chrome that is present on every route.

## I.1 — Dock navigation

- **What** — the five top-level destinations: Home, Workspace, Browser, Terminal, Settings.
- **Where** — `BusterClawWeb.DockNavLive`, `Layouts.dock_nav`
- **State** — SHIPPED
- **Map** — `— none —` (UNMAPPED). The nav has never had its own document; it
  changed as a side effect of whichever roadmap added a destination. Its one
  hard-won rule is recorded in the module: **a layout renders once at mount and
  is never in a later diff**, which is why this is a LiveView and not markup.

## I.2 — The dock strip (timers, notifications, player)

- **What** — the persistent bottom strip: notification chips, and the sticky music player.
- **Where** — `DockLive`, `MusicPlayerLive` (`sticky: true` in `Layouts.app`)
- **State** — SHIPPED
- **Map** — [`archive/07-30-26-music-roadmap.md`](../archive/07-30-26-music-roadmap.md) for the player.
  The strip itself is UNMAPPED.
- **Note** — the player is sticky in the dock *specifically* so audio survives
  navigation; that is a constraint, not a layout choice.

## I.3 — First-run onboarding

- **What** — four dotted steps from launch to doing agentic work through email.
- **Where** — `SetupLive` (`/setup`), `RequireOnboarding`
- **State** — SHIPPED
- **Map** — [`archive/06-13-26-first-run-onboarding-roadmap.md`](../archive/06-13-26-first-run-onboarding-roadmap.md)

## I.4 — Appearance: skins, text size, backgrounds

- **What** — three chat looks, a four-step text size, and the background catalog.
- **Where** — `AppearanceLive` (`/appearance`), `ChatSkin`, `ChatTextSize`, `Shaders`
- **State** — SHIPPED
- **Map** — [`archive/08-09-26-chat-skins.md`](../archive/08-09-26-chat-skins.md)
- **The contract, because it is easy to break** — the DOM is *identical* across
  every skin and every size. Appearance is CSS-only, because a LiveView stream
  never re-renders messages already on screen. **No skin may override panel
  translucency.**

## I.5 — Terminal themes

- **What** — three presets plus a hue-slider custom palette for the terminal.
- **Where** — `TerminalTheme`
- **State** — SHIPPED (Phases 0–2); **the operator walk is the only thing left**, tracked as LAUNCH G-40.
- **Map** — [`TERMINAL_THEME_ROADMAP.md`](TERMINAL_THEME_ROADMAP.md)

## I.6 — Terminal paint (the agent recolours itself)

- **What** — four commands letting the model recolour the terminal it is running
  in, live, into its own slot — never the operator's.
- **Where** — nothing yet
- **State** — SCOPED
- **Map** — [`TERMINAL_PAINT_ROADMAP.md`](TERMINAL_PAINT_ROADMAP.md)
- **Why it is sharper than it looks** — it is the first feature that lets the
  agent change **what the operator sees**. Appearance having no command surface
  is a decision, not a gap.

---

# Part II — Home, the primary surface

`StatusLive` at `/`. Eight sub-tabs plus a corner widget with three of its own.
The sub-tab list is **one literal** feeding both the rail and the click guard —
it was two lists until 08-08, which is how Phone shipped as a button the server
then refused.

## II.1 — Chat

- **What** — the main conversation with the agent.
- **Where** — `ChatPanel`, `status/chat.ex`, `status/chat_attachments.ex`
- **State** — SHIPPED
- **Map** — four closed roadmaps, each governing a different half:
  - [`archive/06-20-26-headless-claude-chat-roadmap.md`](../archive/06-20-26-headless-claude-chat-roadmap.md) — the harness
  - [`archive/08-06-26-chat-live-steering.md`](../archive/08-06-26-chat-live-steering.md) — steering mid-turn (DEV-ONLY flag; rollout is LAUNCH G-41)
  - [`archive/08-08-26-chat-attachments-roadmap.md`](../archive/08-08-26-chat-attachments-roadmap.md) — attachments
  - [`archive/07-18-26-home-chat-agent-selection-roadmap.md`](../archive/07-18-26-home-chat-agent-selection-roadmap.md) — picking the agent

## II.2 — Notes

- **What** — the operator's Markdown vault: live-preview editor, search, ⌘P switcher, `[[wiki links]]`, backlinks.
- **Where** — `NotesComponent`, `components/notes/`
- **State** — SHIPPED
- **Map** — [`archive/08-09-26-notes-editor.md`](../archive/08-09-26-notes-editor.md) ·
  [`archive/08-08-26-home-activity-notes.md`](../archive/08-08-26-home-activity-notes.md)
- **The rule that worked** — **the browser owns editing.** Typing writes nothing
  to the DOM tree. Two earlier designs shipped green and were unusable.
- **Open** — renaming a note orphans every `[[wiki link]]` pointing at it (`LEFTOVERS.md`).

## II.3 — Pockets

- **What** — the operator's own dock icons and homepage banner, swappable.
- **Where** — `PocketsPanel`, `BusterClaw.Pockets`
- **State** — SHIPPED
- **Map** — [`archive/08-09-26-pockets-roadmap.md`](../archive/08-09-26-pockets-roadmap.md)

## II.4 — Calendar

- **What** — the calendar, embedded here and standalone at `/calendar`.
- **Where** — `CalendarComponent` (shared by `StatusLive`, `CalendarLive`, `SplitLive`)
- **State** — SHIPPED
- **Map** — `— none —` (UNMAPPED as a surface). The *sync* behind it is mapped
  under [Google Workspace](#vi2--google-workspace).

## II.5 — Phone

- **What** — the Message Machine: greeting → beep → recorded message, plus SMS.
- **Where** — `PhoneComponent` (shared with `PhoneLive` at `/phone`)
- **State** — ACTIVE — see [VI.3](#vi3--twilio--busterphone). The surface exists; the money leg behind it does not close.
- **Map** — [`phone-maps/BUSTERPHONE_ROADMAP.md`](phone-maps/BUSTERPHONE_ROADMAP.md)

## II.6 — Studio

- **What** — the room the agent can enter. Two sub-tabs on a data-only registry.
- **Where** — `StudioPanel`, `Studio.Registry`
- **State** — **Mix: SHIPPED. Voice: PLACEHOLDER.**
- **Map** — [`STUDIO_ROADMAP.md`](STUDIO_ROADMAP.md) — Parts I–IV shipped 08-08; **Parts V and VI are live.**

| Sub-tab | State | What |
|---|---|---|
| **Mix** | SHIPPED | cutting and arranging — sources, trims, clips, saved mixes (`SoundStudioComponent`, FROZEN at its cap) |
| **Voice** | PLACEHOLDER | voice training and ramshackle audio: recording (V.6–V.8) and a dictionary to browse/audition/correct (VI.1–VI.3) |

- **The binding constraint is corpus size, and it is measured:** **144 of 237
  words are single-take, and 100% are `aligned`** — nothing was ever
  hand-corrected. Three independent lines (engineering, measurement, legal)
  converged on one action: **record the operator's own voice.**
- **This needs a person, not an agent.** The `getUserMedia` spike requires
  clicking a permission dialog at a packaged build.
- **Closed questions — do not reopen:** no YouTube scraping, no sub-word
  splicing, no Whisper, no 2D maps. Banks never merge. **AGC off**, or every
  splice seam jumps level.

## II.7 — Explained

- **What** — the in-app tutorials: what each part of the app is and how to drive it.
- **Where** — `ExplainedPanel`, `Explained.Registry`
- **State** — SHIPPED
- **Map** — [`archive/08-08-26-explore-tab.md`](../archive/08-08-26-explore-tab.md)
- **The demo contract** — four required attributes; *Try in Chat* is prefill-only.
- **Standing decisions** — a markdown content pipeline was **decided against**
  (HEEx is the pipeline), and Explained-vs-Manual held: **both stay.**
- **Known future break** — the Ramshackle tutorial asserts the Voice surface
  does not exist. When [II.6](#ii6--studio) ships, **update the tutorial; do not
  delete the assertion.**

## II.8 — Activity

- **What** — the one automatic log, far right.
- **Where** — `ActivityComponent`, `ActivityReport`
- **State** — SHIPPED
- **Map** — [`archive/08-08-26-home-activity-notes.md`](../archive/08-08-26-home-activity-notes.md)

## II.9–II.11 — The corner widget

One card filling the header gap, three sub-tabs, its own guard-sharing literal.

| Tab | Where | State | Map |
|---|---|---|---|
| **Time & Place** (weather) | `status/weather.ex`, `BusterClaw.Weather` | SHIPPED | `— none —` UNMAPPED |
| **Contacts** | `BusterClaw.Contacts` | SHIPPED | `— none —` UNMAPPED (sync side under [VI.2](#vi2--google-workspace)) |
| **Notify** | `NotifyLive` | SHIPPED | [`archive/07-30-26-sound-roadmap.md`](../archive/07-30-26-sound-roadmap.md) |

## II.12 — The home shader background

- **What** — the smoke shader, ambient behind the chat.
- **Where** — `Shaders`
- **State** — SHIPPED
- **Map** — [`archive/HUMO_ROADMAP.md`](../archive/HUMO_ROADMAP.md) · [`archive/HUMO_EXPRESSION_ROADMAP.md`](../archive/HUMO_EXPRESSION_ROADMAP.md)
- **The `/humo` tab is DELETED** — the shader collapsed onto the homepage. Smoke
  is ambiance; chat is chat. **The SDF attempt crashed WKWebView**, which is why
  GPU 3D is gated.

---

# Part III — Full-screen surfaces

## III.1 — Workspace

- **What** — the file manager over the agent's working folder, with free navigation and "Set as workspace".
- **Where** — `WorkspaceLive` (`/workspace`), `FileTree`, `BusterClaw.Workspace`
- **State** — SHIPPED
- **Map** — [`archive/08-01-26-workspace-review-roadmap.md`](../archive/08-01-26-workspace-review-roadmap.md)
- **Read before changing layout** — the registry, `jobs/`, `backgrounds/`,
  `Dispatch.md`, the `.buster-claw/` machine dir, and a **migration-order
  gotcha** are all recorded there.

## III.2 — Browser

- **What** — the in-app browser. A native child webview is overlaid on the surface in the desktop app.
- **Where** — `BrowseLive` (`/browse`), `BusterClaw.Browser`, `BrowserControl`, 8 Rust modules
- **State** — SHIPPED
- **Map** — four closed roadmaps:
  - [`archive/07-25-26-browser-engine-roadmap.md`](../archive/07-25-26-browser-engine-roadmap.md)
  - [`archive/07-22-26-browser-shell-rebuild-roadmap.md`](../archive/07-22-26-browser-shell-rebuild-roadmap.md)
  - [`archive/08-03-26-browser-closeout.md`](../archive/08-03-26-browser-closeout.md)
  - [`archive/07-18-26-agent-web-automation-roadmap.md`](../archive/07-18-26-agent-web-automation-roadmap.md)
- **The trap that keeps recurring** — **BrowseLive's template decides whether the
  native browser is ever registered in Rust.** Mount-order, across three
  languages, untested end to end. Root cause of the 08-08 live-tab fault.
- **Open, and HIGH** — walk a signed-in checkout to confirm the payment gate
  fires. **A cart-only errand proves nothing about it** (LAUNCH G-34).
- **Accepted ceiling** — the WKUIDelegate limit. Do not re-propose the swap.
- **DELETED** — Browserbase / cloud browser (`419577d`, −2158 lines). Its CDP
  driver was a Playwright sidecar prod never bundled. Do not rebuild.

## III.3 — Split view

- **What** — two views side by side in one tab.
- **Where** — `SplitLive` (`/split`), `ChromeHook`
- **State** — SHIPPED
- **Map** — [`archive/06-21-26-split-browser-roadmap.md`](../archive/06-21-26-split-browser-roadmap.md)

## III.4 — Terminal

- **What** — xterm.js over a PTY in the Tauri Rust backend, streamed over IPC.
- **Where** — `TerminalLive` (`/terminal`), `TerminalCommands`, `TerminalWorkspace`
- **State** — SHIPPED
- **Map** — [`archive/06-07-26-multiple-terminals-plan.md`](../archive/06-07-26-multiple-terminals-plan.md) ·
  [`archive/06-08-26-terminal-commands-menu-roadmap.md`](../archive/06-08-26-terminal-commands-menu-roadmap.md) ·
  [`archive/06-09-26-terminal-pull-queue-roadmap.md`](../archive/06-09-26-terminal-pull-queue-roadmap.md) ·
  [`archive/05-30-26-desktop-shell-terminal-hardening-plan.md`](../archive/05-30-26-desktop-shell-terminal-hardening-plan.md)

## III.5 — The Manual

- **What** — the guide, sourced from `user-guide/`, with in-page sub-tabs.
- **Where** — `UserGuideLive` (`/manual`), `BusterClaw.UserGuide`
- **State** — SHIPPED
- **Map** — `— none —` (UNMAPPED)
- **Open** — **the Manual has no test, and had the worst drift of any surface**
  in the 08-09 comb (`LEFTOVERS.md`).

## III.6 — Music library

- **What** — the audio library, byte-range serving, ingest, waveforms.
- **Where** — `MusicComponent` (inside the Studio's Mix tab), `MusicPlayerLive` (dock)
- **State** — SHIPPED
- **Map** — [`archive/07-30-26-music-roadmap.md`](../archive/07-30-26-music-roadmap.md)
- **Correction to older notes** — there is **no separate Music home tab.** The
  library lives inside the Studio's Mix tab; only the player is standalone.
- **Open, and HIGH** — `nosniff` is missing on four pipeline-less media routes
  (`LEFTOVERS.md`), plus two packaged walks.

---

# Part IV — Settings

Seven sub-tabs, one literal in `SettingsTabs`.

| Tab | Where | State | Map |
|---|---|---|---|
| **Appearance** | `AppearanceLive` | SHIPPED | see [I.4](#i4--appearance-skins-text-size-backgrounds) |
| **Voice** | `VoiceLive` | SHIPPED | [`archive/06-21-26-voice-roadmap.md`](../archive/06-21-26-voice-roadmap.md) |
| **Notify** | `NotifySettingsLive` | SHIPPED | [`archive/07-30-26-sound-roadmap.md`](../archive/07-30-26-sound-roadmap.md) |
| **Integrations** | `IntegrationsLive` | SHIPPED | see [VI.5](#vi5--operational-integrations-github-sentry-umami) |
| **Configuration** | `SettingsLive` | SHIPPED | `— none —` UNMAPPED |
| **Cmd List** | `CmdListLive` | SHIPPED | [`archive/CMD_LIST_EDITOR_ROADMAP.md`](../archive/CMD_LIST_EDITOR_ROADMAP.md) |
| **Security** | `SecurityLive` | SHIPPED | [`archive/05-30-26-security-notification-layer-research.md`](../archive/05-30-26-security-notification-layer-research.md) |

**Voice is TTS only.** Speech output runs through the native macOS synthesizer;
there is no microphone feature here. Whisper STT was demolished 06-28 as
overkill — **do not rebuild on Whisper**; use `SFSpeechRecognizer` if dictation
ever returns. This is a different thing from the Studio's [Voice tab](#ii6--studio),
which is recording, not settings.

**Configuration is UNMAPPED and carries the most weight of any settings tab** —
Google Workspace connection, agent models, the profile, onboarding progress, and
the recovery key all live there.

---

# Part V — The agent core

Not surfaces. The machinery every surface sits on.

## V.1 — The command surface

- **What** — the single catalog every entry point dispatches through: chat, CLI, email, phone.
- **Where** — `BusterClaw.Commands`, `commands/catalog/` (14 modules)
- **State** — SHIPPED
- **Map** — [`archive/05-17-26-command-surface-roadmap.md`](../archive/05-17-26-command-surface-roadmap.md)
- **The trust rule, stated once because it is misread often** — `:restricted`
  earns a confirmation from `:agent` and `:mcp`. **`:agent_untrusted` is stopped
  only by `gated: true`.** `:restricted` does *not* gate it.
- **Do not assert universals over the catalog.** Three sessions write into it at
  once; "the only gated verb" passed against `HEAD` and failed against the merged
  tree. A universal is fine when it *is* a review-forcing snapshot, not when it is
  scenery around a claim about something else.

## V.2 — Agent runner & backends

- **What** — the process the model actually runs in: `:claude`, `:codex`, `:opencode`.
- **Where** — `AgentRunner`, `AgentBackend`, `agent/`
- **State** — SHIPPED
- **Map** — [`archive/08-04-26-agent-backend-roadmap.md`](../archive/08-04-26-agent-backend-roadmap.md)
- **Open** — `agent/chat.ex` is owed a cut; the frozen promise was broken 08-08
  (`LEFTOVERS.md`). `opencode models` is uncached and must not reach a render path.

## V.3 — Model policy

- **What** — a global default model plus per-surface overrides, with a sonnet floor on the money surfaces.
- **Where** — `ModelPolicy`
- **State** — SHIPPED
- **Map** — [`archive/08-04-26-model-versatility-roadmap.md`](../archive/08-04-26-model-versatility-roadmap.md)
- **The floor is unenforceable off Claude** and must **not** be faked with an unmeasured rank.

## V.4 — Policy engine & trust tiers

- **What** — who may run what: `:operator`, `:agent`, `:agent_untrusted`, `:mcp`.
- **Where** — `PolicyEngine`, `AgentToolPolicy`
- **State** — SHIPPED
- **Map** — `— none —` as its own document; the rules are distributed across
  [V.1](#v1--the-command-surface), [VI.1](#vi1--the-clinch-credentials) and the security research.
- **UNMAPPED, and this is the most load-bearing unmapped thing in the app.**

## V.5 — Sentinel (audit & notify)

- **What** — the durable audit spine feeding the Security alert center.
- **Where** — `BusterClaw.Sentinel`
- **State** — SHIPPED (Phases 0–1 + CSP)
- **Map** — [`archive/05-30-26-security-notification-layer-research.md`](../archive/05-30-26-security-notification-layer-research.md)
- The MCP-endpoint tier-bypass finding is **moot** — that endpoint was deleted in
  the pull-queue cut. The scoped `:mcp` token tier remains.

## V.6 — Dispatch, orchestration, swarm

- **What** — the pull-queue the agent works, and the on-duty email loop that feeds it.
- **Where** — `Dispatch`, `Orchestrator`, `swarm/`, `orchestration/`
- **State** — SHIPPED
- **Map** — [`archive/05-31-26-orchestration-plan.md`](../archive/05-31-26-orchestration-plan.md) ·
  [`archive/06-17-26-always-on-shift-roadmap.md`](../archive/06-17-26-always-on-shift-roadmap.md) ·
  [`archive/06-13-26-on-shift-and-email-reply-roadmap.md`](../archive/06-13-26-on-shift-and-email-reply-roadmap.md)
- **`on-duty` / `off-duty` is the single front door.** Mailman poll and shift run
  are deprecated. The Orchestrator is a janitor; shifts are indefinite.
- **Free forever, and unpaywallable by construction.**

## V.7 — Skills

- **What** — the agent's own instruction packs.
- **Where** — `BusterClaw.Skills`
- **State** — SHIPPED
- **Map** — [`archive/SKILL_PROMPTS_ROADMAP.md`](../archive/SKILL_PROMPTS_ROADMAP.md)
- **Open** — two skill seeds were never combed; the scene3d guide should move
  into a reference skill (both `LEFTOVERS.md`).
- **App-wide defect, no owner** — `maybe_write` never overwrites, so **shipped
  defaults can never be tightened.** That includes `memory/policy.md` and the
  trusted-sender lists. Seeded defaults have no upgrade path.

## V.8 — Memory

- **What** — the agent's durable notes across sessions.
- **Where** — `BusterClaw.Memory`
- **State** — SHIPPED
- **Map** — [`archive/s0.3-hermes-4tier-memory.md`](../archive/s0.3-hermes-4tier-memory.md) (research, not a build plan)
- **UNMAPPED as built.**

## V.9 — Scene3D

- **What** — a 3D card in the chat. Validated JSON in, SVG card out.
- **Where** — `BusterClaw.Scene3D`
- **State** — SHIPPED
- **Map** — [`archive/08-08-26-scene3d-roadmap.md`](../archive/08-08-26-scene3d-roadmap.md)
- **The model never writes code.** three.js, model-authored WGSL, and 3D-in-Elixir
  are all ruled out with reasons. **WGSL "Phase 4" died with the roadmap — it is
  not leftover work.**
- **It sole-sources the validated 5-slot palette.** Promote it; never copy it.

## V.10 — Shaders & image-reactive backgrounds

- **What** — agent-authored background shaders; next, ones that sample the image underneath.
- **Where** — `BusterClaw.Shaders`
- **State** — shaders SHIPPED; image-reactive **SCOPED**
- **Map** — [`IMAGE_SHADER_ROADMAP.md`](IMAGE_SHADER_ROADMAP.md)
- The durable half is the **skill**, not the rendering.

## V.11 — Library, analyzer, ingest, journal

- **What** — the supporting stores: recorded media, analysis, ingest, the run journal.
- **Where** — `Library`, `Analyzer`, `ingest/`, `Journal`
- **State** — SHIPPED
- **Map** — `— none —` (UNMAPPED)

---

# Part VI — Integrations

## VI.1 — The Clinch (credentials)

- **What** — one place for credentials, plus SSH remote access, as **one** roadmap.
- **Where** — `BusterClaw.Clinch`, `clinch/vault.ex`, `ClinchPanels`, Tauri `clinch_*` commands
- **State** — **ACTIVE. Phases 0–2 shipped 08-08. Phase 3 is next.**
- **Map** — [`CLINCH_ROADMAP.md`](CLINCH_ROADMAP.md) — **supersedes** `SSH_REMOTE_ACCESS_ROADMAP` (archived unstarted)
- **The decision** — remote may *use* credentials, never *manage* them. Enforced
  by a Tauri-IPC split and a trusted-token floor, **not** a policy check.
- **Phase 3 unblocks BusterPhone.** This is the dependency at the front of the build.

## VI.2 — Google Workspace

- **What** — Gmail, Calendar, Drive, Docs, Sheets, Slides, Tasks, People — OAuth, sync, and commands.
- **Where** — `BusterClaw.Google` (16 modules), `catalog/google*.ex`, `GwsPanels`
- **State** — SHIPPED
- **Map** — [`archive/05-17-26-gmail-integration-roadmap.md`](../archive/05-17-26-gmail-integration-roadmap.md) ·
  [`archive/GWS_SEAMLESS_CONNECT_ROADMAP.md`](../archive/GWS_SEAMLESS_CONNECT_ROADMAP.md)
- **Free, deliberately** — goodwill, not a paid tier. CASA review is a launch item.

## VI.3 — Twilio / BusterPhone

- **What** — a real phone number: answering machine + SMS through the same command surface.
- **Where** — `BusterClaw.Telephony` (`drain.ex`, `relay.ex`, `twilio.ex`, `pins.ex`), `PhoneComponent`
- **State** — **ACTIVE — the money leg.** Inbound path complete: relay deployed
  07-11, Mac-side drain shipped 07-12.
- **Map** — [`phone-maps/BUSTERPHONE_ROADMAP.md`](phone-maps/BUSTERPHONE_ROADMAP.md) ·
  vending mechanics in [`phone-maps/NUMBER_VENDING.html`](phone-maps/NUMBER_VENDING.html)
- **The drain polls PostgREST — it is not Slipstream.** Persist-then-ack, with a transcript grace window.
- **Next actions are the operator's**, in order: upgrade Twilio → wire the Voice
  webhook → set `SUPABASE_URL` / `SERVICE_ROLE_KEY` → call it.
- **This is the entire paywall.** Managed telephony alone. Never
  BYO-Twilio-as-paid; voice-first means no A2P. Signature Feed was **cut 07-14** —
  do not re-propose.

## VI.4 — The relay (Supabase)

- **What** — the deployed edge the phone talks to.
- **Where** — `telephony/relay.ex` + deployed functions
- **State** — SHIPPED
- **Map** — folded into [BusterPhone](#vi3--twilio--busterphone)
- **Open** — confirm the rotated DB password reached the password manager (`LEFTOVERS.md`).

## VI.5 — Operational integrations (GitHub, Sentry, Umami)

- **What** — pull operational data in on a `Service` behaviour: fetch, verify webhook, normalize.
- **Where** — `BusterClaw.Integrations` + `github.ex` / `sentry.ex` / `umami.ex`
- **State** — SHIPPED
- **Map** — [`archive/INTEGRATION_PLAN.md`](../archive/INTEGRATION_PLAN.md)

## VI.6 — Web search & data sources

- **What** — search that *informs*, and a `datareq` channel that supplies numbers.
- **Where** — `catalog/web.ex`, `BusterClaw.Search`, `UrlGuard`
- **State** — SHIPPED
- **Map** — [`archive/08-05-26-chart-build-web-data.md`](../archive/08-05-26-chart-build-web-data.md)
- **WebFetch reaches loopback — denied everywhere.** FRED was dropped; do not reopen.

## VI.7 — Weather

- **What** — the provider behind Time & Place.
- **Where** — `BusterClaw.Weather`
- **State** — SHIPPED · **UNMAPPED**

## VI.8 — Notes That Float / Shadiox

- **What** — agent-authored WGSL shader avatars on notesthatfloat.com; a separate JS app with its own accounts, model running on the user's Mac via `AgentRunner`.
- **Where** — outside this repo
- **State** — SCOPED (07-22)
- **Map** — `— none —` in this repo; scope recorded in project memory.

---

# Part VII — Platform & release

## VII.1 — The Tauri desktop shell

- **What** — the native app: PTY, native webview, Keychain, IPC, ACLs.
- **Where** — `desktop/tauri/`, ~4,771 lines of Rust
- **State** — SHIPPED
- **Map** — [`archive/07-22-26-browser-shell-rebuild-roadmap.md`](../archive/07-22-26-browser-shell-rebuild-roadmap.md) is the closest thing to a shell document.
- **The recurring failure mode** — a Tauri command can be **ACL-dead**: it
  compiles, it is registered, and it can never be called, because `build.rs` or
  capability registration is missing. Co-presence commands sat that way until
  07-17. **Grep cannot see it, and neither can the test suite.**

## VII.2 — Apple signing & notarization

- **What** — a signed, notarized, stapled DMG for both architectures.
- **State** — **ACTIVE. Enrollment cleared 08-01. The next action is G-2, the Developer ID cert.**
- **Map** — [`LAUNCH_ROADMAP.md`](LAUNCH_ROADMAP.md)
- **Two releases, not one.** R1 = signed DMG to a known handful (~1 week). R2 = public download.
- **No feature freeze** — which is exactly why we prefer CI assertions over checklists.
- MAS is permanently closed. **Never lipo the ERTS.** Do not renumber III.E / III.F / III.G / III.J — code cites them.

## VII.3 — Distribution & go-to-market

- **What** — free beta → charge, BYO Claude, MIT open core, busterclaw.lol, MoR.
- **State** — ACTIVE, folded into the launch map.
- **Map** — [`LAUNCH_ROADMAP.md`](LAUNCH_ROADMAP.md)

## VII.4 — CI gates

- **What** — the checks that hold the line: file sizes, cycles, Rust, macOS floor, docs drift, command-surface smoke.
- **Where** — `scripts/check_*.sh`, `scripts/smoke_*.sh`
- **State** — SHIPPED, **with one red**
- **Map** — [`archive/08-03-26-code-quality-refactor.md`](../archive/08-03-26-code-quality-refactor.md) ·
  [`archive/07-17-26-code-quality-roadmap.md`](../archive/07-17-26-code-quality-roadmap.md) ·
  [`archive/DOC_DRIFT_ROADMAP.md`](../archive/DOC_DRIFT_ROADMAP.md)
- **🔴 The Dialyzer gate is RED on `main`.** It exits 2 with 56 findings; the
  08-02 baseline rotted and was never extended. 44 are accepted-class noise,
  **12 can be real defects.** There are no PRs here, so **CI blocks nothing — a
  gate everyone believes is running, isn't.** This has no roadmap file and
  should get one.
- **A gate run against a dirty working tree can hide a red `main`.** Three
  sessions share this tree; `check_file_sizes.sh` was green locally for three
  commits while `main` was over the cap.

## VII.5 — Code health

- **What** — the standing quality position: ~170k LOC, dead-code passes, decomposition.
- **State** — SHIPPED (last pass closed 08-09)
- **Map** — [`archive/08-09-26-dead-code.md`](../archive/08-09-26-dead-code.md)
- **The durable half was four guards, not 22 deletions.** The sharpest lesson: a
  `{__MODULE__, :fun}` seed registry is invisible to grep **and** to
  `--warnings-as-errors`, so a `defp` conversion passed 3,569 tests and would
  have broken seeding at runtime. **Every grep inventory is a lower bound.**
- **Open** — decompose the surviving hotspots and make regrowth visible (`LEFTOVERS.md`).

---

# Part VIII — Deleted on purpose

Listed so nobody rebuilds them, and so an old document mentioning them is
recognisable as stale.

| Thing | When | Why |
|---|---|---|
| **Trading, Portfolio, MarketData, Watchlist, Chart Build** | 08-08 (`293f47f`, ~22k lines) | removed whole — [`archive/08-03-26-trading-tab-critical-review.md`](../archive/08-03-26-trading-tab-critical-review.md) |
| **Extensions** | 08-08 (`a89163e`) | built 08-07, deleted with the Trading stack it existed to re-home |
| **Browserbase / cloud browser** | 07-12 (`419577d`) | its CDP driver was a sidecar prod never bundled |
| **Whisper STT** | 06-28 | overkill; only `say`-based TTS remains |
| **The `/humo` tab** | 07-04 | collapsed into the homepage background |
| **The MCP endpoint** | pull-queue cut | scoped `:mcp` token tier remains |
| **Signature Feed** | 07-14 | cut as a paid tier |

---

# Part IX — What this map makes visible

Three things you cannot see from the roadmap folder:

**1. The unmapped middle.** Twelve sections govern themselves:

> [dock navigation](#i1--dock-navigation) · [the dock strip](#i2--the-dock-strip-timers-notifications-player) ·
> [the Calendar surface](#ii4--calendar) · [weather](#vi7--weather) · [contacts](#ii9ii11--the-corner-widget) ·
> [the Manual](#iii5--the-manual) · [Settings → Configuration](#part-iv--settings) ·
> [the policy engine](#v4--policy-engine--trust-tiers) · [memory](#v8--memory) ·
> [library / analyzer / ingest / journal](#v11--library-analyzer-ingest-journal) ·
> [the Tauri shell](#vii1--the-tauri-desktop-shell) (no dedicated map)

Two of those are load-bearing. [Policy engine and trust tiers](#v4--policy-engine--trust-tiers)
decide what the agent may do, and have no document. [Settings → Configuration](#part-iv--settings)
holds the Google connection, the models, and the recovery key, and has no
document. Neither is a gap in the *product* — both work — but neither has a place
where a change gets thought about before it is made.

**2. One dependency chain owns the schedule.** Clinch Phase 3 → BusterPhone →
the paywall. Everything else on this map is parallel to it.

**3. Two things are waiting on a person, not an agent.** The Studio's
`getUserMedia` spike needs someone to click a permission dialog at a packaged
build; G-2 needs someone to request a certificate. Neither will move by being
planned harder.

---

# Rules for this file

1. **Every surface and integration appears exactly once.** If a thing has two
   homes, it gets one section and the other place links to it.
2. **A section with no roadmap says `— none —` and is tagged UNMAPPED.** Never
   invent a link to make a row look finished.
3. **When a roadmap is archived, its section stays** — the link moves to
   `archive/` and the state becomes SHIPPED. Sections are never deleted for
   being done; they are deleted only when the *feature* is, and then they move to
   [Part VIII](#part-viii--deleted-on-purpose).
4. **State claims are checkable.** Every one is either a roadmap's own header or
   a module that exists. If you cannot point at one, the state is UNMAPPED.
5. **Don't restate a roadmap here.** A section is four fields plus the handful
   of facts that would cause a mistake if forgotten. Everything else lives in
   the roadmap and stays there.
