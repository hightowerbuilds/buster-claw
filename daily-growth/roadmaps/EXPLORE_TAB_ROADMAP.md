# Explore — a home tab that teaches the machine

**Scoped 08-02-26 · Status: ACTIVE · Phase 0 in progress.**

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

- [x] **Trading** — BUILT 08-02, added to the roster (operator, same day). Deliberately the
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
  `Trading`/`TradingOrder` moduledocs + trading-tab memory.

Remaining after that: **BusterPhone** → **Shaders & Backgrounds**.

- [ ] Make the Explore vs Manual call (see open question above) once two or
  three real tutorials make the overlap visible.

# Phase 3 — Roster growth (proposals, not commitments)

Candidate tiles beyond the operator's seven, each needing an operator yes:
**The work queue & on-duty** (the queue is "the whole design" — README),
**Chat & the agent**, **Trading**, **Music & Sound Studio**, **Security feed /
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
