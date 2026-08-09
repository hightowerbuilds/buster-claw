# Explore — a home tab that teaches the machine

> **Trading tutorial deleted 2026-08-08.** The Trading surface was removed from the
> app (`293f47f`), and its Explore tile, tutorial panel and roster entry went with
> it. Every Trading row below is struck rather than removed: what a tutorial was
> asked to explain, and what it got wrong, is the record this roadmap exists to
> keep. The tile count went to **four built of five**, not five of six — and as
> of 08-08 it is **six of six**, with the atlas's own market cycle retired too
> (see Phase 2).

**Scoped 08-02-26 · Status: ACTIVE · Content accuracy pass scoped 08-04-26 ·
Roster completed + demo contract landed 08-08-26.**

> **Where this stands (08-08):** all six feature tutorials are built — no stubs
> remain — and every worked example carries the demo contract (prerequisites,
> side effects, where the stop is, expected result and failure state) plus Copy
> prompt and, where a chat prompt is the right trigger, Try in Chat. What is
> left is editorial and structural, not content: the BusterClaw.lol / NTF
> rewrite, the Explore-vs-Manual decision, cross-linking, and a packaged-app
> walk. See "Recommended execution order" at the end of Phase 2.5.

A new home sub-tab, **Explore**, alongside Chat / Calendar / Notes / Studio, with
its own second-level rail. It holds a growing collection of tutorials — one per
feature surface — plus outbound cards for **busterclaw.lol** and
**notesthatfloat.com**. It opens on an **Intro** sub-tab that says what Explore
is for.

**Why now:** R1 is a signed DMG to a known handful of first-time users
(`LAUNCH_ROADMAP.md`). The app has 150+ commands and a dozen surfaces; the only
in-app teaching today is the Manual (reference, three sections, behind the footer
dock) and Get Started (a Settings checklist). Neither shows anyone *how to drive
the thing*. Explore puts tutorials on the homepage, where people actually are.

---

## The lay of the land (read before building)

- The home tab system lives in `StatusLive` (`status_live.ex`): a literal
  whitelist in the `select_home_tab` guard, a `{key, label}` button list in the
  template, and one `:if` block per panel. **House convention:** panels render
  behind `:if`, which discards component state on every tab switch — so any
  sub-tab selection that should survive a glance at Chat is owned by
  `StatusLive`, not the component (see the `:studio_*` assigns and their
  comments).
- The corner widget (`home_widget.ex`) is the pattern for a second-level rail:
  presentational function component, `role="tablist"`, events handled by the
  parent.
- **The Manual already has a content pipeline** (`BusterClaw.UserGuide`):
  markdown files in a repo-root dir, `@external_resource` + compile-time embed
  (ships in releases, hot-reloads in dev), rendered to sanitized HTML by
  `BusterClaw.Markdown`. Tutorials should reuse this shape, not invent one.
- Home sub-tab tests live in `status_live_test.exs` under
  `describe "home sub-tabs"`; the studio test notes the guard is a whitelist
  ("not a formality") — every new tab key gets a test that it opens.

## Decisions taken while scoping (revisit if wrong)

1. **Both outbound cards open in the app's own browser** —
   `/browse?url=…` — not `SystemBrowser.open/1`. The app has a browser; using
   it is the point. Flip to `SystemBrowser` if the operator prefers them
   landing in the real browser.
2. **The busterclaw.lol card sells the asset model** (operator ask, 08-02):
   users have likely already been to the site, so the card's job is the frame —
   busterclaw.lol is the counter where the agent's **phone number** is bought.
   The number is the one purchasable asset (retailer model, one bill,
   `NUMBER_VENDING.html`), and it is pitched as what the machine is ultimately
   for: an agent that can answer when the world calls. Copy stays honest about
   today — it describes what the site *is*, not a store that isn't live yet;
   revisit the wording when vending actually opens (blocked on paid Twilio,
   per the dossier).
3. **Sub-tab state (`:explore_tab`) is owned by `StatusLive`**, per the house
   convention above. Default `"intro"`.
4. **The sub-tab registry lives in the component** (`ExplorePanel.@tabs`), and
   the parent's event whitelist reads `ExplorePanel.tab_keys/0` — one source of
   truth, so adding a tutorial never touches a guard in two files.

## Open question — Explore vs the Manual

Two learning surfaces will drift into each other unless the line is drawn now.
Proposed line: **the Manual is reference** (what a thing is, exhaustively),
**Explore is tutorial** (do this, then this, and here's what the agent can take
over). If that holds, the Manual stays as-is and Explore never duplicates it —
tutorials link to Manual sections instead of restating them. If it doesn't hold,
the honest move is folding the Manual's sections into Explore's rail and
retiring `/manual`. **Decide by the end of Phase 2, when the first real
tutorials make the overlap visible.** Don't decide it in the abstract.

---

# Phase 0 — The tab exists, with an Intro that earns it

*Small, shippable on its own. Partially drafted already.*

- [x] `BusterClawWeb.ExplorePanel` (`components/explore_panel.ex`): presentational
  component; `@tabs` registry + `tab_keys/0`; second-level rail styled like the
  corner widget's; Intro panel with the what-this-is copy and a two-card grid —
  busterclaw.lol (asset-model framing, decision 2) and Notes That Float.
- [x] Wire into `StatusLive`: `:explore_tab` assign in mount; `"explore"` in the
  `select_home_tab` guard; `select_explore_tab` handler validating against
  `ExplorePanel.tab_keys/0`; `{"explore", "Explore"}` in the button row; the
  `:if` render block. **Wired 08-02.**
- [x] Tests, in the existing `home sub-tabs` describe: Explore opens on Intro
  with both `/browse?url=…` cards; a forged `select_explore_tab` key is
  refused without a crash; the sub-tab selection survives a round-trip
  through Chat. `mix precommit` green.
- [ ] Eyeball it in the real app (operator runs the server — agent tasks get
  SIGTERM'd). The rail with one tab should not look broken; if it does, hide
  the rail until Phase 2 gives it a second tab.

**Done when:** the tab is on the homepage, Intro reads well, NTF link lands in
the browse tab, suite green.

# Phase 0.5 — The launcher grid and the operator's roster *(added 08-02, operator ask)*

The Intro stops being a page with two cards and becomes a **launcher**: a grid
of square tiles, one per sub-tab, each opening that tab in the rail. The
sub-tab roster is now **operator-specified**, superseding the proposed roster
that Phases 2–3 carried below:

| Tile | Sub-tab holds |
|---|---|
| **BusterClaw.lol** | What the site is + the asset-model framing (decision 2) + the actual link |
| **NTF** | What Notes That Float is + the actual link |
| **Shaders & Backgrounds** | WGSL homepage shader, drop-a-`.wgsl` hot-swap, Appearance |
| **BusterPhone** | The answering machine / SMS relay |
| **BrowserControl** | The browser the agent drives, Agent Mode, the payment gate |
| **Cmd & Promptship** | The 150+ command surface and how to prompt an agent that holds it |
| **Gmail/GWS** | Google Workspace connect → sync → act |

- [x] Rebuild the Intro as the tile grid; move the two outbound cards' copy
  into their own `site` / `ntf` sub-tabs (link lives there now).
- [x] Stub panels for the five feature tabs: eyebrow + a true paragraph about
  the surface + a deep link into the real tab (`/appearance`, `/phone`,
  `/browse`, `/cmd-list`, `/settings`) + an honest "tutorial in the works"
  line. Stubs are placeholders for Phase 2 content, not the content.
- [x] Rail gains `flex-wrap` (8 tabs now); tests updated: every non-Intro key
  has both a rail button and a tile, the external links moved with their
  copy, a stub deep-links its surface, persistence proven with a real second
  tab. `mix precommit` green 08-02.

**Done when:** every square opens a tab that says something true, and nothing
claims to be a tutorial that isn't one yet.

*Addendum (operator, 08-02):*
- [x] DONE 08-02 — Get Started's **3-step onboarding moved from Settings into the Intro**
  (above the tile grid — setup before sightseeing). The quick-chat starters
  are dropped, not moved; `/get-started`, `GetStartedLive`, and its Settings
  sub-tab entry retire with the move. The copy-command button markup works
  as-is (global listener in `globals.js`). Rendered as a native `<details>`
  collapsible, closed by default (operator, same day) — returning users see
  one quiet row; the `.ic-collapse-summary` CSS finally has a consumer again.

# Phase 1 — The content pipeline

*How tutorials get written, before any are.*

- [ ] `BusterClaw.ExploreGuide`, mirroring `UserGuide`: markdown files in
  `explore/` (repo root, beside `user-guide/`), `@sections` registry,
  compile-time embed, `Markdown.to_html/1`. Rail order = registry order,
  Intro pinned first.
- [ ] Decide the escape hatch: markdown covers prose + screenshots + plain
  `<a href="/browse">`-style deep links into the app (full-page nav — fine).
  A tutorial that needs live interactivity (buttons that fire events, "try it
  here" panels) gets a HEEx panel function in `ExplorePanel` instead, keyed
  the same way. Both kinds coexist in one rail; markdown is the default.
- [ ] A tutorial template, written down in `explore/README` or the first file's
  header. Proposed skeleton, so every tutorial answers the same four things:
  **what this surface is → drive it yourself (steps) → hand it to the agent
  (the actual commands/prompts) → where the receipts land** (Sentinel/audit,
  workspace files). The fourth section is the product's differentiator; no
  tutorial ships without it.

**Done when:** adding a tutorial = drop a file + one registry line, and the
template exists.

# Phase 2 — Fill the roster (the operator's five, made real)

Replace each Phase 0.5 stub with an actual tutorial. One tutorial per commit.

- [x] **Gmail/GWS** — jumped the queue (operator ask, 08-02). Content =
  prompt-your-way walkthroughs: what a user literally types, then how it
  unfolds command-by-command. Six cycles: the morning brief (sync → brief),
  draft-don't-send triage (`gmail_draft_create` → gated `gmail_send`),
  calendar → reminders (`google_calendar_sync` → `notify_create`), the
  unattended loop (trusted sender + `on-duty` → auto-enqueue →
  `dispatch_reply`), building files (Sheets/Slides/Docs + Drive folders,
  moves, uploads; `drive_share`'s own confirm gate), and email attachments
  (`drive_export` → `gmail_draft_create` attachments → gated send). Every
  command named is real — verified against the catalog and `cli.ex` before
  writing, and the test asserts each one exists. Built as a HEEx panel (the sanctioned
  escape hatch), which makes it the de-facto template: `example` + `prompt`
  sub-components now exist for the rest of the roster. **Re-evaluate Phase 1's
  markdown pipeline when the next tutorial is written** — if it also wants the
  prompt/unfold shape, HEEx is the pipeline and Phase 1 collapses to "the
  sub-components".

- [x] **Command List** — BUILT 08-02. Renamed from "Cmd & Promptship" (operator, 08-02).
  The *atlas* of the command surface: example-oriented pass over the non-GWS
  families (library/journal/notify, finance, telephony, web-without-the-
  browser-tab, dispatch/memory, skills), deliberately light on Gmail/Drive
  (the GWS tab owns those) and light on deep browser driving (the
  BrowserControl tab will own that — the atlas points at both). Opens with
  the anatomy of a command (read / mutate / gated · trust tiers) and one
  inline SVG: the funnel — chat / terminal / trusted email → one command
  surface → policy gates → surfaces, with everything landing on the Sentinel
  feed. SVG is theme-aware (currentColor + the hazard var), no external
  assets. Same command-existence contract test as GWS.

- [x] **BrowserControl** — BUILT 08-02. The load-bearing concept is
  *where the agent's hands are*, so it opens with one SVG mapping the three
  driving surfaces: your live tab (logged in, watched, audited), the
  ephemeral sandbox tab (default for new tabs — no cookies, forgets), and
  the Agent Mode window (own Chromium, scope frozen, payment gate). Five
  cycles: read-over-my-shoulder (`browser_current/read/capture_page`),
  act-on-the-live-tab (`find_elements` → `click`/`fill`, index staleness),
  the sandbox errand (`browser_open_tab` default-ephemeral → `wait` →
  `extract`), routine-into-saved-check (`browser_flow` →
  `browser_check_save/run/list`, background engine), and the Agent Mode
  commerce errand (scope halt, cart freeze, payment handoff — *the human
  pays; the agent cannot pay and cannot confirm*, per the closeout
  roadmap's current posture; finish ≠ stop). Same command-contract test.

- [~] ~~**Trading**~~ — BUILT 08-02, **DELETED 08-08 with the surface**. Deliberately the
  *simple* one: no cycles, just (1) how to connect Robinhood — the two
  terminal commands the Trading tab itself shows (`claude mcp add …` +
  `claude mcp login robinhood`, OAuth → Keychain, the #65895 logout/login
  workaround), with the app-holds-no-credentials point up front — and (2) a
  plain can/can't split. CAN: read balances, positions with cost basis,
  charts, earnings (accounts masked to last-4, never persisted); answer
  market questions in the trading chat; *propose* an order as a typed
  confirm card. CAN'T: place/amend/cancel on its own (read-only tool
  allowlist by construction — only the operator's click submits, and only
  to the one account Robinhood marks Agentic); never auto-retries an
  uncertain submit; never sees the password. Source of truth:
  `Trading`/`TradingOrder` moduledocs + trading-tab memory. **All of that is gone;
  kept because the can/can't split was the clearest thing this roadmap produced,
  and the next safety-sensitive tutorial should be shaped the same way.**

- [x] **BusterPhone** and **Shaders & Backgrounds** — BUILT 08-08. Details in
  Phase 2.5 below. The roster is complete: six tutorials, no stubs.

- [x] **The atlas stops teaching trading** (operator, 08-08). Cycle 2 of the
  Command List was "The market at a glance" — `finance_quote`, `finance_news`,
  `finance_fundamentals`, `finance_filings`. It is now **"The notebook and the
  vault"** (`note_search` → `note_read` → `note_save` → `note_create`).

  Scope decided explicitly, because "no more trading" had two readings: the
  `finance_*` commands **still exist** and are **still on `/cmd-list`**. Nothing
  was deleted. They are read-only public-record research (SEC EDGAR, BLS,
  Finnhub) that survived the 08-08 Trading deletion; they simply stopped being
  one of the six things Explore puts in front of a first-time user. The test
  asserts the market cycle is *gone* and that none of the four command names
  appear, rather than only asserting the new cycle is present — a `refute` was
  the point of the change.

  The replacement was chosen for content, not just to fill the slot: the note
  verbs carry two lessons the market cycle had no equivalent of — `note_create`
  vs `document_save` (the operator's writing vs the agent's findings, a
  distinction the catalog enforces in its own descriptions), and `note_save`'s
  required `revision`, a real optimistic-concurrency rule an operator can
  actually hit by editing a note in the Notes tab mid-run. Both are asserted
  against catalog metadata.

- [ ] Make the Explore vs Manual call (see open question above). Six real
  tutorials now exist, so the overlap is visible and this is decidable —
  it is the oldest open item on this roadmap.

# Phase 2.5 — Content accuracy and runnable demos *(audit 08-04-26)*

Explore's structure is strong, but it is not editorially finished. Two feature
tutorials are still placeholders, several foundational explanations conflict
with the implementation, and every “demo” is a static worked example rather
than something the operator can try.

## Audit summary

| Tab | Status | Required work |
|---|---|---|
| **Intro** | Accuracy rewrite complete 08-04 | It now recommends Claude, names Codex and OpenCode support, explains both Google connection paths, and distinguishes archived untrusted mail from trusted Dispatch work. |
| **BusterClaw.lol** | Accuracy rewrite complete 08-04 | Phone-number vending is now described as planned/future work until the store is actually live. |
| **NTF** | Accuracy rewrite complete 08-04 | It now describes the sibling project as a creative-writing and journaling app with spatial 3D visualization, not Buster Claw's operator notebook. Grouping it under **Elsewhere** or **About** remains an information-architecture option. |
| **Models** | **Complete 08-08** | Harness copy matches Claude/Codex/OpenCode support; the Claude-only pin it described went with Trading on 08-08. Both examples now carry the demo contract, including the read-only current-policy demo. |
| **Shaders & Backgrounds** | **Tutorial BUILT 08-08** | `Explore.Shaders`. Catalog (Off / built-ins / workspace / images), Home *and* Terminal as independent targets, the WGSL file contract, palettes, and the honest refresh story. Two corrections landed with it — see below. |
| **BusterPhone** | **Tutorial BUILT 08-08** | `Explore.Phone`. Inbound diagram, recording-vs-enqueueing as the spine, the asymmetric trust rules in a table, costs, and outbound `sms_send`'s three limits. |
| **Gmail/GWS** | **Complete 08-08** | The tutorial separates policy gates, trust tiers, `confirm_send`/`confirm_share`, and the trusted unattended `dispatch_reply` path, and covers bundled and Advanced OAuth setup. All six cycles carry the demo contract. |
| **Command List** | **Complete 08-08** | Counts and all three metadata axes are guarded against the live catalog by a contract test. Cycle 2 was the market/trading cycle until 08-08 — see the trading note below. All six cycles carry the demo contract. |
| **BrowserControl** | **Complete 08-08** | The three-surface explanation, with audit copy that distinguishes redacted page ingestion, ordinary reads, and consequential actions. All five cycles carry the demo contract. |
| ~~**Trading**~~ | **Deleted 08-08** | The tutorial went with the surface. Its one open correction — *"soften the absolute claim that funding is the most an order can touch"* — was a real inaccuracy that shipped for six days, and is worth remembering as the kind of overclaim a safety tutorial produces when it paraphrases a guarantee. |

## Foundational rewrites

### 1. Tell one harness story

The Intro and Models launcher say “Claude only”; the Models tutorial later says
Claude, Codex, and OpenCode. Replace the shared explanation with:

> Install a supported agent CLI. Claude Code is the recommended one; any surface
> can also use Codex or OpenCode.
>
> *(Amended 08-08: the "required for Trading" clause went with the surface.)*

The existing `brew install --cask claude-code` command is still supported, but
Anthropic now presents its native installer first. Keep Homebrew as a macOS
choice rather than implying it is the only installation route:
<https://code.claude.com/docs/en/getting-started>.

### 2. Replace the Command List taxonomy

The tutorial treats `read`, `mutate`, and `gated` as three equivalent kinds.
They are not. The catalog had **165 commands** when this was written and has
**162** since the trading stack was deleted (08-08); the contract test is the
authority, not this list. Three separate axes:

- **Operation type:** 64 read, 17 trigger, 81 mutate.
- **Trust tier:** 70 safe, 92 restricted.
- **Additional policy flag:** 20 gated commands.

`gated` is not an operation type. `safe` also does not universally mean that
nothing leaves the machine. Rewrite the diagram and legend around these axes.
Replace “every tab, every feature” with “agent-addressable backend operations”:
Appearance and Studio are intentionally UI-only.

### 3. Explain confirmation mechanisms separately

The GWS tutorial currently collapses three different controls into “gated”:

1. Safe versus restricted command tier.
2. The policy-level `gated` flag that blocks untrusted-provenance runs and files
   a pending approval.
3. Command-specific confirmation arguments such as `confirm_send` and
   `confirm_share`.

Rewrite every send/share example to name the actual mechanism it uses. Do not
promise that adding “show me before you send” to a prompt creates a UI-enforced
hold unless the command path actually provides one.

### 4. Correct the trust and connection language

- Untrusted Gmail is synced and archived to the Library; it is not ignored. Only
  trusted senders become Dispatch work.
- Trusted SMS becomes Dispatch work without a caller PIN. Voicemail requires
  both a trusted number and a verified PIN.
- Bundled one-click Google OAuth is conditional. When the bundled client is not
  available, the actual path is Advanced setup with the operator's OAuth client.

## Complete the two missing tutorials — **DONE 08-08**

Both are built. Every tab in `@features` now has a real tutorial, so
`Registry.stubs/0` returns `[]` and the stub `:for` in `ExplorePanel` is
vacuous. The stub module is deliberately kept: it is what makes adding a
sub-tab a one-line edit in the registry, and a new `@features` entry with no
panel must still render something true rather than a dead rail button.

### BusterPhone — `Explore.Phone`

- [x] Diagram inbound voice/SMS → relay → local archive → trust decision →
  optional Dispatch item. The archive box sits **above** the trust box on
  purpose: that ordering *is* the lesson.
- [x] Explain recording versus enqueueing: strangers are recorded by design but
  never become agent work.
- [x] Show the two-factor voicemail rule (trusted number + PIN) and the lighter
  trusted-number-only SMS rule. Built as a three-row table with
  `data-phone-sms-rule` / `data-phone-voicemail-rule` anchors, so the test
  asserts the right cell rather than the word "PIN" appearing anywhere.
- [x] Walk through unheard voicemail, transcript/recording playback, cost
  breakdown, and explicit `phone_mark_heard` behavior. The provisional →
  settled cost story is stated as "a total that grows slightly after the fact
  is the system working", because it looks like a bug otherwise.
- [x] Explain outbound `sms_send`: separately enabled, gated, audited, opt-out
  aware, and capped per recipient per UTC day.
- [x] Safe demo: cycle 1 is `phone_stats` + `phone_list unheard_only`, and the
  cycle exists partly to teach that reading is not hearing.
- [x] Setup is stated honestly: the operator's own Twilio + Supabase relay, and
  no store to buy a number from yet. The test asserts that claim so it cannot
  quietly become a promise.

### Shaders & Backgrounds — `Explore.Shaders`

- [x] Explain the shared catalog: Off, built-in shaders, workspace shaders, and
  uploaded images. Built-ins and the pool size render **from** `Appearance`.
- [x] Show that both Home and Terminal are background targets.
- [x] Walk through selecting a built-in shader before introducing custom WGSL.
- [x] Explain the `shaders/<name>.wgsl` contract, `fs_main`, the shared prelude,
  size/name validation, and the distinction between background shaders and
  `*-face` shaderfaces.
- [x] State the real refresh behavior: no application rebuild, but the file must
  appear in the Appearance catalog and the operator must select it. Written as
  its own beat — *"Nothing changes on screen. This is the part people expect to
  be broken and it isn't."*
- [x] Cover custom three-color palettes (Base / Accent / Highlight, per
  surface, shaders only).
- [x] Safe demo: cycles 1 and 2 are UI walkthroughs with no prompt at all,
  because there is nothing to prompt — see the finding below.

**Two corrections this tutorial forced, both from reading the implementation
rather than the older prose:**

1. **The catalog is a click, not a drag.** Each catalog row carries one button
   per surface (`AppearanceLive.option_chip/1` → `assign_button`).
   `Appearance`'s own moduledoc said "the user drags an option onto the
   Homepage or Terminal target" — and so did this roadmap. Fixed in
   `appearance.ex` in the same commit. Classic drift seam: the doc described an
   interaction that was redesigned, and no test reads prose.
2. **There is no palette-coloured fallback when WebGPU is missing.** This
   roadmap asked for "the solid fallback"; there is no fallback *renderer*.
   `.ic-home-bg` has no background of its own, so the shader layer simply does
   not paint and the ordinary page shows through — which is what the Appearance
   page already says ("the surface just stays solid"). The tutorial says that
   instead of implying a fallback path exists.

**And the finding worth keeping:** Appearance is the one taught surface with
**no commands at all** — no `shader_*`, no `appearance_*`, nothing. That is not
a gap, it is the safety model for arbitrary GPU code: a shader file may arrive
from anywhere (you, or an agent with workspace file access), and only a human
click ever puts it on screen. The tutorial makes that its thesis, and a test
asserts the catalog really contains no such command, so adding one later
fails the build rather than silently falsifying the page.

## Turn worked examples into real demos — **DONE 08-08**

- [x] The four fields are **required attrs** on `<.example>` — `needs`,
  `touches`, `confirm`, `result` — rendered as a four-row `<dl>` between the
  cycle header and its body, because the rule was "name the side effects
  *before* the prompt" and the prompt is the first thing in every body.

  Required rather than optional is the whole design. A worked example that does
  not say what it needs, what it touches, where the stop is, and what happens
  when the dependency is missing is exactly the failure mode this roadmap's
  08-04 audit found: prose that reads like a promise. Required attrs make that a
  compile warning rather than an editorial oversight nobody catches. Answering
  "None — this is a read" is a fine answer; omitting the row is not possible.

- [x] **Copy prompt** — always available, via the existing generic
  `data-terminal-command-copy` listener in `lib/globals.js`. No JS was written.
- [x] **Try in Chat** — `explore_try_in_chat` in `StatusLive`, switching to
  Home → Chat and pushing `bc:chat_prefill`. Prefill only, never submits, size
  bounded. A `try_in_chat={false}` opt-out exists and has exactly one consumer:
  the GWS unattended cycle, whose prompt is an **email**, where offering to
  paste it into the composer would teach the wrong trigger. A test asserts
  precisely one GWS prompt omits the button, so the opt-out cannot spread
  quietly.

**Every demo now declares the contract** — 21 examples across six tutorials
(19 retrofitted, plus the new Phone and Shaders cycles).

Ordering note: this section was built **before** the two missing tutorials
rather than after, so the new ones were written once, in the final shape,
instead of being retrofitted the same week.

The recommended first demos all landed, with one instructive exception:

- **Models:** `model_policy` with no arguments — cycle 1. ✅
- **Browser:** sandbox tab + public page — cycle 3. ✅
- **Command List:** local reminder — cycle 1. ✅
- **GWS:** draft without sending — cycle 2. ✅
- **Phone:** unheard voicemail without marking heard — cycle 1. ✅
- **Shaders:** apply a built-in to the Home preview — **cannot be a prompt.**
  There is no command that selects a background, so this one is a UI
  walkthrough with no prompt and no Try-in-Chat button. The demo contract still
  applies to it; only the prompt is absent. Worth noting because "every demo
  gets a runnable prompt" was an assumption, and one surface disproved it.

## Tests that protect meaning, not wording

The current Explore tests prove that named commands exist and lock in selected
phrases. They can still preserve a false explanation. Add contract tests that
read catalog metadata and verify every claim made by a tutorial:

- [x] Command type, trust tier, `gated` flag, and required confirmation argument.
- [x] Models surfaces, floors, and Claude-only pins from `ModelPolicy`.
- [x] Google connection copy covers bundled and Advanced paths.
- [x] Phone copy covers SMS trust separately from voicemail trust + PIN — and
  08-08 made it a metadata contract, not just phrase-matching: the phone test
  asserts the tier of every read (safe for the three operational reads,
  restricted for the two *policy* reads) and the `gated` flag on all five
  consequential writes. `phone_mark_heard` is asserted **un**gated on purpose,
  because what protects the blinking light is that reading never clears it.
- [x] Every demo declares prerequisites, side effects, confirmation, outcome,
  Copy prompt, and (where appropriate) Try in Chat. Enforced twice: required
  attrs at compile time, and a test that walks all six tabs asserting the fact
  rows actually *reach* the page in equal number to the demos.
- [x] **New 08-08:** the Shaders tutorial's central claim is a contract — the
  test fails if any `shader_*` / `appearance_*` / `background_*` command ever
  enters the catalog, because that would falsify "only your click applies one".

## Recommended execution order

1. **DONE 08-04** — Correct the shared harness, command-taxonomy, trust, and
   gating explanations.
2. **DONE 08-08** — Add the reusable demo contract and safe Copy/Try actions.
   *(Swapped ahead of step 3 so the new tutorials were written once, in the
   final shape.)*
3. **DONE 08-08** — Build BusterPhone and Shaders & Backgrounds tutorials.
4. **DONE 08-08** — Retrofit Models, GWS, Command List, and BrowserControl
   examples.
5. Rewrite or relocate BusterClaw.lol and NTF after verifying their live roles.
6. Run a packaged-app editorial pass; archive this roadmap only after every
   tutorial has been exercised against a real dependency or an explicit safe
   failure state.

**Remaining to close this roadmap:** step 5, step 6, the Explore-vs-Manual call
(Phase 2's open question — six real tutorials now make the overlap visible, so
it is decidable), and Phase 4's cross-linking and packaged walk.

# Phase 3 — Roster growth (proposals, not commitments)

Candidate tiles beyond the operator's seven, each needing an operator yes:
**The work queue & on-duty** (the queue is "the whole design" — README),
**Chat & the agent**, **Music & Sound Studio**, **Security feed /
Sentinel**, **The terminal**. Eight thin tutorials are worth less than five
good ones; anything declined goes to `LEFTOVERS.md` with a reason.

# Phase 4 — Closeout

- [ ] Cross-link: Get Started and the Manual mention Explore where it helps;
  the Intro links the Manual for reference depth.
- [ ] Walk the tab in the packaged app (compile-time embeds must actually ship —
  same class of check the music routes needed).
- [ ] Archive this roadmap; open items → `LEFTOVERS.md`.

---

## Order

Phase 0 alone is a shippable commit and lands first. Phase 1 before any
tutorial is written — the template is what keeps eight tutorials from being
eight formats. Phases 2→3 are content, committable one tutorial at a time
(direct to main, per standing practice). The only decision with teeth is
Explore-vs-Manual, deliberately deferred to the end of Phase 2.
