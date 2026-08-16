# DMG review — 08-15-26 · **CLOSED 08-15**

> **Archived the same day it was opened.** All three findings are fixed and the
> three requested builds shipped. One thing is deliberately NOT closed here and
> was moved rather than ticked: findings 1 and 2 are proven **in dev only**, and
> the packaged re-check now lives in
> [`QA_BACKLOG`](../roadmaps/platform/QA_BACKLOG.md) — "Harness detection — the one check that can
> only pass in a packaged build". Two tails from the same fix are in
> [`LEFTOVERS_PLATFORM`](../roadmaps/platform/LEFTOVERS_PLATFORM.md).
>
> **The sharpest thing this review produced is not in its table.** Finding 3's
> sweep, and the security regression that B1 introduced and B2 exposed, both
> came from following a small report further than it asked. See the closing
> section.

Findings from opening the first signed DMG of the day
(`Buster Claw_0.1.0_x64.dmg`, 27 MB, Developer ID + hardened runtime, **not
notarized**). Built from `7ec717a`.

**This file is a running list.** Findings are numbered in the order they were
found, not by severity; the table says which is which. A finding is closed by a
commit that names it, and the line is struck through rather than deleted — what
was wrong in a shipped build is worth being able to read later.

**The point of this pass is that none of it is visible in dev.** Every finding
below is either caused by the packaged app's environment or was in front of us
all along in a surface nobody clicked.

| # | Finding | Severity | State |
|---|---|---|---|
| 1 | No agent CLI is detected, so no app-wide model can be set | **HIGH** — the app looks broken on first launch | **FIXED** in dev (`6661021`, `0d4a920`) — *needs a packaged re-check* |
| 2 | Configuration says claude / codex / opencode are "not installed" when all three are | **HIGH** — same root cause as 1 | **FIXED** in dev, same commits |
| 3 | Voice tab: pressing Enter leaves the tab and returns to Chat | **MEDIUM** — breaks the surface being tested | **FIXED**, and two more like it |

---

## 1 + 2 — The packaged app cannot see your agent CLIs

**These are one bug with two faces**, so they are written once. Finding 1 is the
symptom the operator noticed first; finding 2 is the same cause admitting itself
on another screen.

### What was measured

All three CLIs are installed and on the PATH of a *shell*:

```
claude    -> /Users/lukehightower/.local/bin/claude
codex     -> /Users/lukehightower/.bun/bin/codex
opencode  -> /usr/local/bin/opencode
```

`launchctl getenv PATH` is **unset**, which means a GUI app launched from Finder
gets the system default — roughly `/usr/bin:/bin:/usr/sbin:/sbin`. **Not one of
those three directories is in it.** `~/.local/bin` and `~/.bun/bin` are per-user
install dirs added by a shell profile, and even `/usr/local/bin` is absent from a
Finder-launched process's environment.

### Why the app believes them absent

`AgentBackend.available?/1` is `System.find_executable(name) != nil`, and
`System.find_executable/1` searches **the running process's** `PATH`. In a
double-clicked `.app` that is launchd's, not yours. `SettingsLive` renders the
model picker from `AgentBackend.installed/0`, which is `Enum.filter(order(),
&available?/1)` — so in the packaged app that list is empty, every harness is
disabled, and no app-wide model can be chosen.

This is the same class the repo already knows about and states elsewhere: *a
double-clicked `.app` inherits launchd's environment, not your shell's.* It is
written down as the reason credentials must be entered in the app rather than as
environment variables. Nothing carried that lesson to executable lookup.

### Two things that make this sharper than it looks

**The app can probably RUN what it says is missing.** Execution and detection
disagree by design. `AgentRunner` spawns through a **login shell** — `-lc`, which
sources the user's profile — precisely so a packaged or daemon run reaches the
user's PATH and the agent's persisted auth. Detection does not: it asks the
process. So the likely truth is that a run would succeed while the UI insists
there is nothing to run it with. **Worth confirming before designing the fix**,
because it decides whether this is a display bug or a real capability gap.

**There are already two different answers to "is claude installed."**
`AgentRunner.claude_path/0` falls back to `~/.local/bin/claude` explicitly when
`find_executable` misses — and on this machine that file exists, so
`AgentRunner.detect/0` would find claude. `AgentBackend.available?/1` has no such
fallback. Two checks, two answers, and the Configuration page happens to use the
stricter one. That inconsistency is worth fixing regardless of how the PATH
question is settled: whatever "installed" means, it should mean one thing.

### What is missing from the UI either way

Even if detection is fixed, the first-launch story is a picker that is disabled
with **no sentence explaining why**. `settings_live.ex:59` records the deliberate
choice to show an uninstalled harness *disabled rather than hidden*, so that a
missing one is visible — but the reason it is disabled is not. A user who has
claude installed and sees it greyed out has no way to learn that the app looked
on a different PATH.

### Candidate fixes, not yet chosen

- **Resolve through a login shell once at boot** and cache it, so detection uses
  the same environment execution already does. Costs one shell spawn at startup.
- **Widen the canonical fallback list** beyond `~/.local/bin/claude` to the
  handful of real install dirs (`~/.bun/bin`, `/usr/local/bin`, `/opt/homebrew/bin`,
  npm/volta globals). Cheap, but a guess-list that will rot.
- **Let the operator name the path**, which `:agent_binary` already supports as a
  test seam — the honest escape hatch when detection is wrong.
- **Say why the picker is disabled**, whatever else is done. This one is owed
  even if detection becomes perfect.

---

## 3 — Voice tab: Enter leaves the tab

Typing a phrase into **Studio → Voice → "Can it say this?"** and pressing Enter
closes the tab and returns to the Chat home tab, losing the phrase.

**Cause.** Both forms on that surface carry `phx-change` and **no `phx-submit`**.
A single-input form with no submit handler is submitted *natively* by the browser
on Enter, which navigates the page; LiveView remounts, and `:home_tab` returns to
its mount default of `"chat"`. Nothing crashed — the page was replaced.

Mine, shipped in `7d10b3a` earlier today, and worth recording rather than quietly
patching: **the surface was verified by clicking and typing, never by pressing
Enter.** Every LiveView test drives `render_change/2` directly, which cannot
produce a native submit — so the suite could not have caught it and did not.

**Fixed.** Both Voice forms carry `phx-submit` now.

### The sweep, which is the part worth keeping

Since LiveView tests cannot see a native submit at all, the whole app was
measured rather than trusted. **57 form tags in the web layer. 14 carry
`phx-change` with no `phx-submit`. Of those, 3 had a text input** — and only a
text-like field triggers HTML's implicit submission, so the other 11 (appearance
pickers, settings toggles, the studio sidebar) are selects and checkboxes and
were never exposed. Failing those would have been noise, and noise is how a
guard gets deleted.

The three:

| Where | Verdict |
|---|---|
| `studio/voice.ex` ×2 | the reported bug — **fixed** |
| `appearance_live.ex:642` (custom theme editor) | same defect, unreported. Enter in the theme **Name** field would reload `/appearance` and take the half-built palette with it — **fixed** |
| `notes/switcher.ex:37` (⌘P) | looked like a third and **was already safe**: `NotesKeys` claims Enter and calls `preventDefault()` |

**The switcher is the interesting one, and it got the fix anyway.** Its hook
protects it *while the hook is attached*, and this app has a documented window
where that is not true — a click landing before LiveView connects is silently
discarded, filed separately on 08-14 from the same kind of walk. That window
leaves Enter to the browser. So `phx-submit` went on as the floor under the
hook, not as a replacement for it.

**Guard: `test/buster_claw_web/form_submit_test.exs`.** Asserts no form carries
`phx-change` plus a text input without `phx-submit`. It reads source rather than
rendering, because `render_change/2` and `render_submit/2` push events straight
at the process and neither involves a browser — the same argument
`hooks_registered_test.exs` makes about `phx-hook`. Verified by removing one of
the fixes: it fails naming the file and line.

The rule it enforces is the stricter one on purpose: **the server owns Enter, not
the JS.** A hook may still claim it for better behaviour; it may not be the only
thing between a keystroke and a lost page.

---

---

## Requested builds — not DMG defects

Asked for on 08-15 while this review was open. **Kept separate from the findings
above on purpose**: those are things the shipped build got wrong, these are
things it was never asked to do. Mixing them makes a review that cannot be
closed. Each names where it will actually live once it is scoped.

### B1 — Set either background from the terminal

The agent can already recolour the terminal it is running in
(`terminal_theme_*`, `TERMINAL_PAINT_ROADMAP`), but it cannot change the
**background** of the terminal or the homepage. Those are `Appearance`'s two
surfaces, and today the only way to change them is Settings → Appearance.

**Why it is more than a convenience.** `TERMINAL_PAINT`'s whole argument is that
the agent should be able to dress the surface it is speaking from. A palette
without a background is half of that, and the split is invisible to the operator
— "change the terminal's look" is one idea to them and two mechanisms to us.

**What it has to respect**, because `Appearance` is stricter than it looks: the
mode grammar is `off` / a shader name / `image:<slot>` / `image:<slot>+<shader>`,
the image pool is fenced and slot-based, and `set_background/2` already refuses
a shader that would not react to an image. A command must go through that
function rather than write `Settings` keys, or it becomes a second definition of
what a valid background is. There is also a live example of why: the tile-badge
bug fixed in `089494e` came from exactly that kind of second opinion.

**Open question for scoping:** whether this is one verb taking a surface plus a
mode, or a small family. One verb is likelier right — the surface table already
makes everything else surface-agnostic.

**Home:** `shell/TERMINAL_PAINT_ROADMAP.md`, as a sibling to the palette work.

### B2 — A Pockets tab in Explained

The Explained rail has eight tutorials and **none for Pockets**, which is now a
shipped, operator-facing concept: the roles table, the read fence, mounts,
brand slots, and the contact shaderfaces all sit behind a word a new user has no
definition for.

**Why this one earns a tile where the five parked candidates did not.** The
archived Explore work left five proposed tiles unaccepted with a standing rule —
*eight thin tutorials are worth less than five good ones* — so a new tab needs an
argument. Pockets has one the others lack: it is **already load-bearing in other
surfaces**. Backgrounds live in a Pocket, brand art lives in a Pocket, contact
faces live in a Pocket. A user meeting the word in three places with no page to
send them to is the case a tutorial exists for.

**What it has to carry**, from the modules rather than from prose: a Pocket is
a directory with a manifest, roles *describe* a Pocket and never *decide* one
(the fixed-name rule in `Appearance`), the read fence and why it re-asks on every
call, and the demo contract every Explained tile owes — prerequisites, side
effects, where the stop is, expected result and failure state.

**Cheapest correct route:** `Explained.Registry` is data-only and adding a tab is
one edit there plus a module, exactly as `Studio.Registry` was for Voice. The
rail, the guard and the dispatch all read the registry, so the tab cannot exist
in one and not the others.

**Home:** `surfaces/LEFTOVERS_SURFACES.md` until scoped, since the Explore
roadmap is archived and this is its first real successor.

### B3 — Sub-tabs inside Configuration

Settings → Configuration is one long page holding four unrelated features:
Google Workspace (accounts, Gmail labels, Gmail search, Gmail sync, Calendar
sync), the model policy, the profile form, and Clinch. It wants a sub-tab rail.

**This is not a new idea — it is the operator asking for what the frozen Phase 4
was scoped to enable**, and that changes the estimate. `settings_live.ex` is
FROZEN at 936 with a **378-line `render/1`**, and the 08-13 review re-verified
the split against current code: 12 of its 20 `handle_event` clauses are GWS, and
the models section is a clean ~300-line unit that maps 1:1 onto
`BusterClaw.ModelPolicy`. So the rail and the decomposition are the same job, and
doing the rail without the split just adds a fifth thing to a file that cannot
grow.

**One question is already answered.** Home panels render behind `:if`, which
discards component state on tab switch — the constraint that forced Studio's and
Explained's sub-tab state up into `StatusLive`. **Configuration is a route, not
an `:if`-gated panel** (`settings_tabs.ex`), so real `live_component`s are
available here and the state-lifetime argument does not apply. The one mechanic
it does need: `handle_info` for `:google_account_changed` and `clinch:changed`
lands on the LiveView, so a GWS component must be reached with `send_update` —
the pattern `status/studio.ex` already uses.

**Copy the registry shape, for the third time.** `Explained.Registry` and
`Studio.Registry` are both data-only modules that the rail, the event whitelist
and the dispatch all read, so a tab cannot exist in one and not the others. That
property has already caught real bugs twice — a rail button the guard refused,
and a console tab that silently fell back. A third rail should not be
hand-rolled.

**Sequencing, and it matters here.** Models first: it is the cleanest cut, has no
`handle_info`, and — relevant to findings 1 and 2 above — **it is the section
currently showing a disabled picker with no explanation.** Whatever fixes the
"why is this greyed out?" gap lands in that component, so building it first means
writing that sentence once rather than twice.

**Home:** the frozen Phase 4 entry, now in `surfaces/LEFTOVERS_SURFACES.md`.

---

## Still to walk

Not yet checked in the packaged app, and each is a known unknown rather than a
finding:

- **Does Studio → Voice read the real corpus?** It lives under the configured
  DataZone, not the workspace. Zero sources and a failed read render almost
  identically — the tab says "no indexed sources yet" for both.
- **The microphone.** The signed build is the only place TCC and the hardened
  runtime behave like a release. The `/dev/mic-probe` route does not exist in
  this bundle (dev-only by construction), so answering V.4a here needs a
  deliberate path.
- **The Ramshackle QA pass** filed in `QA_BACKLOG` (`7ec717a`) — the user-facing
  walk and the internal-process walk.
- **First launch on a machine that did not build the app** — still the largest
  untested surface in the product, and no finding here touches it.


---

## What actually closed it

| # | Fix |
|---|---|
| 1 + 2 | `BusterClaw.ShellPath` (`6661021`) resolves the **login-shell** PATH so detection uses the environment execution already used, plus the disabled-picker paragraph in the new Models component (`0d4a920`) |
| 3 | `phx-submit` on every form with a text input (`6994407`), guarded repo-wide |
| B1 | `background_list` / `background_set` (`09343be`), narrowed by `d2f6ffa` |
| B2 | The Pockets tutorial (`d2f6ffa`) |
| B3 | Configuration rail; `settings_live.ex` 936 → 643 (`0d4a920`) |

### Three things worth carrying past this file

**A one-line report was a three-form bug.** Finding 3 was "Enter closes the Voice
tab". Sweeping all 57 forms found 14 with `phx-change` and no `phx-submit`, of
which 3 had a text input — including the Appearance custom-theme editor, where
Enter would have taken a half-built palette with it. **LiveView tests cannot see
a native submit at all**, because `render_change/2` never involves a browser, so
the guard reads source.

**`-lc` was not the fix, and the first measurement said it was.** A zsh *login*
shell does not source `.zshrc`. Measuring from an already-interactive shell
showed all three CLIs resolving; replaying launchd's environment with `env -i`
showed codex missing and claude resolving to a *different* binary than a terminal
runs. **A measurement taken in the wrong environment is a guess wearing a
number.**

**B1 broke D1, and a tutorial caught it.** `background_set` shipped arguing "no
command authors a shader" — true, and insufficient, because **authoring needs no
command**: the workspace is writable. An agent could write `shaders/x.wgsl` and
apply it by name, putting GPU code it wrote on the operator's screen with no
human click. It surfaced because building the Pockets tab turned the Shaders
tutorial's central claim false. Documentation held as a contract found a security
hole that four reviewers' worth of prose reasoning had missed.
