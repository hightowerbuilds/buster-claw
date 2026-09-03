# 09-03-26 — The operator at the keyboard, relaying what he sees

Yesterday built the Voice map with the operator away. Today he opened the app
and worked from the screen: *this shouldn't be here, this needs a UI, we need a
way to do that.* Five commits, each answering one thing he pointed at — and one
request declined, correctly, by a number he had forgotten.

---

## What landed — `95c5500..` on main

| | |
|---|---|
| `95c5500` | The dock tab is **Sketch**, not Studio |
| `a0ceef2` | Engine settings — reference clip, device, steps, guidance, path |
| `c4e95a8` | **Record your voice once**, then type anything and hear it |
| *this* | **Spoken messages** — notes to yourself in your voice, fired as notifications; four verbs for the agent |

**Gate at close:** 4342 tests / 1 failure (the pre-existing `BrandTest`), bun
348/0, credo clean, 219 commands.

---

## The Studio tab, and what it was sharing a route with

*"We still have our studio tab. That shouldn't exist anymore."* Removing it
would have deleted the only door to the **Sketch Pad** — a finished surface
(SKETCH_ROADMAP Phases 0–4) that lived at `/studio` beside Mix and the Voice
Library. Asked; the answer was keep it. So the tab became the Sketch Pad's, on a
new `/sketch` route that is thirty lines rather than three hundred because
`SketchComponent` needs nothing from a parent — no assigns, its own mount, all
eighteen of its own events. A property written so the drawing could survive a
sub-tab switch turned out to be exactly what let it move house.

Two things tried and reverted, the same mistake twice: deleting the `/studio`
*route* broke ~30 tests exercising Mix and Voice Library through it, and renaming
the Explained tutorial's key broke five more. Both stay until the spin-off takes
them with their tests. **A route deleted out from under its own suite is an
afternoon of guessing which failures were meant.**

> **A finding worth keeping.** `status_live_test` asserted `href="/studio"` in the
> rendered page, with a comment claiming it proved the tutorial deep-links to
> its surface. It never did — `studio` is a *built* tab so it renders
> `Explained.Studio`, which has no such link; only the stub renders a registry
> path. **The href it matched came from the dock nav bar.** Removing the dock tab
> turned it red, which is the only reason anyone learned it had been reading
> the wrong element all along. Removed, not repaired.

---

## One request declined

*"A simple toggle for users to have the model read the home page chat output —
wire the existing buttons for Vox."*

The buttons already work — the chat header toggle reads every reply through the
Mac voice picked in Settings, instantly, markdown stripped. What was being asked
for was VoxCPM doing that. **VoxCPM measured RTF ≈ 97 on this machine yesterday.**
A thirty-word reply is ~10 s of audio; ~16 minutes to render. Live readback in
the operator's voice cannot be live. Said so; *"Ah!! Ok we don't want that then
… forgot about that constraint."*

The constraint, restated so it stops being a number nobody remembers: **live
speech needs RTF < 1.** `say(1)` is effectively zero. VoxCPM is 1.76 on the best
Apple Silicon measured, 97 here. Anything that must speak *as it happens* is the
Mac voice. Anything made *ahead of time* — chimes, greeting, clips, messages — is
where the operator's own voice goes. It is the top of the Voice map now.

---

## Record it, and there is no training step

*"We need a way for users to record their voice, have the model learn it and
create their own clips."*

The middle clause is a misconception the panel copy clears up front. VoxCPM
clones zero-shot — hand it ten seconds of you and it speaks as you — so *"have
the model learn my voice"* is a file the app **saves**, not a job it runs. Saving
a take sets the reference clip; from that moment every chime, clip, greeting and
message is rendered in it.

The recorder **reuses the Studio's `VoiceRecorder` hook** rather than copying its
AudioWorklet and Float32 encoder: two `data-event-*` attributes let the same
microphone, meter and encoder push to a different listener, and the Studio's
behaviour is unchanged. `Capture.Take.decode/2` is the one piece of Studio
machinery this depends on — **when the Studio spins off, `decode/2` stays.**
Silence is refused, and so is anything under two seconds: a half-second of "uh"
is not a voice, and cloning it gives you a stranger's with no warning.

*Say anything* is the payoff and the fastest way to judge a recording — one
sentence is minutes, the chime set is most of an hour.

---

## Spoken messages: one sentence of design

*"A UI in Notify for creating messages for users to notify themselves with. The
model needs to reach that via CLI."*

**A spoken message is a notification whose sound is a rendered line.** The line
renders through `Voice.Renderer` and is installed in the sound library as
`message-<name>.wav`; the notification carries that filename in
`metadata["sound"]`; `Sound.for_notification/1` honours it ahead of the routing
walk. That is the whole change to the notification layer — one clause. The modal,
snooze, the sound toggle and the audit feed all come for free, because a fired
message *is* a fired notification. A dangling sound name falls through to the
walk rather than to silence.

**Nothing waits on the render.** `create/2` returns at once; readiness is read
off the disk each time; installing into the library happens lazily the first
time a ready message is listed or fired. No process listens for the render to
finish — nothing to supervise, nothing left half-done.

Four verbs for the agent — `voice_message_create`, `_list`, `_fire`, `_delete` —
so the model can leave the operator a message in the operator's own voice: *"I
finished the report,"* now, in N seconds, or at nine tomorrow. Command count 215
→ **219**; `_list` is the only `:safe` one, and the review-forcing snapshot in
`catalog_invariants_test` demanded to know why before it would pass.

---

## Four small bugs, all found by tests, two of them mine

- **`config_test` deleted `telephony_relay_url` in cleanup** instead of restoring
  it — wiping the test-env relay for every Pins and Drain test that ran after. 25
  failures in files the change never touched. `greeting_test` had done it right.
  **Test cleanup restores app env; it never `delete_env`s.**
- **The renderer's PubSub topic is global.** `assert_receive {:voice_render, _,
  {:ok, _}}` could be satisfied by a *previous* test's render landing late, so a
  test proceeded before its own audio existed. Every receive is now pinned to its
  own cache path.
- **The batch "gap" test once found its victim already cached** under a random
  seed. `workspace_root` is global app env, so a render finishing after its test
  ends writes into whatever root is current. That describe now wipes its cache in
  setup, asserting the precondition.
- **Pre-existing, not touched:** `SoundBoardTest` is `async: true` and
  `refute_receive`s on a global topic while `chat_test` rings `"chat"`. Twenty
  more tests shifted the schedule enough to show it once.

---

## Still open

- **A listen.** Nothing rendered today has been heard through a real chime or a
  real phone call. `Speak them` with a recorded clip is the test.
- **`supabase functions deploy voice`**, then phone the number.
- **`Pockets.BrandTest`** stays red on any clean clone — brand art is gitignored.
- **The Studio's route and tests**, reachable by URL, tabless, waiting for the
  spin-off.
