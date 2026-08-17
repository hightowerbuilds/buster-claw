# The release gate — the human walkthrough and the repeatable checklist

**Carved out of the launch roadmap 2026-08-09 · Status: ACTIVE.**

> ### The one-sentence version
>
> **One packaged build, one sitting, every question answered by a person — then a
> checklist that makes doing it again cheap.**

**This is what cannot be automated.** Everything that *can* be asserted in CI
lives in [`APPLE_ROADMAP`](APPLE_ROADMAP.md). What is left here is the part that
needs eyes on a real artifact, plus the two items about how the app presents
itself to someone judging it in ten seconds.

> **Because there is no feature freeze, prefer automation.** An item asserted in
> CI survives every merge between now and release. An item written as a manual
> checklist step is only true for the commit it was run against. Where both are
> possible, make it CI. **Where it must be human, do it last, against the
> artifact actually being shipped.** Testing a build you will not ship is the
> specific waste this choice creates, and the only defence is timing.

**`G-40` is the big one** — consolidated 08-03 from the browser closeout map and
the leftovers maps, where these had been accumulating separately for weeks. They are
one gate because they are one *sitting*.

---

## The gate

*Numbers are stable and cited from commit messages — re-tagged and re-ordered,
never renumbered. `G-36`–`G-41` were carved out of the launch map and keep their
labels.*

### G-36 — The dock must be the product, not the roadmap **[R2]**

A stranger judges maturity by the weakest surface they click.

- [x] **G-36. CLOSED 08-08.** *Move Voice out of main navigation.* Already true and not
      noticed: the dock is **Home / Workspace / Browser / Terminal / Settings**. Voice is a
      Settings tab, not a destination. Re-read on archiving the critical review — the page
      is also not a dead end, it is an accurate 58-line explainer that says where the
      toggle is and that there is no microphone input.
- [x] **G-37. CLOSED 08-08 by a different route than this gate proposed.** *Move Phone out
      of the dock or behind a labs toggle.* Phone **left the dock on 08-08** and is now a
      Home sub-tab. The operator then **declined the labs toggle** — Phone, Studio and
      Voice stay where they are — so the obligation was met by **labelling in place**
      instead (`3fd245c`): the keypad now says on screen that it only searches contacts and
      that outbound calling isn't built, and the inert Text/Call buttons carry an
      `aria-label`, not just a hover `title`. *The rule this sets for the next unfinished
      surface: hiding and labelling are both acceptable; shipping it unmarked is not.*
      **Re-read 08-15, still closed, and the label changed rather than went away.**
      `phone_call` and then the keypad's Call button both shipped that day, so
      "outbound calling isn't built" became false. The line now says whether calling is
      switched on and names the variable that turns it on — a disabled control with its
      reason in a `title` is the same G-37 failure, so the disclosure survives its own
      feature.
- [x] **G-38. CLOSED BY DELETION 08-08.** *Decide what to do about Trading in the dock
      while its safety remediation is open (**R9**).* Decided in the strongest available
      way: the surface is gone. Nothing to label, nothing to gate, no unsafe path for a
      stranger to find.

### G-40 — The human walkthrough: one build, every answer **[R1]**

**Consolidated 08-03** from `BROWSER_CLOSEOUT_ROADMAP.md` (archived) and
the leftovers maps, where these had been accumulating separately for weeks. They are
one gate because they are one *sitting*: a packaged build, a signed-in session,
and a person looking. Splitting them across documents is why none of them
happened.

**Why this is a gate and not backlog.** Part IV's own rule is that an item
belongs here if a person with the app in front of them can judge it pass/fail.
Every line below is that, and each one covers a claim nothing in CI can reach —
`render_hook` never touches JS, and no test in the suite has ever driven a real
logged-in checkout.

- [ ] **The signed-in checkout walk — do this one first.** Drive one real
      Agent-Mode commerce run to a **logged-in** checkout and confirm the run
      halts at the payment gate. The 07-25 field test found this exact gate
      failing **open** on Amazon's `/gp/buy/` funnel; the fix is tested but has
      **never been walked**, because that funnel is only reachable from a
      signed-in session. Nothing in the repo can do this — it needs the
      operator's own account.

      **Two field exercises have now gone by without testing it.** The 08-08
      book errand drove a real signed-in Amazon session under Agent Mode and
      succeeded — 17 steps, book in the cart, `commerce: true` — but stopped at
      the cart by design and never reached checkout, so the gate did not fire
      and this finding must still be assumed **open**. That is the trap worth
      naming: an errand can exercise nearly the whole commerce path, look like a
      clean pass, and leave the one control that stops money untested. **A run
      that stops at the cart is not evidence about the gate.** Reaching
      `/gp/buy/` has to be the explicit goal of the walk, not a side effect of a
      shopping errand.

      **Its stakes rose three times on 08-03**, which is why it leads: the agent
      can now file a purchase receipt (`agent_run_confirm_purchase`), reach
      signed-in sites unattended (`$secret.<name>` resolves against a real
      store), and its egress on those sites is newly bounded but unobserved in
      the wild. This gate is what stands between all of that and a live payment
      page. **Nothing further should be built on the browser commerce surface
      until it passes.**
- [ ] **Per-host egress, observed rather than asserted.** During the same run,
      confirm `amazon.com` actually resolves to `structure_only` and the step
      receipts show free text withheld. Shipped 08-03 with the default in code;
      the field test measured 89.8 KB leaving at `:full` with zero redactions.
- [ ] **A first-open workspace, through the setup wizard.** Packaged app →
      wizard picks the folder → open it in **Finder** → count. The scaffolding
      is guarded by 24 tests and its count was measured by setting
      `BUSTER_CLAW_WORKSPACE_ROOT` and listing — never by the path a new user
      actually takes, and never for how the folder *reads* to a human.
- [ ] **Byte ranges and codecs in the packaged app**, not a browser tab: confirm
      `RangeResponse` satisfies WKWebView's media stack and the probed codecs
      play. The two acceptance criteria `MUSIC_ROADMAP` could never close.
- [ ] **The Clinch's management gate, clicked.** Inherited 08-08 from
      `CLINCH_ROADMAP.md` Phase 2, whose own acceptance criterion this is.
      Settings → the Clinch: store a credential, see it listed by name, delete
      it. Then **Reveal key** and confirm the recovery key appears — it is now
      read from the Keychain by Rust rather than assigned by the server, so this
      is the first time that path runs against a real Keychain entry at all.

      **Why no test reaches it.** The Elixir side is covered (3,093 tests), the
      JS logic is covered (bun), and the three-place ACL registration is covered
      by `acl_lockstep`. What none of them exercises is the actual IPC round
      trip: `window.__TAURI__.core.invoke` → Rust → loopback with a
      Keychain-sourced token. Dev builds also mask ACL omissions, which is
      precisely how the co-presence commands (07-17) and `speak`/`stop_speaking`
      (07-21) shipped dead. **A dev-shell click is not this check.**

      While the packaged app is open, also confirm the **Keychain prompt** for
      the new `secret_key_base` read is intelligible and that "Always Allow"
      sticks — that is **G-13**'s question, now with a second caller asking it.

- [ ] **The Explore tab, read by a person.** Inherited 08-08 on
      `EXPLORE_TAB_ROADMAP`'s archive
      (`daily-growth/archive/08-08-26-explore-tab.md`), where it was two items —
      Phase 0's "eyeball it in the real app" and Phase 4's packaged walk. Open the Explore rail in the
      packaged build and read all nine sub-tabs: the eight-tab rail wraps
      sensibly, the launcher grid's tiles are square and legible, each tutorial's
      inline SVG renders in **both** themes (they use `currentColor` and
      `var(--color-primary)`, which no test verifies visually), and the demo fact
      rows (Needs / Touches / Stop / Result) read as a scannable block rather than
      a wall. Click one **Try in Chat** and confirm it lands in the composer
      *without* sending.

      **The risk this originally named is void, and that is worth knowing before
      you walk it.** Phase 4 asked to confirm "compile-time embeds must actually
      ship — same class of check the music routes needed." There are no embeds:
      Phase 1's markdown pipeline was evaluated and **decided against**, so all
      six tutorials are HEEx function components compiled into the release like
      any other module. Nothing can fail to ship. What remains is purely whether
      it *reads* well on a real build — cheap, and the only claim 3,272 tests
      cannot make.

- [x] **The three chat skins, looked at.** — **SIGNED OFF by the operator
      08-09-26.** Source roadmap archived to
      `daily-growth/archive/08-09-26-chat-skins.md`. Inherited 08-09 from
      `CHAT_SKINS_ROADMAP.md`, whose own acceptance section this is. Settings →
      Appearance → Chat theme: change it three times and watch the preview. Then
      open the homepage **with a conversation already on screen** and confirm the
      **old messages** restyle, not just new ones — that is the whole design, and
      a test can only assert the attribute changed and the nodes survived, not
      that the result looks right. Toggle dark/light against each skin (three
      skins × two themes = **six** combinations, and skin CSS uses only daisyUI
      tokens precisely so all six work). Finally, with a run in flight, confirm
      **Stop**, **Steer now** and the attach affordance are all reachable in all
      three.

      Also check the **text size** control while you are there (Normal → Largest):
      set it to Largest and confirm the chat still *fits* — a long message at
      150%, two lines in the composer, the queue rail open. Type scales and the
      panel does not, which is intended, so the risk is wrapping and overflow
      rather than colour.

      **What CI does cover, so you can skip re-checking it:** every skin *and*
      size renders byte-identical DOM apart from the two attributes; no skin uses
      a hex literal or `display: none`; every `data-chat-*` selector in the
      stylesheet exists in the markup; every font-size a reader reads goes through
      the scale; and the percentages the dropdown promises are the multipliers the
      CSS applies. What it cannot cover is legibility. Note that all three skins
      keep the homepage's translucent blurred panel — an opaque draft was corrected
      on 08-09 — so none of them should look out of place beside the other tabs.

- [ ] **Terminal themes, including one you made.** Inherited 08-09 from
      `TERMINAL_THEME_ROADMAP.md`, whose acceptance section this is. Settings →
      Appearance → Terminal theme: pick each of Industrial, Nord and Monokai with a
      terminal **already open** and confirm it restyles. Then build a custom theme:
      **drag the hue slider** and confirm the open terminal follows the drag live,
      then change an individual swatch and confirm that sticks too.

      *(This step said "Then *Start from Nord*" until 08-09. That entry point was
      replaced the same day, on operator revision, by the hue spectrum — one
      number in, all 21 colours out — and `copy_of/1`/`starting_points/0` were
      deleted. The bullet described a button that no longer exists.)*
      Open a **second window** and confirm both terminals agree. Restart the app
      and confirm the custom theme is still there and still selected.

      Two specific things to look at, because they are the honest edges of the
      design. **Run something with coloured output** (`ls`, `git status`) under a
      custom theme with the ANSI section untouched — it should look themed, because
      a custom theme is a *copy* of a preset and copies all 21 colours; if it looks
      like default xterm colours, the copy is not doing its job. And **toggle the
      app between light and dark**: Industrial should follow, and a custom theme
      should not. That asymmetry is deliberate and the UI says so, but it is worth
      seeing.

      **What CI covers:** the three presets and the six removals in *both*
      languages, a stale selection resolving to the default, every colour validated
      as `#rrggbb`, a partial palette refused rather than merged, and the push event
      that carries an edit to the browser. What it cannot cover is whether xterm
      renders the palette the way the swatch promised.

- [ ] **Pockets, and the app's own art.** Inherited 08-09 on `POCKETS_ROADMAP`'s
      archive (`daily-growth/archive/08-09-26-pockets-roadmap.md`). One sitting,
      four things a person has to judge:

      **The brand loop, which is the one with a designed failure state.** In the
      packaged app: Home → Pockets → Add art on a dock icon, confirm the dock
      changes *without a reload* (it is a sticky nested LiveView — `DockNavLive` —
      precisely because the app layout is never diffed after mount). Then open
      `pockets/nav-home/` in **Finder**, drop a second image in, and confirm the
      dock falls back to the **text label** with a plain error in the tab, no
      modal and nothing blocking. Remove the extra file and confirm the art
      returns on its own — there is no repair action by design. Finally confirm
      the replaced image is sitting in the **top level of the workspace**, not
      deleted.

      **A real mount.** Point a Pocket at a folder outside the workspace and
      confirm its files list and its thumbnails render. This is the only check
      that exercises the asset route against a path the workspace fence would
      otherwise refuse, and `Pockets.resolve/2` is the single fence it goes
      through.

      **The one measurement Phase 0 could not make.** Drag a **folder** onto the
      app and see whether the Tauri drop event carries a path for a directory the
      way it does for a file. If it does, folder-drop is the natural mount
      gesture and the typed path becomes the fallback rather than the primary.
      Nothing depends on the answer; it is cheap to get while the build is open.

      **Why none of this is in CI:** every LiveView test passed against a dock
      that a real browser would have shown stale, because `render/1` re-renders
      the whole tree server-side. That is the specific reason this needs eyes.

> **If the checkout walk fails, stop and fix before the rest.** The others are
> quality; that one is money.

### G-41 — Live chat steering ships OFF, and stays off until it is decided **[R1]**

**Status: built and dev-only. The decision to ship it is not made.**

Chat live steering (`daily-growth/archive/08-06-26-chat-live-steering.md`) lets an
operator redirect an agent mid-turn. All three harnesses do it, all three are
proven end to end against real CLIs, and it is **on in dev only**.

**Why it is a release gate rather than a feature flag nobody thinks about.** It
is a *transport* switch, not a UI toggle. With it on, a chat conversation holds
a long-lived `claude` process, a `codex app-server` connection, or an
`opencode serve` subprocess for as long as the conversation is open. That is a
real change in what a packaged app does on someone's machine — more processes,
more ports, a different failure surface — and it should be a decision rather
than a leftover.

**The guard is a CI assertion, not a checklist line** (`G-39` is where
checklists go; this belongs where it cannot be skipped).
`test/buster_claw/agent/steering_rollout_test.exs` fails if the flag is enabled
in any config outside `dev.exs`, and also fails if dev *stops* enabling it, so
the local default cannot rot silently either.

That test is deliberate about the checklist's weakness: the flag is invisible in
the UI until a run is in flight, so an accidental rollout would not be caught by
clicking around a build.

**To turn it on for a release, all of these first:**

- [ ] the three acceptance smokes pass on this machine (see G-39)
- [ ] the flag has been on in dev long enough to have been *used*, not just tested
- [ ] a decision recorded here about the resource cost: one long-lived agent
      process (or server connection) per open conversation, not per turn
- [ ] `steering_rollout_test.exs` updated deliberately, in the same commit

**Deliberately not shipped with it:** operational metrics
(submit-to-accept latency, demotion count, transport restarts). They were scoped
in the original Phase 7 and are **R2 or later** — they need somewhere to go, and
telemetry is already deferred to Release 2. Nothing about steering requires them
to be useful; they are for tuning it once real people are using it.

---

### G-39 — The repeatable release checklist **[R1 + R2 — runs every release]**

Everything above is one-time. This runs every release, forever.

- [ ] `mix precommit` green · `bun test assets/js` green
- [ ] `mix dialyzer` green · `mix sobelow --config` green
- [ ] `scripts/check_docs_drift.sh` green
- [ ] `mix test --include browser_engine` green on a machine with a browser
- [ ] Deno tests for the edge functions green
- [ ] **If chat live steering is enabled for this release (G-41):** all three
      acceptance smokes pass — `mix run scripts/smoke_chat_steering{,_codex,_opencode}.exs`,
      dev server stopped. These cannot be CI: they drive the operator's own
      logged-in CLIs and cost real tokens. They found four defects a green suite
      could not see, so they are a gate rather than a formality.
- [ ] Two-arch DMGs built, signed, notarized, stapled
- [ ] `smoke_desktop.sh` + `smoke_command_surface.sh` green against **each** packaged artifact
- [ ] III.J exit tests passed on real hardware, **both** arches
- [ ] Update from the previous release tested, not assumed
- [ ] `VERSION` bumped, changelog written, per-arch `latest.json` published
- [ ] **Minisign key backup confirmed to still exist**
- [ ] **`https://busterclaw.lol/updates/latest.json` returns 200** — the rewrite
      lives in the **separate website repo**, and nothing in this repo fails
      without it. The release job warns; it deliberately does not block, because
      the artifacts are fine and the fix is one line elsewhere
      ([`UPDATE`](UPDATE_ROADMAP.md) `D5`)
- [ ] Apple Developer Program License Agreement still accepted (it stalls silently)

> **A gate that can be skipped is not a gate.** `mix precommit | tail && git push` shipped a
> red suite once. Use `set -o pipefail` on any `&&` chain that depends on a piped gate.

---


---

## What this map does not cover

- **Signing, notarization, the updater, the macOS floor** — [`APPLE_ROADMAP`](APPLE_ROADMAP.md).
- **Telemetry, error surface, the trust claims** — [`TRUST_AND_SUPPORT_ROADMAP`](TRUST_AND_SUPPORT_ROADMAP.md).
- **The download page** — [`WEBSITE_ROADMAP`](../website/WEBSITE_ROADMAP.md).
- **Per-surface QA that blocks nothing** — [`QA_BACKLOG`](QA_BACKLOG.md).

---

## What the release is

*The release-wide framing from the launch roadmap, which every gate in every map
inherits.*

> ### Two releases, not one
>
> **Release 1 — target: roughly one week.** A signed, notarized, stapled DMG for **both
> architectures**, handed directly to a handful of people we can email. It proves the entire
> Apple path on real hardware with real stakes and no strangers. **The updater does not
> block this** — a new link is an email.
>
> **Release 2 — public download.** A stranger visits **busterclaw.lol**, downloads a DMG,
> double-clicks it, and the app opens with **no dialog of any kind**. This is where the
> updater, telemetry, the download page, and the privacy policy become mandatory, because
> "please re-download" stops being a message you can send to everyone affected.
>
> Every gate item is tagged **[R1]** or **[R2]**. The split exists because the two
> have genuinely different risk: R1's audience can be told things, and R2's cannot.

> **We are not freezing the tree.** Feature work continues on `main` and the release gate
> runs against whatever is there at release time (operator call, 08-01). That is a real
> trade: every merge after a manual QA pass silently invalidates it.
>
> **So the gate is built to be cheap to re-run.** Prefer an assertion in CI over a paragraph
> in a checklist — an automated gate survives a merge and a manual one does not. Where a
> check can only be human (first launch on a clean machine, the III.J walk), **run it against
> the artifact you are actually shipping, as late as possible.**

> ### The trading stack was deleted 2026-08-08
>
> Trading, Portfolio, MarketData, Watchlist and Chart Build were removed whole
> (`293f47f`), and the extension mechanism built to re-home them followed
> (`a89163e`). **~24,000 lines.** Operator decision: size the app down and finish
> what remains.
>
> **This closes gate items and risks rather than completing them** — the honest
> distinction, and the reason each is marked *closed by deletion* rather than
> ticked. Affected: **G-38**, **R9**, **V.9**, **T-10**, two **G-40** manual
> checks, and the Trading rows in the QA checklist and the surface table.
>
> `finance_*` (SEC/Finnhub, public reads) survives; nothing else from that stack does.

> ~~**R9 — Trading is in the dock while its remediation is open.**~~ **CLOSED BY
> DELETION 08-08.** The financial surface no longer exists, so there is no unsafe
> path in it to find.

---

---

## The order to do it in

### Stage 0 — Done, and what it unblocked

| # | Task | State |
|---|---|---|
| 0a | Enroll in the Apple Developer Program | **DONE 08-01.** This was the gate on all of Part III |
| 0e | ~~**Identify the Intel Mac** you will run III.J on~~ → **Identify an APPLE SILICON Mac** | **Recorded backwards until 08-10.** The dev machine *is* the Intel Mac (i9-9980HK) and every DMG in the tree is `x64`; nothing was owed. What is owed is arm64 — **the majority slice**, never built outside CI, never signed, never launched. Still a scheduling dependency, not an engineering one, and now the last hard blocker on Release 1 |

### Stage 1 — Release 1: get it signed (this week)

*The critical path. Everything else in every map waits behind 1a.*

| # | Task | Cost |
|---|---|---|
| ~~1a~~ | ~~G-2: the Developer ID certificate~~ | **DONE 08-10** |
| 1b | G-2b: App Store Connect API key for notarization (`.p8` downloads once) | Minutes |
| 1c | **G-3: first real signed build.** Expect rejection rounds | Hours to days — the largest unknown here |
| 1d | **G-4: III.J exit tests, both arches, on real hardware** | A day, plus Intel-Mac scheduling |
| 1e | **G-9–G-15: first launch on a clean machine.** TCC prompt, no-`claude`, no-Homebrew, offline | A day. **Run this LAST, against the artifact you ship** |
| 1f | G-34/G-35: the two `LEFTOVERS` HIGH items — payment gate walk, `nosniff` | Hours. Safety, not presentation |
| 1g | **G-7: the clean-clone build.** Local end-to-end passed; a cold clone has not | Hours plus surprises |

### Stage 2 — Free work, any time (does not block Release 1)

| # | Task | Cost |
|---|---|---|
| 2a | **VI-a: pick one front door**; make README, site, wizard, and home agree | Hours. Highest leverage in the document |
| 2b | **Run the one-sentence test** (IX.1) before and after 2a | An afternoon |
| 2c | VI-b/VI-c: delete retired features from the user guide, fix the wizard docs | Hours |
| 2d | G-17/G-17b: the WebGPU feature floor, and stating the floor in the README | A morning |
| 2e | G-36/G-37: move Voice and Phone out of main navigation | Small diffs |

### Stage 3 — Release 2: the public download (the week after)

| # | Task | Cost |
|---|---|---|
| 3a | **G-18–G-20: the updater** ([`UPDATE`](UPDATE_ROADMAP.md), moved out of Apple 08-16). Minisign keypair, **offline key backup**, per-arch `latest.json`, the BEAM-safe swap | **Days. The subtle part is the respawn race, not the plumbing** |
| 3b | G-21–G-24: download page, `/privacy`, `/terms`, the stated floor and Claude requirement | Hours to a day |
| 3c | G-25–G-28: telemetry, user-facing error surface, uninstall, diagnostic bundle | Days |
| 3d | G-29–G-33: the trust claims — approval gate, kill switch, disclosure, Security tab | Days |
| 3e | 0b/0c/0d: decide on restricted Gmail scopes; start Google verification if yes | Free to decide; weeks to months if yes |

### Stage 4 — Ship, then watch

IX.3 sessions on the real signed DMG · publish · one question by email each week to whoever
shows up: *"What did you use it for this week?"* The answers are the roadmap.

### Explicitly off the critical path

- **SMS / A2P 10DLC** — code-complete, frozen on the Sole-Proprietor registration reset. Does
  not gate anything here.
- ~~**Trading Stages 1–7**~~ — **moot 08-08.** The surface was deleted rather than
  remediated, which closed G-38, R9 and V.9 together.
- **The iPhone companion and the newspaper reader** — separate products (retained in git history).
- **Everything in [`QA_BACKLOG`](QA_BACKLOG.md).**

**The bill lives with [`DISTRIBUTION`](../distribution/DISTRIBUTION_ROADMAP.md)** —
it is a money question, and duplicating it is how two documents start disagreeing.

---

## How `G-40` was assembled

### Promoted 08-03 → the release gate, as **G-40**

Every item that needed *a person looking at a packaged build* left this file
together and became one release gate: the **Chart Build look**, the
**first-open workspace through the setup wizard**, and the **packaged byte-range
and codec walk** — joined there by the **signed-in checkout walk** inherited
from `BROWSER_CLOSEOUT_ROADMAP.md` on its archive.

They went because they are one sitting, not four errands, and because splitting
them across two documents is why none of them had happened. The detail travelled
with them; nothing was lost. This file's rule still holds — they needed no
design, only a build and an afternoon — but they blocked a release, and this
file is explicitly for things that block nothing.
