# 09-05-26 — Four things left, and one that never did

Seven commits, and five of them are a removal or a move. Voice left Settings, the
engine's liveness button left, the Sketch Pad left whole, Notes and Calendar left
Home. The day's last find was the opposite: **a render job that died without
saying so, and stayed marked as running forever.**

The useful part of the day is in three places — what the gates caught in the
*removing* direction, one bug I wrote and found before it shipped, and the two
confident wrong answers I gave about the flake.

---

## What landed on main

| | |
|---|---|
| `d319c6f` | **Vox2B** — the voice becomes a homepage tab, and leaves the Settings rail |
| `b1e82ae` | One surface with hairlines, not nine cards with shadows |
| `a040f57` | The engine liveness check deleted — it produced a sentence, not an experience |
| `69ae8ee` | A render shows a **pulse and a running clock**, not a sentence |
| `f129434` | **The Sketch Pad deleted whole** — the model still draws, in the chat |
| `e1bf48a` | The Workspace grows a rail: **Directory · Notes · Calendar** |
| `2612105` | A dead render job wedged the queue permanently |

**Gate at close:** 4,095 Elixir tests / 0 failures (verified ×4), bun 340 / 0,
credo strict clean, docs drift OK, 2 accepted cycles. **219 → 213 commands.**

**CI is red and it is not ours.** Nine failures, byte-identical to the set before
today's pushes — `SoundStudio`/`VoiceLibrary` header probes needing `afconvert`,
and the `Info.plist` lockstep. All macOS-only, all on an ubuntu runner, all left
deliberately. Dialyzer, Rust and JS are green. The diff of the failure lists
before and after is empty, which is the only reason that sentence is worth
anything.

---

## The morning: the voice gets somewhere to live

`/voice` was eight panels on a settings route, plus a ninth on a *different*
settings route. The ask was one tab on the homepage with all of it. The move
itself was cheap for a reason worth restating, because it is the third time this
month it has paid: **a component that renders inline with no layout of its own
can be re-homed by whoever provides the chrome.** `PhoneComponent` proved it,
`VoxComponent` reused it, and `NotesComponent` did it again in the evening.

What was *not* cheap was the host contract. A `LiveComponent` has no process, so
it receives neither the `Renderer` broadcast nor its own `Task` replies — both
land in the host's mailbox. Both hosts relay now, and the component checks each
task ref against the one it started rather than assuming an unrecognised ref is
its own. That assumption was safe with one host and is a bug with two.

### Voice leaving Settings took four lists, and only two were guarded

`SettingsTabs.@tabs`, `TAB_GROUPS` in `tabs.js` (pinned to the first by
`SettingsTabsTest`), `tabs.test.js` — and `Layouts.@tab_labels`.

> **The fourth one nothing would have caught.** A route collapsed into the
> Settings tab group borrows that group's label. Take it out of the group and it
> has no label of its own, so the tab strip titles a deep link **`/voice`** — the
> exact raw-path failure `SettingsTabsTest` was written about after
> `/notify-settings` did it. The test that exists for this could not see it,
> because the drift was in a third file neither side names.

### The restyle, and a bug I wrote

Nine `.ic-panel` cards with `text-2xl font-black uppercase` headings is correct
Industrial Claw for a page you visit and a wall on a tab you work in. It became
one surface with hairlines under four sticky act labels — Train · Make · Assign ·
Reading aloud, the last separate because it is a different engine.

The sixteen chime rows became a CSS grid, and `:for` has to wrap *something*:

> **`<template>` is a trap.** Its contents are inert. The rows would have
> rendered invisible and the inputs would never have submitted — and **every
> string assertion in the suite passed anyway**, because the markup is in the
> HTML either way. It is `display: contents` now, and `voice_live_test` refutes
> `<template>` on this surface. Verified by putting the bug back.

---

## "There's no actual experience happening"

The operator, with VoxCPM finally installed on his own machine, on the engine
panel's **Run it** button: *"I just click Run it and then it just says it
answered."*

Correct, and both alternatives were worse. Running it automatically on load was
rejected on `Engine`'s own moduledoc, which already says why — even `--help` pays
a full torch import, which is the stated reason `probe/0` never spawns anything.
Turning it into "say hello" duplicates **Hear yourself**, one act further down,
which renders arbitrary text in his own voice.

So it went, and `Engine.verify/0` with it — one caller, three tests. The panel
says what is *installed*; nothing claims to know whether it *runs*. A broken
install reports itself in the render note of the first thing you actually ask for,
which is later and more useful than a pre-flight shrug.

> **A vacuous guard is worse than none.** The "nothing installed" test used to
> `refute` that button. After the deletion that is trivially true, so it now
> asserts what *is* true of that state. A test that passes because its subject
> stopped existing is not a test.

Then the opposite request: *a little animation that shows the model building out
the line.* Two constraints made the shape. `Voice.Renderer` broadcasts exactly
one message per job — at the end — so there is no percentage and never will be
without the engine reporting one. And these waits are **minutes** on a CPU, where
a spinner that has turned for four of them says what it said at four seconds.

So: a pulse **and** a clock. The pulse answers *is it alive*, the clock answers
the question you actually have at minute three. It reuses the chat's
`ThinkingTimer` rather than forking it — parameterised through data attributes,
the way `voice_recorder.js` already was.

> `data-elapsed-ms` is the load-bearing part. Home renders the tab behind an
> `:if`, so wandering to Chat and back **destroys and remounts** the element. A
> purely client-side timer would restart and report "0.2s" into a four-minute
> render — worse than no number, because it reads as authoritative.

It also fixed something older: **`@clip_jobs` had been tracked since this surface
was written and rendered nowhere.** A queued clip showed one sentence and an
empty textarea, so the line you had just typed left the screen for the whole
render.

### The frozen cap bought two extractions

`vox_component.ex` was capped FROZEN on arrival at 1,139 — no headroom, by
design. It ended the day at **1,005**, having *gained* a feature:

| | |
|---|---|
| 1,139 → 1,072 | the restyle: chrome came off, every control stayed |
| 1,072 → 1,026 | the liveness button left |
| 1,026 → 1,005 | the render chip needed room, so **`What it says` moved out** to `components/vox/chimes.ex` |

That last row is the tier working exactly as written. A raised cap would have
bought the same feature and left the file bigger; the freeze bought it and left
the file smaller. Fourth time. It is also `VOX_TAB_ROADMAP` Phase 3's first real
cut, arriving sideways because the gate would not let me take the easy path.

---

## The Sketch Pad, deleted whole

*"I dont recall if there is more than a sketch app here."* There were two, and
they shared no code:

- **The Sketch Pad** — `/sketch` *and* the Studio's third tab, `BusterClaw.Sketch.*`,
  six commands, two hooks, an asset route, the dock item, a tutorial.
- **`BusterClaw.SvgViewer`** — the chat's SVG channel. The model emits a fenced
  ` ```svg ` block; it is sanitized and rendered as a real SVG.

So the thing anyone wanted from the Pad was already met by the surface that is on
screen anyway. ~7,350 lines, 246 tests, six commands.

**Two general mechanisms went with it**, because the Pad's `D6` was their only
caller: caller-aware dispatch, and `surface_confirmation/4` — a command deciding
for *itself* that it needs the operator, recorded into `Sentinel.Pending`. Deleted
rather than left unreachable: Dialyzer does not analyse unreachable code and no
test could reach them, so keeping them would have been a comment that compiles.
`commands.ex` carries the note that they return **together or not at all** —
the first without the second returns a refusal the operator never sees, which is
how it shipped the first time.

The operator's drawings stayed. `sketches/` is `:deprecated`, which sweeps only
once empty.

> **Two guards fired in the removing direction** and made me look: the Studio
> rail snapshot and the safe-tier catalog snapshot. And `update_test`'s positive
> control **was** `sketch_update` — a control that stops existing is a test that
> stops testing, and it would have gone green against an empty catalog. Replaced,
> not dropped.

---

## The evening: Notes and Calendar move to the Workspace

Same shape as the morning, third host each, and the tests **moved** rather than
being rewritten — eighteen of them, four substitutions: the route, the tab event,
two component ids. That they needed nothing else is the evidence it was a move.

> **`NotesComponent` hardcoded `id="home-notes"` on its root element**, and had
> since it was written. It worked only because the homepage was its one host. The
> moment a second existed the id stopped describing anything: `send_update`
> addressed `workspace-notes` while the DOM still said `home-notes`, so every
> keyboard hook that reaches for its own root — the switcher, the new-note chord
> — found nothing. A split pane would have collided the same way. Latent for
> months; visible in an afternoon.

Home is now **Chat · Vox2B · Pockets · Phone · Explained · Activity**. The
Pockets test asserted "Pockets sits directly after Notes", which is a claim about
a tab that left; it is anchored to Vox2B now and stays a *neighbour* assertion
rather than an index, because what it always checked is that Pockets is not the
tab nobody can find.

---

## The one that never left

Verifying that move, a full run failed with **seventeen voice tests down at
once** — every `assert_receive` timing out with an **empty mailbox**, nothing in
the log, and the next identical run green. Two of eight runs.

I was confidently wrong twice.

**Wrong once: test budgets.** Raised two from 1s to 5s. It still happened. *A
budget is the first thing you reach for and the last thing that is ever the
cause.*

**Wrong twice: an unowned Ecto checkout.** `Renderer` is a singleton outside
every test's sandbox, and `do_render` called `Engine.resolve/0`, which reads a
Settings row. `Config.get/0` survives that by rescuing **and** catching exits — so
it would not crash, it would block for the connection timeout. A good story, and
a real defect. **Fixed on its own merits, and not the flake.**

What made it findable was reverting **only** `renderer.ex` to `HEAD` and running
in isolation: three green on the committed version, three failures on mine. That
turned a heisenbug into a deterministic one.

> **`Task.start/1` is neither linked nor monitored.** A job that died without
> sending `{:done, …}` left `state.running` set with nothing alive to clear it,
> and the single queue wedged **permanently** — every later render sat in it
> forever. `do_render/3` rescues exceptions, which is precisely why this read as
> impossible: **a rescue does not cover an exit or a kill, and a process dying
> that way sends nothing.** Hence no crash in the log. The "green re-run" was a
> fresh app, not a fresh roll of the dice.

`spawn_monitor`, the ref in state, and a `:DOWN` clause that treats a dead job as
an ordinary failed render. Four consecutive clean full suites, against two
failures in the previous eight.

Both fixes are pinned by **source guards**, and that is deliberate rather than
lazy: the job runs in a spawned process the suite never sees, so no behavioural
test can reach either property. Both were verified by reintroducing the defect.

---

## Worth carrying forward

- **`<template>` renders nothing and submits nothing**, and string assertions
  cannot tell.
- **`pushEventTo(this.el, …)` falls through to the LiveView** when the element
  has no `phx-target` (`targetComponentID/3`) — which is how one hook serves a
  component and a plain LiveView without a second copy.
- **LiveView processes a socket's messages serially**, so a pending row is in the
  `render_submit` reply no matter how fast the work finishes. I built a sleeping
  test stub on the opposite assumption; it bought no determinism across four
  seeds and cost a second on a shared queue.
- **An ungrouped route cannot borrow its group's tab label.**
- **A guard that fails when something is removed is doing the same job** as one
  that fails when something is added. Four did today.

## Open

- **CI's nine-failure floor** makes it unable to tell you anything — it has been
  red on every push since 09-04, so a real regression would look exactly like
  today. An `@tag :macos` plus `--exclude macos`, the same shape as
  `:browser_engine`, would turn it green without pretending those tests pass.
  Operator's call; noted only because the cost changed once everything else
  started passing.
- **`VOX_TAB_ROADMAP` Phase 2** — spoken messages still live in Settings → Notify.
- **Nothing here has made a real sound yet.** The engine is installed now, which
  makes **Make → Hear yourself** the first thing that would change that. Short
  line first: measured RTF on this Intel means minutes, not seconds.
