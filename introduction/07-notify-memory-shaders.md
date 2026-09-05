## Notify: timers, alarms, reminders

You can put something on the clock, and the app will surface it to the user
even if this conversation is long over — a modal on the homepage plus a chime.

    ./buster-claw run notify_create --json '{"kind":"timer","label":"tea","in_seconds":180}'
    ./buster-claw run notify_create --json '{"kind":"alarm","label":"standup","at":"2026-07-29T09:00:00Z"}'
    ./buster-claw run notify_list                                     # pending + snoozed
    ./buster-claw run notify_snooze --json '{"id":7}'                 # default 300s
    ./buster-claw run notify_dismiss --json '{"id":7}'                # retire without firing

`kind=timer` needs `in_seconds`, `kind=alarm` needs an ISO-8601 `at`, and
`kind=reminder` fires immediately. Reach for these whenever the user says
"remind me" or "in twenty minutes" — a Notes entry is a record,
not a reminder, and nothing will wake them up.

## Spoken messages

A notification can arrive as a sentence **in the operator's own recorded
voice** instead of a chime. Four verbs:

    ./buster-claw run voice_message_list                                        # safe
    ./buster-claw run voice_message_create --json '{"name":"report-done","text":"The report is finished."}'
    ./buster-claw run voice_message_fire --json '{"name":"report-done"}'         # or in_seconds / at
    ./buster-claw run voice_message_delete --json '{"name":"report-done"}'

`name` is a slug; `text` is what gets said. **`voice_message_create` returns
before the audio exists** — the speech engine takes minutes on a slow machine —
so it comes back `ready=false` and `voice_message_list` is how you learn it has
landed. Firing one that is not ready is refused with `not_ready`, so wait,
don't retry blindly. All of this needs the speech engine installed; if it isn't,
say so rather than promising a message that will never render.

`voice_message_fire` **plays out loud in whatever room the machine is in**, in a
voice the operator will hear as their own. It fires now by default;
`in_seconds` makes it a timer and `at` (ISO-8601) an alarm. That is louder than
a chime in every sense — fire one because they asked for this message at this
moment, not to confirm the feature works.

In the app these are at **Home → Vox2B → Alerts**. They were under Settings →
Notify until 09-05; Notify still owns the routing table that decides which
*sound* plays for which event, which is a different thing from a spoken message.

## Memory & self-improvement

You are not the first run. `memory_search` full-text searches past run
summaries — **check it before re-deriving something**, especially on a
recurring job where a previous run already found the answer or hit the wall
you're about to walk into. `activity_report` summarizes a recent window:
requests done, blocked, and failed, what's still open, and unattended runs.
It's the honest answer to "what have you been doing".

The app also watches its own command traffic: repeated sequences become
**skill suggestions**. `skill_suggestions` lists them, `skill_analyze`
triggers a scan, and `skill_suggestion_approve` / `skill_suggestion_reject`
dispose of one. Approving turns a sequence you keep running by hand into a
named composition skill. Surface good ones to the operator rather than
silently approving your own.

## Shader patterns (homepage and terminal)

Backgrounds are live WebGPU **shader patterns**, chosen in Settings →
Appearance **or by you, with `background_set`**. There is **one** catalog and
**three** surfaces that can point at it — the homepage, the terminal, and the
Time & Place card in the corner of the home header — and the same pattern may
back all three at once. There are five shipped patterns. Four of them —
**smoke, waves, mandel, weather** — share one uniform/binding contract
(value-noise/fbm helpers, a 3-colour palette in `colA`/`colB`/`colC`, and a
shared `bg_post` tonemap pass) and are coloured through the user's palette, so
a pattern inherits their theme instead of fighting it. The fifth, **veil**, is
the image-reactive one: it is what goes on the right of a `+` in
`image:<slot>+<shader>` below. Shaders are used
elsewhere in the app too (the animated face, the phone keypad, the
seven-segment clock, the day-cycle sky); the background catalog is the one
place you can extend from the workspace.

**You can add new patterns at runtime.** Write one WGSL file at
`shaders/<name>.wgsl` in this workspace — just the fragment entry point
`fs_main` (the shared prelude is prepended automatically) — and it becomes
selectable in Settings → Appearance immediately, no rebuild and no restart.
Constraints worth knowing before you start: the file must define `fs_main`,
the name must be lowercase letters/digits/hyphens, and reads are size-capped
(64 KB). The browser compile-checks the WGSL and falls back gracefully on
error, so a broken shader degrades rather than blanking the homepage.

**`background_set` applies the five built-ins outright — `smoke`, `waves`,
`mandel`, `weather`, `veil` — and applies a workspace shader only once the
operator has applied that exact file themselves in Settings → Appearance.**
Their click is what approves it, and the approval is keyed to the file's
contents, so **if you edit the shader the approval is void** until they click
it again. The patterns already sitting in `shaders/` were approved when this
shipped, so an existing one will usually just work.

This is not a check on who wrote the file — a shader is a file, this workspace
is writable, and no command can tell a file you wrote from one they wrote. It
is a check on whether a human has ever looked at the GPU code you are asking to
put on their screen. The Appearance page itself has no such limit, because a
human is clicking there.

So when you write a **new** pattern the loop is: write the file, tell them the
name, and ask them to apply it once in Settings → Appearance. After that you
can point either surface at it whenever you like. Do not tell them you will
apply a new shader yourself, and do not plan on tweak-look-tweak: every edit
needs another click, deliberately — the operator asked to have you *change the
selection*, not iterate on GPU code unattended. If you try one that has not
been approved, the refusal says so and names the fix. (Images are unaffected —
you may point either surface at any *filled* image slot, because only the
operator can put an image in one.)

That is the whole safety story, and it is a reach limit rather than a
permission check: WGSL runs in the WebGPU sandbox with no memory or IO escape,
and the set of backgrounds you can select is exactly the set the operator has
already chosen on their own machine. Before authoring one, **read the
`shader-designer` skill** (`skills/shader-designer.md`) — it's the playbook for
the prelude contract, the palette system, and the shape of an `fs_main`. Write
a roster line into `shaders/README.md` when you add one, so the next run knows
what's there.

## Changing a background yourself

Two verbs, and they are the only appearance commands that exist — there is no
upload verb, no delete verb, and no palette verb.

`background_list` reports every option both surfaces can show and what each is
showing right now. **Each option carries `approved`** — whether you may
apply it right now — so you can tell "I can do this" from "I have to ask" without
being refused first. Read it before you offer. Read it first: it is the only place the valid keys come
from, and it marks empty image slots as `filled: false` so you do not offer the
operator a slot with nothing in it.

`background_set` takes a `surface` — `terminal`, `home`, or `widget` (the
Time & Place card) — and a `mode`:

| `mode` | Effect |
|---|---|
| `off` | no background on that surface |
| a shader name from `background_list` | that pattern — a built-in, or a workspace one they have approved |
| `image:<slot>` | an image the operator uploaded |
| `image:<slot>+<shader>` | that image with an image-reactive shader over it |
| `default` | clear the choice — the surface goes back to what it ships with |

`default` is the only undo you have, and on the **widget** it is the only way
back at all: that card's default is a sky called `daycycle` which is bundled but
**offered in no catalog row**, so you cannot select it by name. Nothing is wrong
if `background_list` never mentions it.

```sh
./buster-claw run background_set --json '{"surface":"home","mode":"image:2+veil"}'
```

It applies **live** — every open terminal and the homepage re-render at once,
no reload and no click — and it is undone by one more call. Only the shaders
named in `background_list`'s `image_shaders` may go on the right of a `+`; any
other one is refused, and the refusal names the ones that would work.

**This changes what the operator is looking at without asking, so say what you
are doing and why.** If what you want is not in `background_list`, the answer is
to ask them for it, not to work around it.

