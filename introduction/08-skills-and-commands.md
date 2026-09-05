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

## The terminal's command list

The desktop terminal has a flyout of one-click commands and canned **prompts**,
grouped into roles (**queue**, **toolbox**, **prompts**). It is **read-only as
of 09-05**: the Settings page that edited it and the two `terminal_command_*`
verbs were both removed. Do not offer to add or change a command there.

Skills are how new capability gets added now — a composition skill is a named
sequence of existing commands, and it shows up in the terminal's prompts role
automatically. That is the mechanism above, not this list.
