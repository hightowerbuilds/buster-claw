# Skill Prompts (dynamic Prompts-role generation) Roadmap

> **Status (2026-07-05): COMPLETE.** Phase 0 (synthesis) and Phase 1 (editor
> read-only rendering) both shipped; Phase 1.5 (caching) stays deferred by design
> — negligible at this scale. The terminal `prompts` role is generated from the
> skills folder: `welcome-introduction` (static default) plus one prompt per
> enabled `skills/*.md`, synthesized at read time in `roles/0` via
> `with_skill_prompts/1` / `skill_prompt_commands/0`, never persisted
> (`generated: true`). Composition skills get a "run it" prompt; reference skills
> get a "read + do the task" prompt. Settings → Cmd List renders the generated
> prompts as read-only rows ("From your skills folder", `skills/<name>.md` badge);
> the editable form base comes from `role_edit/1` (`load/0`), which excludes them,
> so a save can never persist a stale row — and a user's own `skill-<name>` row
> shadows the generated one. Rides on the file-first cmd-list store
> (`cmd-list/catalog.json`).

*2026-07-05. Governing principle: **skills are already a file-first, runtime
layer — the Prompts flyout should mirror them, not restate them.** Adding or
removing a `skills/<name>.md` file already changes the runnable command surface
(`./buster-claw commands`) with no rebuild; the terminal Prompts role should
follow the same source of truth so a per-skill prompt appears and disappears
with its skill. The synthesis reads `BusterClaw.Skills.list/0` and injects one
prompt per enabled skill at the display layer — it never persists, so it can't
drift from the folder and there is nothing new to migrate.*

Effort tags: **S** = a sitting, **M** = a day-ish, **L** = multi-day / has unknowns.

---

## Where this sits

Two runtime layers exist today and they are **not coupled**:

- `BusterClaw.Skills` (`lib/buster_claw/skills.ex`) is fully dynamic.
  `Skills.list/0` walks `<workspace>/skills/`, loads and validates each file,
  and returns every **enabled** skill as
  `%{name, description, tier, handler_kind}` (`handler_kind` is `:composition`
  or `:reference`). Runnable composition skills also flow into
  `./buster-claw commands` via `Skills.catalog_entries/0`. No recompile.
- `BusterClaw.TerminalCommands` (`lib/buster_claw/terminal_commands.ex`) is the
  terminal cmd-list catalog — a **compile-time** `@roles` attribute merged with
  a persisted user JSON doc in `load/1` (the pure test seam) / `load/0` (reads
  `Settings`). The `prompts` role is one of these compiled roles.

The only link between them today is two hardcoded rows in `@roles`' `prompts`
group (`skill-save-note`, `skill-shader-designer`) added on 07-05. They restate
the two skills that happen to exist right now; add a third skill and no prompt
appears until someone edits and recompiles the catalog. This roadmap wires the
Prompts role to `Skills.list/0` so that coupling is automatic.

**Why not just keep editing `@roles`:** a hardcoded prompt per skill duplicates
the skills folder into compiled code and rots the moment a skill is added,
removed, renamed, or disabled. It also can't reflect a skill that a user drops
into their own workspace — the whole point of the file-first skills layer.

## Design — synthesis at the display layer, never persisted

The synthesized skill prompts are **generated, not stored**. This keeps them
from drifting from `skills/*.md` and avoids a migration or a new persisted
shape.

- **Placement.** The pure merge `load/1` stays pure (the moduledoc guarantees it
  as a disk-IO-free test seam — `Skills.list/0` does disk IO, so it must not go
  there). Synthesis happens in a thin runtime layer that wraps the merged
  catalog: a new `with_skill_prompts/1` applied inside `roles/0` (and therefore
  `menu_roles/0`, which already derives from it). Every consumer that reads
  `roles/0`/`menu_roles/0` — the flyout, `role/1`, the CLI — then sees the
  skill prompts, while `load/1` unit tests stay pure.
- **What gets injected.** For each `Skills.list/0` entry, one `prompts` command:
  - `key`: `skill-<name>` (already slug-safe — skill names are `[a-z0-9-]`).
  - `label`: `Skill — <Humanized Name>`.
  - `description`: the skill's own `description`.
  - `kind`: `:prompt`.
  - `command` (the prompt text), templated by `handler_kind`:
    - **composition** → a "run it" prompt: read `skills/<name>.md`, gather the
      declared `args`, and run `./buster-claw run <name> --json '{…}'`, then
      report the result.
    - **reference** → a "read + do the task" prompt: read `skills/<name>.md` in
      full, then produce the artifact it describes.
  - a `generated: true` marker (new optional field on the runtime command shape)
    so the editor and any consumer can tell a synthesized row from a shipped or
    user one.
- **Dedup / override precedence.** If a persisted user command (or a shipped
  built-in) already owns key `skill-<name>`, the user/built-in row **wins** and
  no synthesized row is added for that name. This gives a zero-UI override path:
  a user who wants to reword a skill's prompt adds their own `skill-<name>` row
  in Settings → cmd-list and it shadows the generated one.
- **Ordering.** `welcome-introduction` (the static default) first, then
  synthesized skill prompts in `Skills.list/0` order (already name-sorted), then
  any user-only prompts.
- **Disabled skills.** `Skills.list/0` already filters to `enabled: true`, so a
  disabled or invalid skill produces no prompt — matching the enable gate.

## Editor interaction (Settings → cmd-list)

Synthesized rows are not persisted, so the cmd-list editor must not treat them
as editable state it can save. Recommended: render generated skill prompts in
the `prompts` role **read-only**, with a small "auto from `skills/<name>.md`"
note (mirroring the protected-role lock affordance, but per-row and for a
different reason). The escape hatch is the dedup rule above — add a
`skill-<name>` row of your own to override. This keeps the editor honest (it
never persists a row that would immediately be shadowed or go stale) without a
new "virtual row" editing mode.

## Performance / caching

`roles/0` is read on every flyout render and several CLI paths; `Skills.list/0`
does a directory listing plus a frontmatter parse per file. At today's scale
(two skill files) this is negligible. If the skills folder grows or profiling
shows churn, cache `Skills.list/0` behind a short-lived ETS/`:persistent_term`
entry invalidated on a skills-folder change broadcast. Ship without caching
first; add only if measured.

---

## Phases

### Phase 0 — synthesis + remove the interim static rows (S)

**Goal:** the Prompts flyout shows one prompt per enabled skill, generated from
`Skills.list/0`, and the two hardcoded `skill-*` rows are gone.

- Delete the interim `skill-save-note` and `skill-shader-designer` commands from
  the `prompts` group in `@roles` (`terminal_commands.ex`). Keep
  `welcome-introduction` as the static default.
- Add `TerminalCommands.skill_prompt_commands/0` — calls `Skills.list/0`, maps
  each entry to a synthesized `%Command`-shaped map (`generated: true`), applies
  the composition/reference template.
- Add `with_skill_prompts/1` that, given the merged role list, appends the
  synthesized prompts to the `prompts` role, skipping any `skill-<name>` key
  already present (user/built-in wins). Wire it into `roles/0` so
  `menu_roles/0`, `role/1`, and CLI consumers inherit it. Leave `load/1` pure.
- Extend the runtime command shape with an optional `generated: false` field
  (defaulted in `normalize_builtin_command/1` / user normalizers) so nothing
  else has to special-case it.

**Files:** `lib/buster_claw/terminal_commands.ex` (remove 2 rows, add
`skill_prompt_commands/0` + `with_skill_prompts/1`, wire `roles/0`, add
`generated` field). Templates for the two prompt kinds live here as module
attributes.

**Tests:** `test/buster_claw/terminal_commands_test.exs` —
- with a fixture skills dir holding one composition + one reference skill,
  `roles/0`'s `prompts` group contains `skill-<comp>` and `skill-<ref>` with the
  right kind text and `generated: true`.
- a disabled/invalid skill yields no prompt.
- a persisted user `skill-<name>` row shadows the generated one (no duplicate;
  user text wins).
- `load/1` stays disk-IO-free (no `Skills` call) — synthesis only shows up via
  `roles/0`.
- regression: `welcome-introduction` remains the default and renders (the
  existing `terminal_live_test.exs` assertion).

### Phase 1 — editor read-only rendering for generated rows (S)

**Goal:** Settings → cmd-list shows generated skill prompts without letting the
user persist a row that would go stale.

- In `CmdListLive`, render `prompts` rows where `generated: true` as read-only
  (no `<.input>` bindings, no delete), with an "auto from `skills/<name>.md`"
  note and a link/hint to override by adding a same-key row.
- Ensure `save_role` never serializes a generated row into the persisted doc
  (filter `generated: true` before building the catalog document), so a save
  from a page that shows generated rows is a no-op for them.

**Files:** `lib/buster_claw_web/live/cmd_list_live.ex`,
`test/buster_claw_web/live/cmd_list_live_test.exs` (generated rows render
read-only; saving the prompts role does not persist generated rows; an explicit
same-key override still persists and shadows).

### Phase 1.5 — caching (S, optional / deferred)

Add a short-lived cache for `Skills.list/0` invalidated on a skills-folder
change broadcast, only if profiling shows `roles/0` is hot enough to matter.
Deferred until measured.

---

## Outstanding — to-complete checklist (as of 07-05, not started)

1. **Phase 0** — remove interim rows; `skill_prompt_commands/0`,
   `with_skill_prompts/1`, wire `roles/0`, `generated` field + normalizer
   defaults; composition/reference prompt templates.
2. **Phase 0 tests** — synthesis (comp + ref), disabled-skill exclusion,
   user-override shadowing, `load/1` purity, `welcome-introduction` regression.
3. **Phase 1** — editor read-only rendering of generated rows; `save_role`
   filters generated rows.
4. **Phase 1 tests** — generated rows read-only, not persisted on save, explicit
   override round-trip.
5. **Quality gate** — `mix precommit` / `mix lint` clean; existing
   `terminal_commands_test.exs`, `terminal_live_test.exs`, and
   `cmd_list_live_test.exs` still green.

## Decisions needed from Luke

- **Both kinds, or composition only?** Plan generates a prompt for *reference*
  skills too (read + do the task, e.g. shader-designer). Want reference skills
  included, or only runnable composition skills?
- **Override precedence.** Plan lets a user's own `skill-<name>` row shadow the
  generated one (zero-UI override). Prefer that, or make generated rows fully
  fixed (no override)?
- **Editor treatment.** Plan renders generated rows read-only with an "auto from
  skills/…" note. OK, or hide them from the editor entirely and only show them
  in the live flyout?
- **Prompt voice.** Should the generated composition prompt actually *run* the
  skill (`./buster-claw run <name> …`), or just *explain/prepare* it and wait
  for confirmation? (Runnable composition skills are already gated per step, but
  restricted ones prompt on execution.)
- **`welcome-introduction`.** Keep it as the static default prompt above the
  generated skill prompts, or fold it in / drop it?
