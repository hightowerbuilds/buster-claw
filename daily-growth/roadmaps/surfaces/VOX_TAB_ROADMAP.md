# Vox — record it, make it say something, put it somewhere

**Scoped 2026-09-05 · Status: Phases 0–1 SHIPPED 09-05, plus `D6`–`D9` and the
first cut of Phase 3. Phase 2 next.**

> **Green at the close of Phase 1:** 4,343 Elixir tests / 0 failures, bun 352 / 0,
> credo strict clean, size gate holds on the new file. **Unwalked** — no part of
> this has been used by a person, and `R3` still stands: no render in any test
> has ever made a real sound.

> ### The one-sentence version
>
> **The voice stops being a settings page and becomes a place you work: record
> once, type a phrase, and assign that phrase to somewhere it will actually be
> heard — all on the homepage, between Chat and Notes.**

Successor to [`VOICE_ROADMAP`](VOICE_ROADMAP.md), which is BUILT. That map put a
speech engine in the app and proved the plumbing. This one is about **where the
controls live and what shape they are in**, because the answer today is "eight
panels stacked on a settings route, plus a ninth on a different settings route."

---

## The ask, as given (09-05, operator)

> *"Create a new sub-tab on the homepage between Chat and Notes… incorporate all
> of the necessary things that we need: to train it, to be able to ask it to
> create certain phrases, to be able to assign those phrases to various places."*

Three verbs. **Two of them exist and one is half-missing** — see `F6`.

| The verb | What backs it today | Where it lives |
|---|---|---|
| **train** | `Voice.Reference` (record takes, pick one) + `Voice.Config` (six engine knobs) + `Voice.Engine` (probe/verify) | `/voice`, panels 3–5 |
| **make** | `Voice.Clips` (type it, hear it, kept with a manifest) | `/voice`, panel 6 |
| **assign** | `Voice.Chimes` (16 routing keys), `Voice.Greeting` (the phone), `Voice.Messages` (notifications) | `/voice` panels 7 and 9 — **and `/notify-settings`** |

## Decisions taken at scoping (operator, 09-05)

- **`D1` — everything voice-shaped goes in the tab.** All eight `/voice` panels,
  including the two that are *not* VoxCPM at all (the `say(1)` on/off toggle and
  the macOS voice picker), plus spoken messages from Settings → Notify. One
  surface, nine panels.
- **`D2` — one source, two hosts.** The surface becomes a `LiveComponent`
  rendered by both the homepage tab and `/voice`. This is not a new idea: it is
  exactly what `PhoneComponent` does for `/phone` and the Phone sub-tab, and its
  moduledoc already carries the reasoning. **No parallel copy.**
- **`D3` — the tab is called `Vox2B`** (operator, revised mid-build from `Vox`).
  Between Chat and Notes:
  `Chat │ Vox2B │ Notes │ Pockets │ Calendar │ Phone │ Explained │ Activity`.
  The tab **key** stays `vox` — it addresses the surface (`VoxComponent`, at
  `home-vox`), while the label names the model doing the talking. Every other row
  in `@home_tabs` is a downcased label, so that divergence is commented at the
  list rather than left looking like a typo.
- **`D4` — the context is NOT renamed.** `BusterClaw.Voice.*` stays. The tab is
  a label; a sweep over nine context modules to match it would be the exact
  failure `feedback_sweep_renames` records, and would buy nothing.
- **`D5` — `/voice` keeps its route.** Page chrome around the same component.
  Deep links and `SplitLive` panes still land somewhere, the way `/phone` and
  `/calendar` did when they became sub-tabs.
- **`D6` — Voice leaves the Settings rail entirely** (operator, 09-05, after
  seeing Phase 1). It is not a setting you visit; it is a surface you work at,
  and it has one home now. Four lists move together, two of them guarded:
  `SettingsTabs.@tabs`, `TAB_GROUPS` in `tabs.js` (pinned to the first by
  `SettingsTabsTest`), `tabs.test.js`, and — **the one nothing would have caught
  —** `Layouts.@tab_labels`. An ungrouped route can no longer borrow the Settings
  group's label, so without a new entry the tab strip titles a deep link
  `/voice`, which is the exact raw-path failure `SettingsTabsTest` was written
  about. `/voice` also stops rendering the rail: a rail that lists neither the
  page nor an active tab claims membership of a section the route has left.

## Findings from reading the code (09-05) — these shape the build

**`F1` — a `LiveComponent` has no process, and this surface needs one.**
`VoiceLive` holds two things a component cannot receive: `Renderer.subscribe()`
(`{:voice_render, key, result}`) and `Task.async` replies (`{ref, result}` plus
`:DOWN`, for `engine-verify` and `chime-render-all`). **Both hosts must subscribe
and relay.** `PhoneComponent`'s host contract is the template to copy, including
its warning: hosts subscribe rather than the component doing it in `update/2`,
because a component shares its host's process and a host that already subscribes
would otherwise receive every broadcast twice.

**`F2` — `pushEventTo(this.el, …)` is safe at both recorder call sites.** Read
out of `deps/phoenix_live_view/assets/js/phoenix_live_view/view.js:1564`
(`targetComponentID/3`), not assumed: an element with no `phx-target` resolves to
`null`, which targets the LiveView. So `voice_recorder.js` can switch from
`pushEvent` to `pushEventTo` **without touching the Studio recorder**
(`components/studio/recorder.ex:158`), which carries no `phx-target` and must
keep reaching `StudioLive`. The hook is already parameterised for two call sites
via `data-event-take` / `data-event-report`; this is the third parameter it needs.

**`F3` — `voice_picker_lockstep_test.exs` pins `voice_live.ex` by path.** Moving
the picker markup will fail it, by design — that test exists because a renamed
attribute leaves LiveView tests green while the control silently dies. Its
`@templates` list moves in the same commit as the markup, never after.

**`F4` — `status_live.ex` has 72 lines of headroom** (738, cap 810, HELD). The
relay handlers land there. If they do not fit, the cap is raised **in the same
commit, with the reason**, per the size gate's own rule.

**`F5` — the rail/guard lockstep test iterates `home_tabs/0`**
(`status_live_test.exs:1058`), so `vox` is covered the moment it joins the list.
That test exists because Phone once arrived as a button the server refused.

**`F6` — "assign" is the half that is actually missing.** The primitives are all
there: `Chimes.install(key, path)` installs any rendered wav as a key's chime,
`Sound.assign(key, name)` routes a library sound at a routing key, and
`Messages` installs `message-<name>.wav`. What does not exist is a control that
takes **a phrase you made** and puts it **somewhere you choose**. Today clips,
chimes and messages are three unrelated editors that each render their own
audio; a clip cannot become a chime without re-typing the line into a different
box and paying for a second render. **Phase 4 is the only genuinely new
feature in this map.**

**`F7` — there is no training step, and the UI should stop implying one.**
VoxCPM clones zero-shot (`Voice.Reference`: *"'Have the model learn my voice' is
not a job this module runs — it is a file this module saves"*). "Train" here
means **record a take, hear it, keep or re-record**. The panel says that in
those words rather than borrowing fine-tuning's vocabulary for something that
takes ten seconds.

---

## Phases

### Phase 0 — the component exists, and `/voice` renders it

Extract all eight panels and their handlers out of `voice_live.ex` (1,040 lines)
into `BusterClawWeb.VoxComponent`. `VoiceLive` becomes page chrome plus the two
subscriptions of `F1`, mirroring `phone_live.ex`.

**No behavior change, and that is the exit test:** the existing
`voice_live_test.exs` and `voice_live_engine_test.exs` pass against the new
structure with only selector-scoping edits. `voice_picker_lockstep_test`'s
`@templates` list moves with the markup (`F3`).

- [x] `VoxComponent` with a documented host contract (`notify/2` + relay shapes)
- [x] `VoiceLive` reduced to chrome + subscribe/relay — **1,040 → 65 lines**
- [x] `voice_recorder.js` → `pushEventTo`, Studio call site unchanged (`F2`)
- [x] Component id namespaces every DOM id the hooks reach for
- [x] Size-gate entry for the new file, capped on arrival at 1,139 FROZEN

**What the move cost, exactly:** three `render_hook(view, …)` calls in
`voice_live_engine_test.exs`. They pushed at the LiveView, which no longer has a
`handle_event` — so they had to be aimed at the recorder *element*, which is
what the browser now does too. Nothing else in 25 tests moved, which is the
evidence Phase 0 changed no behavior.

### Phase 1 — the tab

`{"vox", "Vox2B"}` between `chat` and `notes` in `@home_tabs`; the component
rendered at `home-vox`; `StatusLive` subscribes to `Renderer` and relays.

- [x] Tab renders and is reachable (covered free by `F5`)
- [x] The tab-order snapshot updated — it failed on arrival, which is its job
- [x] **A render broadcast reaches the sub-tab, not just `/voice`** — asserted
      end to end: stub the engine, submit a clip on the homepage, wait for the
      `Renderer` broadcast to come back through the relay.

**The guard was broken on purpose before it was trusted.** Deleting the
`{:voice_render, …}` clause from `status_live.ex` turned that test red with its
own failure message and left every `/voice` test green — which is precisely the
silent staleness `R2` describes. Restored, and green again.

**`F4` held with room to spare:** `status_live.ex` went 738 → 781 against its
810 cap, so the relay landed without touching the number.

### Phase 2 — spoken messages come home

Move the messages panel out of `notify_settings_live.ex` into the component.
Settings → Notify keeps sound *routing* (that is Notify's job) and links to Vox
for the lines themselves.

- [ ] `notify_spoken_messages_test.exs` retargeted, not deleted
- [ ] Notify's own `{:voice_render, …}` subscription removed with its panel

### Phase 3 — the three-act arrangement

Nine panels in a flat stack is the settings page it is trying to stop being.
Rearrange behind an internal rail — **Train · Make · Assign** — the way
`PhoneComponent` uses a two-tab rail rather than one long column.

- [ ] The rail's keys and the guard are one list (the `F5` lesson, applied here)
- [ ] Engine probe/verify sits in Train; it is the precondition for everything

### Phase 4 — one phrase, anywhere (the new part)

The control `F6` describes: pick a phrase you already made, pick where it goes —
any of the 16 routing keys, the phone greeting, or a named spoken message — and
it is installed there **without a second render**, because the audio already
exists on disk.

- [ ] A clip can become a chime with no re-typing and no re-render
- [ ] Assignment is visible from both ends: the phrase says where it is used,
      the destination says which phrase it holds
- [ ] Re-assigning does not orphan the previous file

---

## What the first look changed (09-05, operator at the screen)

**The engine is installed.** `~/.buster-claw/voxcpm/bin/voxcpm`, running on
`cpu`. `VOICE_ROADMAP`'s standing caveat — *"nothing here has yet made a real
sound"* — is now testable on this machine rather than blocked on hardware. It is
still true until someone types a line under **Make** and hears it back.

**`D7` — the engine "Run it" button is deleted, and `Engine.verify/0` with it.**
The operator's verdict: *"I just click Run it and then it just says it answered.
There's no actual experience happening on the user end."* Correct, and the
alternatives are all worse:

- *Run it automatically on load* was considered first and rejected on `Engine`'s
  own moduledoc — even `--help` pays a full torch import, which is the stated
  reason `probe/0` never spawns anything. Auto-verifying would put a torch import
  on a homepage tab every five minutes (the probe TTL).
- *Make it say hello* is a strictly worse duplicate of **Hear yourself**, which
  already renders arbitrary text in the operator's own voice one act down.

So the panel now states what is *installed* and nothing claims to know whether it
*runs*. A broken install reports itself in the render note of the first thing you
ask for, which is both later and more useful than a pre-flight shrug. `verify/0`
had exactly one caller and three tests; all four went, and the reasoning is in
`Engine`'s moduledoc so it is not re-added by someone tidying. It is in git if a
support-shaped "engine doctor" ever wants it.

**`D8` — the surface is one panel with hairlines, not nine cards.** Operator:
*"a tidy minimalist style."* Sections group under four sticky act labels — Train,
Make, Assign, and **Reading aloud** last, because the `say(1)` half is a
different engine and putting it in one of the three acts would claim otherwise.
The `ic-vox-*` utilities are scoped rather than a change to `.ic-panel`: this
surface is the exception and the twenty other panels are not. Phase 3's grouping
has therefore arrived as presentation; **the rail itself is still unbuilt**, and
that is what keeps the file FROZEN.

**`D9` — a render shows a clock, not just a spinner.** Operator: *"a little
animation that shows that the model is building out the line we're creating."*
Two constraints shaped it: `Voice.Renderer` broadcasts one message per job (at
the end), so there is no percentage and never will be without the engine
reporting one; and these waits are **minutes**, so a spinner that has turned for
four of them says what it said at four seconds. The chip is therefore a pulse
**and** a running clock — `BusterClawWeb.Vox.Progress`, reusing the chat's
`ThinkingTimer` hook with `data-label-running` / `data-elapsed-ms` rather than
forking it (the `voice_recorder.js` precedent).

`data-elapsed-ms` is the load-bearing part and is specific to this tab: Home
renders the panel behind `:if={@home_tab == "vox"}`, so a wander to Chat and back
**destroys and remounts** the element. A purely client-side timer would restart
and report "0.2s" into a four-minute render — worse than no number, because it
reads as authoritative. The three start times are therefore server state.

It also fixed something older: **`@clip_jobs` had been tracked since the surface
was written and rendered nowhere.** A queued clip showed one sentence and an
empty textarea, so the line you had just typed left the screen for the whole
render. It stays now, in italic, with the clock beside it, and becomes the player
when the render lands.

**Phase 3 has begun, sideways.** The chip is an addition to a FROZEN file, so it
had to be funded by an extraction: `What it says` is now
`components/vox/chimes.ex`. Cap went 1026 → 1005 — the feature landed and the
file got *smaller*, which is the fourth time this tier has produced that outcome.

## Risks

- **`R1` — the extraction is large and the suite is the only witness.** ~590
  lines of template and ~350 of handlers move at once. Mitigation: Phase 0
  changes no behavior, so any red test is a real regression, not an expected
  churn — which is only true if Phase 0 stays disciplined about scope.
- **`R2` — two hosts, one relay, and a silent failure mode.** A host that stops
  relaying leaves the surface *looking* fine and never updating. Phase 1's
  explicit relay test is the answer; it must be written to fail if the relay is
  removed (`feedback_break_the_guard`).
- **`R3` — nothing here has ever made a real sound.** `VOICE_ROADMAP` Part 0
  stands: every render in every test is a stub copying a fixture WAV. This map
  moves controls; it does not make the engine any more proven than it was.

## Explicitly out of scope — and do not re-propose

- **Renaming `BusterClaw.Voice.*`** (`D4`).
- **VoxCPM reading the chat live.** Declined 09-03 on measured RTF; `say(1)`
  already does it. `VOICE_ROADMAP` carries the numbers.
- **A fine-tuning step.** `F7`. Zero-shot has to be judged insufficient before
  anything tunes it.
- **Deleting the `/voice` route** (`D5`).
