# Skills

Composition skills extend Buster Claw's command surface at runtime, with no
recompile. Each skill is one markdown file here (`<name>.md`) whose `steps`
are an ordered list of existing native commands.

## Two kinds (`handler_kind`)
- `composition` — `steps` are an ordered list of existing native commands.
  Run one with `./buster-claw run <name> --json '{...}'`. Every step is
  re-authorised, so a skill can never exceed the trust of its caller.
- `reference` — a playbook you **read** (no steps; the markdown body is the
  payload) for an authoring task the command surface doesn't cover, e.g.
  `shader-designer` for building a homepage shader pattern. Read the file,
  then produce the artifact it describes.

## Frontmatter
- `name` — must equal the filename stem (`[a-z0-9-]`).
- `description` — what it does / when to use it.
- `tier` — `safe` or `restricted` (a declared ceiling; per-step authorization
  still applies).
- `enabled` — `false` by default; a skill is only active when explicitly `true`.
- `handler_kind` — `composition` or `reference`.
- `args` — (composition) JSON map of the skill's inputs.
- `steps` — (composition) JSON array of `{"command": "<native>", "args": {...}}`,
  run in order. In step args, `$<arg>` interpolates a skill input and `$prior`
  is the previous step's result.
