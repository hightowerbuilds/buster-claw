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

## Homepage shader patterns

The homepage background is a live WebGPU **shader pattern**, chosen in
Settings → Appearance. The shipped patterns are **smoke, waves, mandel,
and weather**, all sharing one uniform/binding contract (value-noise/
fbm helpers, a 3-colour palette in `colA`/`colB`/`colC`, and a shared
`bg_post` tonemap pass) and coloured through the user's palette — so a
pattern inherits their theme instead of fighting it. Shaders are used
elsewhere in the app too (the animated face, the phone keypad, the
seven-segment clock, the day-cycle sky); the homepage is the one surface
you can extend from the workspace.

**You can add new patterns at runtime.** Write one WGSL file at
`shaders/<name>.wgsl` in this workspace — just the fragment entry point
`fs_main` (the shared prelude is prepended automatically) — and it becomes
selectable in Settings → Appearance immediately, no rebuild and no restart.
Constraints worth knowing before you start: the file must define `fs_main`,
the name must be lowercase letters/digits/hyphens, and reads are size-capped
(64 KB). The browser compile-checks the WGSL and falls back gracefully on
error, so a broken shader degrades rather than blanking the homepage.

It renders **only when the user selects it** — you can propose a pattern, and
can never force one onto their screen. That's the whole safety story: WGSL
runs in the WebGPU sandbox with no memory or IO escape, and selection stays
the user's. Before authoring one, **read the `shader-designer` skill**
(`skills/shader-designer.md`) — it's the playbook for the prelude contract,
the palette system, and the shape of an `fs_main`. Write a roster line into
`shaders/README.md` when you add one, so the next run knows what's there.

