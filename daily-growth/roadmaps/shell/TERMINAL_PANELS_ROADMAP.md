# Terminal panels — up to four shells in the work area

**Scoped 2026-10-15 · BUILT the same evening, Phases 0–4.** Sits on top of the
persistent panels that shipped hours earlier (`4716c83`). Nothing here touches
the PTY plumbing in Rust; everything is the layout above it.

> ### What shipped (10-15, uncommitted at the time of writing)
>
> - Phases 0–4 as written, with Q1–Q3 answered by their defaults. `mix precommit`
>   green; both guards broken on purpose and seen to fail (five slots → 2 failures;
>   a close that leaves the shell mounted → 1 failure).
> - **One addition the operator made while reading the map:** ⌘1 ⌘2 ⌘3 are now
>   fixed jumps to the Work Area, Settings (its remembered sub-page) and the
>   Browser — *the only three* — in the DOM strip, the native Tabs menu (renamed
>   items; ⌘4–9 removed) and the Browser chrome. `shortcutDestination` in
>   `lib/tabs.js` is the one source.
> - The ⌘T double-fire question (I.4) was **not measured**: `requestNewTerminal`
>   drops a second request inside 300 ms, so one press is one terminal whether
>   the native accelerator also fires or not. Phase 0's counter is still worth
>   running once in the packaged app; the answer decides nothing now.
> - Walked in Chrome against the dev server (no PTY there): four from the
>   sidebar, the `4 / 4` badge and the refusal pulse, × frees the slot, the
>   reopened slot is the lowest free one, ⌘T on the work area, ⌘T from Settings
>   (lands on `/?panel=terminal` with the one-shot flag consumed), ⌘2 and ⌘1.
> - **D8 shipped with it** (same evening): the Paired columns preset, the
>   three-panel cap on Side by side and Stacked, and the picker's reasons.
> - **D9 shipped with it** (same evening): drag a panel by its header onto
>   another's spot; the rest slide over. Walked in Chrome with synthetic pointer
>   events: Chat dragged from first to last, four terminals slid, order saved.
> - **Still open — Phase 5, the walk in the desktop app:** the busy prompt on ×,
>   that a closed slot's shell is really gone (step 5), the native menu items,
>   and the upgrade path (step 11). Also noticed: an embedded terminal sets
>   `page_title`, so the window title reads "Terminal 4 · Buster Claw" after the
>   last slot mounts — pre-existing with one terminal, more visible with four.

> ### The one-sentence version
>
> **The Terminal becomes a panel you can open up to four times — from the
> sidebar button or ⌘T inside a terminal — and the toolbar loses the two
> buttons that only made sense when a terminal was a tab.**

## The ask, as given (10-15, operator)

> *"We need to write a map for re-building our terminal layout. We want users
> to be able to open multiple terminals. We want to get rid of the + and session
> key copy buttons. We want users to be able to click the terminal button in the
> sidebar to create another terminal, or press command-T while in a terminal and
> that opens a new terminal panel as well. Let's have a limit of 4 terminals."*

Four requirements, one constraint. Taken literally throughout, with two places
where the literal reading needed a decision ([D3](#d3--the-sidebar-button-always-creates-the-deep-link-only-ensures), [D5](#d5--t-means-new-terminal-panel-everywhere-in-the-app-except-the-browser)).

---

## Contents

- [Part I — What the code already tells us](#part-i--what-the-code-already-tells-us)
- [Part II — Decisions](#part-ii--decisions)
- [Part III — The model](#part-iii--the-model)
- [Part IV — The phases](#part-iv--the-phases)
- [Part V — Tests and the acceptance walk](#part-v--tests-and-the-acceptance-walk)
- [Part VI — Not in scope](#part-vi--not-in-scope)
- [Part VII — Risks](#part-vii--risks)
- [Part VIII — Open questions for the operator](#part-viii--open-questions-for-the-operator)

---

## Part I — What the code already tells us

Seven findings. Two of them (I.1, I.4) mean the obvious implementation is the
wrong one; one (I.6) is a size-gate wall that decides where the code goes.

### I.1 — There are three terminal hosts today, and the ask is about one of them

| Host | Route / id | Session key | How many |
|---|---|---|---|
| Standalone tab | `/terminal?session=…&label=…` | from the URL (`term-<stamp>-<token>`) | unbounded, one per tab |
| Joined tab | `/split?left=…&right=…` | per pane, from the pane URL | two per tab, hard-stopped by the greyed "+" |
| Work-area panel | `#workbench-pane-terminal`, `live_render` id `workbench-terminal` | **fixed: `"workbench"`** | **exactly one** |

The panel is the one the operator is describing: it is what the sidebar button
opens, and since `4716c83` it is the only terminal a user reaches without a
keyboard shortcut or the CLI. **Only the third row changes.** The first two keep
their routes (see [Part VI](#part-vi--not-in-scope)).

`StatusLive` renders it as a single static slot
(`lib/buster_claw_web/live/status_live.ex:691–700`), and `WorkbenchState`
knows it as one key in a fixed list of eight (`@panels`,
`workbench_state.ex:4–13`). Every validator in that module — `open/2`,
`restore/1`, the depth bound in `validate/2` — is closed over that list. **A
second terminal is not a second `live_render`; it is a new kind of key.**

### I.2 — The "+" is the split button, and the split is a tab-era idea

`data-terminal-action="split"` (`terminal_live.ex:132–150`) calls
`openTerminalSplit` (`assets/js/lib/tabs.js:136`), which rewrites the current
**tab** into a `/split` URL with a freshly minted second terminal. In the work
area the button is permanently disabled, because `@embedded?` is true there —
so today it is a greyed-out control with a tooltip about a limit that does not
apply to the panel it sits in. Removing it is a deletion, not a redesign:
`openTerminalSplit` and `splitPathForTerminal` have no other caller.

### I.3 — The session key is an implementation detail that leaked into the toolbar

The copy button (`terminal_live.ex:151–160`) and the `<code data-terminal-key>`
line under the label (`:120–125`) exist so a human could paste a key into
`terminal open --session <key>`. Inside the work area the key is always
`"workbench"`. The hook still needs `data-session-key` — it is how the PTY
survives a navigation (`localStorage["bc:term:<key>"]` → Tauri session id,
`terminal.js:98–114`) — but no human needs to see or copy it.

### I.4 — ⌘T is already taken, twice, and both takers open a *tab*

- `TabStrip.handleShortcut` (`tab_strip.js:446–462`) captures `keydown` on
  `window` in the capture phase and, on ⌘T, calls `openNewTerminalTab`.
- The native **Tabs → New Tab** menu item carries `CmdOrCtrl+T`
  (`desktop/tauri/src/main.rs:369`). Rust (`browser/mod.rs:838`) evals
  `window.__bcMenuShortcut("new_tab")` into the app webview when no browser
  surface is shown — and `menuShortcut` (`tab_strip.js:78`) also calls
  `openTerminalTab`.

So the chord the operator wants already has a meaning: *a new standalone
terminal tab*. The map does not add a third handler; it changes what the
existing two do ([D5](#d5--t-means-new-terminal-panel-everywhere-in-the-app-except-the-browser)).
**Whether the native accelerator and the DOM handler both fire on one
keypress is not established** — `main.rs:265–275` says the native one fires
regardless of `preventDefault`, which is why ⌘W was removed from the menu
entirely. If that is true for ⌘T too, today's code opens two tabs per press and
nobody noticed because the second is a no-op on a page that is already
navigating. With a panel it would open two panels. Phase 0 settles it with a
counter before anything is built on top.

### I.5 — A hidden panel keeps its PTY, which is right for every panel except this one

`Workbench.shell` renders a pane while it is in `@workbench_mounted` and merely
sets `hidden` when it is not in the tree. That is the whole point of `4716c83`:
"flat, stable pane hosts preserve editors, streamed messages, and PTYs while
their rectangles change." The header's × is literally labelled **"Hide panel"**.

For a terminal counted against a limit of four, *hide* is the wrong verb. A
hidden terminal is a ghost that holds a slot and a shell, and the user who
clicked × to make room gets "four is the limit" on the next click. The ×
on a terminal pane has to **close**: free the slot, end the PTY, and ask first
if something is running — the busy check already exists (`isBusy()` →
`terminal_busy`, `terminal.js:289–298`) and is already wired into tab close.

And closing is not automatic. `TerminalView.destroyed()` closes the PTY only
when there is **no** session key (`terminal.js:308–311`); a keyed terminal
deliberately survives unmount. Closing a slot therefore needs an explicit
`terminal_close` plus clearing `bc:term:<key>`, or the next terminal opened in
that slot reattaches to the shell the user thought they had ended.

### I.6 — Two of the files in the path cannot grow

| File | Cap | Today | Tier |
|---|---|---|---|
| `lib/buster_claw_web/live/status_live.ex` | 810 | 735 | HELD |
| `assets/js/hooks/tab_strip.js` | 536 | 535 | **FROZEN** |

(`scripts/check_file_sizes.sh:335`, `:1029`.) `tab_strip.js` has one line of
headroom and is frozen because it is "three jobs" already. **The ⌘T change
must be net-zero there**, which is easy — the branch that opens a tab becomes a
branch that dispatches one event — and the listener lives elsewhere. The
status-live budget is enough for four slot declarations, not for a feature;
the state and event handling go in `WorkbenchState` / `WorkbenchHook` (61
lines, uncapped), which is where they belong anyway.

### I.7 — What is already free

- **Arrangement.** `State.open/2` lays a new leaf into the current preset.
  A fourth terminal lands as a fourth column, row, or grid cell with no new
  geometry code.
- **Focus.** `term.focus()` on mount; the pane goes `data-active` through the
  existing `workbench_focus`.
- **Persistence.** `bc:workbench:v1` restores the tree; `bc:term:<key>` restores
  each shell. Nothing new to store — only new keys to allow.
- **Rust.** `TerminalState` is a `HashMap` of sessions with no count limit and a
  256 KB scrollback each. Four is nothing.

---

## Part II — Decisions

### D1 — Four terminal slots are four keys, and the limit is the key list

`WorkbenchState` gains `terminal`, `terminal-2`, `terminal-3`, `terminal-4`.
The first keeps its name and its `"workbench"` session key so an existing
layout and an existing shell survive the upgrade untouched. The limit is not a
counter anywhere; it is the length of that list, so `restore/1` refuses a
fifth the same way it refuses a key it has never heard of.

### D2 — The launcher shows one Terminal button; the key list is not the menu

`State.panels/0` (what the sidebar iterates) keeps its eight entries.
`State.keys/0` (what the tree may contain) grows to eleven. `Workbench.label/1`
learns the slot labels: **Terminal**, **Terminal 2**, **Terminal 3**,
**Terminal 4** — the tab strip's numbering convention (`nextTerminalNumber`),
so a user who has seen both reads them the same way.

### D3 — The sidebar button always *creates*; the deep link only *ensures*

A click on the sidebar's Terminal sends a new event, `workbench_terminal_new`:
open the lowest free slot, focus it; at four, focus the active terminal and
say so in the button (`4 / 4`, title "Four terminals is the limit — close one").
`/?panel=terminal` (bookmarks, the Chat's "open a terminal" links,
`WorkbenchHook.mount`) keeps meaning *make sure one is open* — otherwise every
reload of that URL would mint a shell. The wire for the deep link does not
change; only the sidebar stops using it.

### D4 — × on a terminal pane closes the shell; on every other pane it still hides

Per [I.5](#i5--a-hidden-panel-keeps-its-pty-which-is-right-for-every-panel-except-this-one).
The button is labelled "Close terminal" on terminal slots. The order is: busy
check → confirm if busy (same dialog text as tab close) → `terminal_close` →
clear `bc:term:<key>` → `workbench_close`. The server side removes the slot from
both the tree and `@workbench_mounted`, so the `live_render` unmounts and the
slot is free for the next click.

### D5 — ⌘T means "new terminal panel" everywhere in the app except the Browser

The ask says *"while in a terminal."* Inside a terminal pane it must work, and
that is the only place the chord is at risk of being eaten by xterm (the capture
phase handles that today). Everywhere else on the work area, the same meaning
costs nothing and avoids teaching one chord two things. On another app tab
(Settings, Duty, Phone) ⌘T navigates to `/` and opens a slot on arrival — the
standalone terminal tab stops being what ⌘T makes. In the **Browser** tab the
chord belongs to the chrome (`__menuShortcut`) and is untouched.

The native menu item keeps its "New Tab" label and accelerator; the Rust side
already routes it by context and does not need to know the meaning changed.
Renaming it is [Q2](#q2--should-tabs--new-tab-be-renamed).

### D6 — The toolbar keeps `cmd-list` and nothing else on the right

Split and copy-key go, in every host — a greyed-out "+" is not a feature in the
work area, and a standalone tab that wants a second terminal can still be
joined from the tab strip (drag, or right-click → Join). The `<code>` session
key line goes with the button; `data-session-key` stays on the host element.

### D8 — Four panels are two columns of two, never four in a row (added 10-15, after the build)

> *"When we have 4 tabs open we need to have a 4th option. We don't want 4
> stacked all the way up — nobody wants that. We want 2 columns and then 2
> stacked. For 5 we want 3 columns and 2 stacked."* — operator, same evening

The three presets were written for two and three panels and nobody had opened
four. A fourth arrangement, **Paired columns** (`pairs`): columns of two, left
to right, an odd panel alone in the last column. Four → 2×2; five → three
columns with two of them stacked. **Side by side and Stacked hold up to three
panels**: opening a fourth under either moves the work area to pairs on its
own, the picker refuses a row or a column of four, and closing back to three
returns to side by side. Balanced split stays as the alternative at four and
up (it differs from pairs only in which column stands alone, until seven).
`WorkbenchState.effective_preset/2` is the one place that rule lives.

### D9 — Pick a panel up by its header and drop it on another's spot (added 10-15, after D8)

> *"Once they've got three panels open and arranged how they want it, they can
> pick one up and put it into a different spot. The other panels sort of slide
> over automatically."* — operator

The arrangement's **shape** depends only on the count and the preset, so moving
a panel is relabelling the tree's leaves in a new order. That is why the drag
previews locally with no round trips (`reorderKeys` + `relabelTree` in
`lib/workbench.js`) and only the drop sends `workbench_reorder` with the final
order; `WorkbenchState.reorder/2` relays a preset from that order and, for a
hand-built tree with no preset, keeps every partition and swaps who sits where.
Semantics are *slide*, not swap: the panels between the two spots shift one
slot toward the vacated one, so the dragged panel lands exactly where the
target was. Headers are the handle (buttons excluded); Escape cancels; not
while zoomed, not on a narrow canvas where the panes are a column. Keyboard
reordering is not built.

### D7 — The limit is a work-area limit

Standalone `/terminal` tabs and role terminals (`terminal open mailman`) do not
count. They are a different host with a different lifecycle, and the operator's
four is about what fits on one screen. Rust stays uncapped.

---

## Part III — The model

```
WorkbenchState
  @panels      8 entries, unchanged — the sidebar launcher
  @terminal_slots ["terminal", "terminal-2", "terminal-3", "terminal-4"]
  @keys        @panels keys ++ the three extra slots   (11)

  open_terminal(state)
    -> {:ok, state}      lowest slot not in leaves(tree), laid into the preset, active
    -> {:error, :limit}  all four open; state unchanged
  terminal_count(state)  number of slots in leaves(tree)   (sidebar badge)
  session_key("terminal")   -> "workbench"        (preserved)
  session_key("terminal-N") -> "workbench-N"

StatusLive
  <:panel :for={slot <- State.terminal_slots()} key={slot}>
    live_render TerminalLive, id: "workbench-#{slot}",
      session: embedded + workbench + session_key(slot) + label(slot)

WorkbenchHook (handle_event)
  "workbench_terminal_new"            -> open_terminal, push "workbench:sync"
                                         or push "workbench:limit" (sidebar flashes)
  "workbench_close" on a terminal key -> close as today; the JS already ended the PTY

JS
  WorkbenchMenu click on Terminal     -> dispatch bc:workbench-terminal-new
  Workbench hook                      -> listens, pushEvent("workbench_terminal_new")
                                         listens bc:terminal-new (from ⌘T), same
  TabStrip.handleShortcut / menuShortcut("new_tab")
                                      -> on the work area: dispatch bc:terminal-new
                                         elsewhere (not Browser): navigate "/?terminal=new"
  Workbench pane × on a terminal      -> isBusy → confirm → terminal_close →
                                         localStorage.removeItem → pushEvent("workbench_close")
```

The one-shot `?terminal=new` is read in `WorkbenchHook.mount` and then dropped
from the URL with `push_patch`, so a reload does not mint another.

---

## Part IV — The phases

Costs are a solo afternoon each unless noted. Each phase leaves `mix precommit`
green and is committed on its own.

### Phase 0 — Settle ⌘T, then delete

- Instrument `handleShortcut` and `menuShortcut` with a counter in the dev app
  and press ⌘T once on the work area. **One or two?** Write the answer into
  I.4 above. If two, the DOM handler becomes the only one and the menu item's
  accelerator goes (keep the item, like ⌘W's fate in `main.rs`).
- Delete the split and copy-key buttons, `copySessionKey`, the `split` and
  `copy-key` branches of `handleToolbarClick`, `openTerminalSplit`,
  `splitPathForTerminal`, and the `<code data-terminal-key>` line. Drop the
  `tabs.test.js` cases that covered the split helper.
- Test: `TerminalLive` renders no `[data-terminal-action]` but `cmd-list`
  still opens. `grep` for the deleted names returns only the roadmap.

### Phase 1 — Slots in the state (pure Elixir)

- `WorkbenchState`: the slot list, `open_terminal/1`, `terminal_count/1`,
  `session_key/1`, slot labels; `@keys` derived, not retyped.
- `WorkbenchStateTest`: lowest free slot is reused after a close (open 1–3,
  close 2, open → `terminal-2`); fifth open returns `{:error, :limit}` and the
  state is identical; `restore/1` accepts a saved tree holding `terminal-3`
  without `terminal-2`; rejects `terminal-5`; every preset round-trips with
  four terminals plus the other seven panels (eleven leaves, the depth bound
  still holds).

### Phase 2 — Render four, create from the sidebar

- `StatusLive`: the `:for` slot. `WorkbenchHook`: `workbench_terminal_new`,
  the `?terminal=new` one-shot, `workbench:limit` push.
- `Workbench.menu`: the Terminal launcher carries `data-workbench-terminal-new`
  and a count span; `WorkbenchMenu.paint` fills `n / 4` and sets the title at
  four. `Workbench.shell`: terminal slots label their × "Close terminal".
- Tests (`workbench_live_test.exs`): four clicks → four `live_render` children
  with four distinct `data-session-key`s (`workbench`, `workbench-2`, …); a
  fifth click leaves four and pushes `workbench:limit`; `/?panel=terminal` on a
  layout with two terminals opens none and focuses the first; the existing
  "Terminal opens in the work area with a persistent session" test still finds
  `workbench-terminal` with key `workbench`.

### Phase 3 — Close means close

- `workbench.js`: intercept the × on a terminal pane; find that pane's
  `TerminalView` hook through the live registry (`registerTerminal` — add a
  `pane()` accessor rather than scanning the DOM); busy → confirm; then
  `terminal_close`, `localStorage.removeItem("bc:term:<key>")`,
  `pushEvent("workbench_close")`.
- `WorkbenchHook`: a terminal close also drops the key from
  `@workbench_mounted` (today `put_state` only ever adds).
- Tests: live test that closing `terminal-2` unmounts its child and a following
  `workbench_terminal_new` lands on `terminal-2` again, not `terminal-3`.
  JS test for the pane-close sequence with a stubbed `invoke`.

### Phase 4 — ⌘T

- `tab_strip.js`, net-zero: the `"t"` branch and `menuShortcut("new_tab")` call
  one new two-line helper in `lib/tabs.js` (`requestNewTerminal()`): on the
  work area dispatch `bc:terminal-new`; on the Browser do nothing (the chrome
  owns it); elsewhere `location.href = "/?terminal=new"`. `openTerminalTab` and
  `openNewTerminalTab` go — check first that `terminal_tab_open` / the
  TerminalWorkspace path (`onOpenTerminalRequest`) does not use them; it builds
  its own path, so it should not.
- The Workbench hook listens for `bc:terminal-new`. Verify in the dev app that
  the chord fires with focus inside xterm (the capture-phase listener is what
  beats xterm's `textarea`; `isTypingContext` is deliberately *not* consulted,
  same as today).
- Headless browser check, the kind `4716c83` used: focus terminal 1, press ⌘T,
  expect two panes; press until four, expect the badge and no fifth.

### Phase 5 — The walk, in the real app

Dev app first, then a clean unsigned build. The list is in
[Part V](#the-acceptance-walk). Phase 5 is the only phase that is not code.

---

## Part V — Tests and the acceptance walk

### What each layer asserts

| Layer | File | Guards |
|---|---|---|
| State | `workbench_state_test.exs` | slot allocation, reuse, the limit, restore |
| LiveView | `workbench_live_test.exs`, `terminal_live_test.exs` | four children, distinct keys, ensure-vs-create, no split/copy buttons |
| JS unit | `tabs.test.js`, `workbench.test.js` | `requestNewTerminal` routing by location; pane-close sequence |
| Headless | the `4716c83` browser checks | ⌘T inside xterm; the badge; no fifth |

Break the guard before trusting it: set the slot list to five and watch the
limit test fail; make `destroyed()` skip `terminal_close` and watch the reuse
test attach to the old shell.

### The acceptance walk

1. Fresh profile: sidebar Terminal → one shell, prompt visible, typing works.
2. Click three more times → four panes in the current arrangement, each with
   its own prompt; the badge reads `4 / 4`.
3. Fifth click → nothing opens; the badge title says why; the active terminal
   keeps focus.
4. In terminal 3 run `sleep 100`; click its × → the busy prompt; cancel → still
   running; confirm → the pane is gone, the badge reads `3 / 4`.
5. Sidebar Terminal → the new pane is **Terminal 3** again, with a fresh shell
   (no `sleep` in its process tree).
6. Focus terminal 1, ⌘T → a fifth pane does not open at four; with one closed
   it does, and focus lands in it.
7. Switch to Settings, ⌘T → lands on the work area with a new terminal.
8. Browser tab, ⌘T → a new browser tab, nothing in the work area.
9. Change the arrangement to Stacked with four terminals open → four rows, no
   remount (scrollback intact).
10. Quit and relaunch → the layout restores with four empty shells (PTYs do not
    survive a relaunch; that is today's behaviour, not a regression).
11. Upgrade path: a profile from before this map, with its one terminal open
    and a command running, then switch branches and reload → the same shell is
    still attached under `workbench`.

---

## Part VI — Not in scope

- **The standalone `/terminal` tab and `/split`.** Routes, `PaneRoutes`, the
  drag-to-join, the role terminals the CLI opens (`terminal_tab_open`,
  `TerminalWorkspace`, `bc:open_terminal`) — all untouched. Whether role
  terminals should land as work-area slots instead is [Q1](#q1--should-role-terminals-become-panels).
- **⌘W inside a terminal pane.** Today it closes the current *tab*. Making it
  close the focused pane is a natural next step and a separate decision.
- **Rust.** No session cap, no new commands. `terminal_close` and
  `terminal_busy` already exist.
- **Naming or renaming panes.** Slots are numbered; a label editor is not asked
  for.
- **The terminal's own toolbar beyond the two deletions.** The status chip and
  `cmd-list` stay as they are.

---

## Part VII — Risks

- **R1 — Double-fire on ⌘T** ([I.4](#i4--t-is-already-taken-twice-and-both-takers-open-a-tab)).
  Phase 0 exists to measure it. Building Phase 4 without the answer risks two
  panes per press, and the fix (dropping the accelerator) touches Rust.
- **R2 — A ghost shell.** If Phase 3 ships without clearing `bc:term:<key>`, the
  next terminal in that slot reattaches to the shell the user closed, scrollback
  and all. The reuse test is written to catch exactly this.
- **R3 — Four WebGL contexts.** Each xterm loads the WebGL addon. WebKit's
  per-page context budget is well above four, and a lost context already falls
  back to the DOM renderer (`loadWebglRenderer`). Watch for it on the walk
  (step 9) rather than designing around it.
- **R4 — `restore/1` and old layouts.** A saved tree from before this map holds
  only known keys, so it restores; the risk runs the other way — a layout saved
  *after* this map, opened by a build *before* it, drops to `new()`. That is the
  existing behaviour for any unknown key and is acceptable for a dev-only
  window.
- **R5 — The one line of headroom in `tab_strip.js`.** If Phase 4 cannot be
  net-zero there, the helper moves wholesale into `lib/tabs.js` and the strip
  only calls it. Do not raise the cap.

---

## Part VIII — Open questions for the operator

### Q1 — Should role terminals become panels?

`terminal open mailman` and the on-duty startup profile open a standalone tab.
With panels able to carry a session key and a label, they could open as a slot
instead (`workbench_terminal_new` with `startup_profile`). It would end the
standalone terminal tab as a thing users ever see. **Default if unanswered:**
no; this map ships the four slots and leaves role terminals where they are.

### Q2 — Should Tabs → New Tab be renamed?

The menu item will mean *New Terminal* in the app and *New Tab* in the Browser.
A single label cannot say both. Options: leave it (default), rename to "New
Tab / Terminal", or add a second item "New Terminal" with ⌘T and move the
browser's chord to ⌘⇧T. **Default:** leave it.

### Q3 — Should the sidebar button also focus?

Under D3 a click at the limit focuses the active terminal, but a click below the
limit always creates. If you want "click once to show my terminals, click
again to add one," say so — it changes D3 to *ensure on first click, create on
the next*, which is one more state and one more thing to explain.
