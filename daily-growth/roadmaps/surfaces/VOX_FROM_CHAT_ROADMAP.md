# Ask for a phrase in chat, hear it in your own voice

**Scoped 2026-09-05 · Status: Phases 0–1 SHIPPED 09-05. Phase 2 open.**

> **Unwalked, and `R2` is why that matters here more than usual.** The verbs are
> green against a stub that copies a fixture WAV. Nobody has yet typed "make me a
> line" in chat and heard it come back.

> ### The one-sentence version
>
> **"Make me a line that says the build is done" — typed in chat, rendered by
> VoxCPM in the operator's own voice, and the operator finds out when it is
> ready without having gone looking.**

Successor to [`VOX_TAB_ROADMAP`](VOX_TAB_ROADMAP.md), whose Phases 0–3 built the
surface. This one is about reaching that surface **from the chat**, which is
where the operator actually is.

## The ask (09-05, operator)

> *"Create a CLI so that the model is able to write phrases that the Vox2B model
> will create… we want the user to be able to call Vox2B from the chat to make
> certain phrases."*

## What already exists, so we do not rebuild it

| | |
|---|---|
| `Voice.Clips.make/1` | Renders a line. Returns `{:ok, path}` on a cache hit, `{:queued, key}` otherwise |
| `Voice.Clips.install/1` | Copies a clip into the sound library (added 09-05) |
| `Voice.Renderer` | One global queue, one job at a time, `@max_queue 32`, broadcasts `{:voice_render, key, result}` |
| `voice_message_*` | Four verbs — but for **named** notification lines, not ad-hoc phrases |
| Vox2B → Files | Where a finished clip appears, with a player and `Use as a sound` |

**There is no command for clips.** That is the gap: eight `voice_*` verbs exist
and not one of them makes an ad-hoc phrase. The Vox2B tutorial states this as a
fact — recording, engine settings and the greeting have no command either — so
the tutorial and its catalog universal both move with this work.

## The two findings that shape everything

**`F1` — chat has exactly one artifact channel, and it is not audio.**
`SvgViewer` is the whole mechanism: the model emits a fenced ` ```svg ` block,
`Status.Chat` extracts it, and it renders beside the conversation. The model
learns the channel exists because `SvgViewer.guide/0` is appended to the system
prompt. **Nothing equivalent exists for sound**, so "hear it in chat" is a new
surface, not a wiring job.

**`F2` — a render takes minutes, and that is not a tuning problem.** Measured RTF
on the operator's CPU means a short line is *minutes*. So:

- The command **cannot block**. It returns `{:queued, key}` and the turn ends.
- By the time the model replies, **the audio does not exist yet.** Any design
  where the model hands back a playable thing in the same message is fiction.
- The operator will have moved on. Whatever tells them it is ready has to find
  *them*, not wait on a tab they may never open.

That second point is what makes this more than a `defdelegate`.

## Decisions

- **`D1` — a new `voice_clip_*` family, not an extension of `voice_message_*`.**
  A message is a *named* line installed as a notification sound; a clip is a
  phrase you asked for. Forcing a slug on "say the build is done" is friction
  invented by the data model. `Clips` is already a separate context with its own
  manifest; the verbs follow it.
- **`D2` — `:restricted`, not gated.** It writes a file and spends real compute,
  so `:agent` and `:mcp` are out. It is not outbound and not irreversible — a
  clip can be forgotten — so it does not join the `gated` set that
  `:agent_untrusted` is refused. Same shoulder as `voice_message_create`, which
  is the closest existing verb.
- **`D3` — the model is told the capability exists**, the way it is told about
  drawing: a guide appended to the chat's system prompt. A verb the model never
  learns about is a verb nobody uses. This is the smallest part of the work and
  the one most likely to be skipped.
- **`D4` — hearing it is Phase 2, and it is a real surface.** Phase 1 makes
  phrases; Phase 2 decides how the operator hears one without going looking.
  Splitting them is deliberate: Phase 1 is useful alone (the clip lands in Files
  with a player), and Phase 2 has a genuine design question that should not hold
  the verb hostage.

## Phases

### Phase 0 — the verbs

`voice_clip_make`, `voice_clip_list`, `voice_clip_delete`, dispatched to the
existing `Clips` functions. No new domain logic — `Clips.make/1` already handles
the cache hit, the queue and the refusals (`:empty_text`, `:engine_unavailable`,
`:reference_missing`).

- [x] Three verbs in `Catalog.Notify` beside the message family, tiered per `D2`
- [x] `voice_clip_make` returns the queued key AND a `note` that says in words
      that the audio is not ready. The note is load-bearing — it is what the
      model reads back to the operator — so a test asserts it, not just the key
- [x] The Vox2B tutorial's catalog universal **failed exactly as predicted**,
      was read, and the page's copy changed from "four verbs, all about
      messages" to "seven: four for messages, three for clips". That is the whole
      argument for guarding a claim about absence with a universal
- [x] `@command_stats` recomputed; 211 → 214

### Phase 1 — the model knows it can

A `Clips.guide/0` appended to the chat's system prompt, next to
`SvgViewer.guide/0`, teaching: what the verb does, that it takes **minutes**,
that the model must not claim the audio is ready, and that a reference recording
is what makes it the operator's own voice rather than a designed one.

- [x] `Clips.guide/0` written and appended beside `SvgViewer.guide/0`
- [x] A lockstep test: every `voice_*` the guide names must be in the catalog.
      **Verified by making the guide name `voice_clip_status` and watching it
      fail.** A system prompt is not covered by the compiler, the docs-drift gate
      or any LiveView test — it is a string handed to a model, and this repo has
      shipped a wrong one twice.
- [x] A second guard on the timing sentence, because that is the claim the model
      gets wrong by default: it replies in seconds, the render takes minutes.

### Phase 2 — hearing it without going looking

The open question, and the reason it is its own phase. Three candidates, none
free:

1. **Fire it as a notification when it lands.** Reuses the whole notification
   path — the modal, the sound routing, the audit feed — and the room hears the
   phrase. Cheapest by far. Risk: a phrase the operator asked for quietly
   becomes an *alert*, and alerts have a meaning that "here is your clip" does
   not.
2. **An audio row in chat**, the sound equivalent of the SVG viewer. Best
   payoff, most work: a new artifact channel, and it must appear *later* than
   the message that caused it — which no existing chat row does.
3. **Nothing; it is in Files.** Honest, already true after Phase 0, and a weak
   answer to "call Vox2B from the chat".

**Not choosing here on purpose.** Phase 0 and 1 ship value on their own, and this
choice wants the operator to have used the verb once first.

## Risks

- **`R1` — the queue is shared and bounded.** One global `Renderer`, `@max_queue
  32`, one job at a time. A model asked for ten phrases queues ten renders and
  blocks every chime, greeting and spoken message behind them for the better part
  of an hour. Phase 0 must decide whether the verb needs its own ceiling beyond
  the existing rate limiter, and `{:error, :queue_full}` must reach the model as
  a sentence it can act on rather than a tuple.
- **`R2` — nothing here has made a real sound.** `VOICE_ROADMAP` Part 0 still
  stands: every render in every test is a stub copying a fixture WAV. The engine
  is installed on the operator's machine now, so this is the second feature that
  would be better for one real render being heard first.
- **`R3` — a phrase is the operator's voice.** A clip made from chat is
  indistinguishable from one the operator recorded deliberately. That is the
  point of the feature and also the thing to be careful about: the guide should
  not encourage the model to make phrases unasked.

## Explicitly out of scope

- **Cloning anyone else's voice.** The reference recording is the operator's own,
  by construction, and nothing here adds a way to point it elsewhere.
- **Live readback.** VoxCPM pre-renders; `say(1)` reads chat. Settled in
  `VOICE_ROADMAP` on measured RTF, and re-proposing it is re-proposing arithmetic.
- **A second render queue.** One at a time is a deliberate constraint
  (`Renderer`'s moduledoc: serialising is the difference between slow and
  unusable), not a bottleneck to route around.
