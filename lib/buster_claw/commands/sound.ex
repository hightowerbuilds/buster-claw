defmodule BusterClaw.Commands.Sound do
  @moduledoc """
  The `sound_*` command surface — the Studio, addressable (STUDIO_ROADMAP Part I
  Phases 0/1 and Part III Phase A/B). Delegated to from `BusterClaw.Commands`.

  Since 10-16 (CODE_QUALITY_SWEEP Phase 6) this module is the facade: the
  library verbs live in `Commands.Sound.Library`, the editing verbs in
  `Commands.Sound.Edit`, and the helpers both need in `Commands.Sound.Shared`.
  The story below is the surface's, and it still reads top to bottom.

  The Sound Studio is the one authoring surface in this app the agent cannot
  reach. The library verbs give it eyes and nothing else: `sound_list`,
  `sound_routes`, `sound_sources` and `sound_probe` are `:safe`, read files they
  never open for writing, and touch no setting.

  `sound_import` and the four editing verbs (`sound_trim`, `sound_fade`,
  `sound_normalize`, `sound_concat`) are the verbs here that write audio, and
  every one of them writes a new *source* — none routes anything, which is why
  they are `:restricted` but not gated. Routing is the only act that changes what
  the machine does unattended.

  > **The cut-up verbs lived here until 09-19** — transcripts, the word index,
  > `sound_align`, `sound_find`, `sound_sentence`, `sound_assemble` — about half
  > this file. They were deleted with the engine under them
  > (`CUTUP_DELETION_ROADMAP`), which is now its own project. What is left is the
  > sound library, the Studio's sources, and the edits Mix is built on.

  ## The one gated verb

  `sound_apply` is the end of the walk and the only gated entry: it copies a
  studio source into the sound library and points a routing key at it, which is
  the difference between "the agent made me a sound" and "the agent changed what
  my computer does at 3am". Two refusals happen *before* anything is written —
  a key that is not in `Sound.route_keys/0`, so a typo cannot be discovered
  later as a chime that does not play, and a library name that is already taken
  or that would shadow a bundled default, because this layer overrides the
  bundled set by basename and `alarm.wav` installed here replaces the built-in
  alarm for every key that falls back to it, not only the one being routed.

  `sound_restore_defaults` is the way back, and it exists because an agent that
  has just overwritten a chime is exactly who needs one. It copies the bundled
  set into the workspace without ever overwriting, and — only when asked — clears
  the routing map so every key inherits again.

  ## The editing verbs all render to a new name

  `sound_trim`, `sound_fade`, `sound_normalize` and `sound_concat` each wrap one
  pure function in `SoundStudio` and write the result as a **new** source; an
  existing name is refused as `:name_taken` unless `overwrite: true`. Editing in
  place would destroy a recording that cannot be re-recorded, and a render to a
  new file is reviewable in a way an in-place mutation is not.

  Each returns the new name together with `duration_ms` and `peak`, beside the
  source's own — the agent cannot hear, so those two numbers are the whole of
  how it checks that a cut cut something and that a level moved.

  ## The one verb that names a file outside the sound stores

  Every other verb here takes a **basename** and resolves it against a directory
  listing, so nothing outside `sounds/` is even expressible. `sound_import` has
  to reach further — a recording lives under the Library root, in none of the
  three sound stores — and `sound_probe` follows it there so the workflow is
  *probe it, then import it* rather than *import blind, then probe*.

  That reach is deliberately the narrowest thing that works: a path
  **relative to the Library root**. `under_library/1` is the whole boundary — absolute paths, `..`
  and null bytes are refused before the filesystem is touched, and the expanded
  result is re-checked against the root. There is no second line of defence
  behind it: a verb that accepted an absolute path would let an agent read
  anything this app can read.

  Two things the shape of these answers is deliberately built around:

  **The library has two layers and the workspace wins.** `sounds/` overrides the
  bundled defaults *by basename* (`Sound.resolve_path/1`), so a listing that
  showed one flat set of names is how "I replaced the chime and nothing changed"
  becomes a bug report. `sound_list` therefore reports every name once, with the
  layer it resolves from and whether a bundled default is being shadowed.

  **The agent cannot hear.** `sound_probe` is its whole substitute for ears:
  format, duration, peak, and whether the file is already in the Studio's
  internal PCM16/mono/22.05 kHz format — the one fact that decides whether an
  edit needs the system decoder at all.

  Peak is the fact that needs *samples*, and an mp3 has none until something
  decodes it — so the default probe of an mp3 is blind on exactly the file
  the acceptance walk starts from. `decode: true` fixes that by running the file
  through `import_source/1` and measuring the clip that comes back. It is opt-in
  because it is a subprocess and a full decode; the header-only path stays the
  default and stays honest about what it could not answer.

  Names are basenames, never paths. Resolution goes through `Sound.path_for/1`,
  `Sound.bundled_path_for/1` and `SoundStudio.path_for/1`, each of which
  allowlists against a real directory listing, and anything carrying a separator
  is refused as `:invalid_name` before it gets that far.
  """

  alias BusterClaw.Commands.Sound.Edit
  alias BusterClaw.Commands.Sound.Library

  defdelegate sound_list(args \\ %{}), to: Library
  defdelegate sound_routes(args \\ %{}), to: Library
  defdelegate sound_sources(args \\ %{}), to: Library
  defdelegate sound_probe(args), to: Library
  defdelegate sound_delete(args), to: Library
  defdelegate sound_apply(args), to: Library
  defdelegate sound_restore_defaults(args \\ %{}), to: Library

  defdelegate sound_import(args), to: Edit
  defdelegate sound_trim(args), to: Edit
  defdelegate sound_fade(args), to: Edit
  defdelegate sound_normalize(args), to: Edit
  defdelegate sound_concat(args), to: Edit
end
