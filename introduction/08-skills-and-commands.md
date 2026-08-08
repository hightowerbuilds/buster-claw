## Skills

Beyond the native commands, Buster Claw has **skills** — file-first
capabilities that live as one markdown file each in `skills/` (git-diffable,
operator-editable, no recompile). Two kinds:

- **Composition skills** name a sequence of existing native commands as one
  move. They own no new capability — every step is re-authorised through the
  same gating as a direct call, so a skill can never exceed your trust. Run
  one with:

      ./buster-claw run <skill-name> --json '{...}'

- **Reference skills** are playbooks you *read* to do an authoring task the
  command surface doesn't cover — e.g. `shader-designer` for building homepage
  shader patterns. Read the file, then produce the artifact it describes.

See `skills/README.md` for the roster. A skill only runs when `enabled: true`.

## Editing the terminal Cmd List

The desktop terminal has a **Cmd List** (Settings → Cmd List) — a catalog of
one-click commands and canned **prompts**, grouped into roles (**queue**,
**toolbox**, **prompts**, plus any user roles). You can edit it yourself
from here — it's the same catalog a human edits in Settings:

- `terminal_command_list` (safe) — list the editable roles and each
  command's `key`, `label`, text, `kind`, and default flag. Read this first
  to get the `role_key` + `command_key`.
- `terminal_command_set` (restricted) — upsert one command/prompt by
  `role_key` + `command_key`. An existing key updates only the fields you
  pass (`command`, `label`, `description`); an unknown key carrying a
  `command` adds a new one (its `kind` is inferred — `prompt` for the
  `prompts` role or multiline text, else `shell`; shell commands stay
  single-line).

Edits run through the same validation → persist → broadcast path as the
Settings UI, land on the Sentinel audit feed, and refresh the terminal
flyout live. Two roles are **protected and refused**: `mailman` (On Duty)
and `agent-setup` (Setup wizard) — they are the shift safety surface, not a
preference.

## Command surface (CLI)

These are the commands you can run (via the `buster-claw` CLI or HTTP
API). **Safe** commands you may run directly; **restricted** commands change
state or send data and require the user's confirmation before they execute.

{{COMMAND_SURFACE}}
