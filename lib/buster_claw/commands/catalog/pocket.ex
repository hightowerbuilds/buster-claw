defmodule BusterClaw.Commands.Catalog.Pocket do
  @moduledoc """
  Catalog entries for Pockets — the operator's own named, typed folders of media
  (POCKETS_ROADMAP Part VI Phase 4, "the agent's reach").

  **Three verbs, all reads, and deliberately no more until something wants
  more.** `pocket_list` says what exists, `pocket_describe` says what one Pocket
  is *for* and what it holds, and `pocket_read` returns the text of one file
  inside it. That is the whole surface.

  ## The absent verb is the design

  There is no entry here that creates, removes or changes a **mount** — the
  app-owned record that lets a Pocket's bytes live outside the workspace — at
  any tier, ever ([D4] of the roadmap). Recording a mount is an operator act in
  the UI, for the same reason The Clinch let a remote caller *use* a credential
  but never *manage* one: the split is structural, so no policy check has to be
  right.

  The manifest carries the same split and it is why these reads are cheap to
  trust. `POCKET.md` is a file the agent can write, so it holds *description*
  only — name, kind, description, roles. Everything that decides **reach** (where
  the bytes are, and whether they may be written) lives in a registry this
  surface cannot address. An agent editing a manifest relabels a Pocket; it can
  never move one.

  ## Why all three are `:safe`

  They open files read-only, write nothing, change no setting, and send nothing.
  `pocket_read` is the only one that returns file *contents*, and its whole
  reach is `BusterClaw.Pockets.resolve/2` — the single audited fence, which
  takes a **bare filename** rather than a path, canonicalizes the result back
  against the Pocket's own directory, and `lstat`s it so a planted symlink is
  seen and refused rather than followed. There is no second path-building code
  path here on purpose: two places that build paths is how one of them ends up
  wrong.

  And it never returns bytes it cannot read as text. A command that dumps an
  icon into a transcript has spent the operator's context on noise; images and
  fonts are described, and are *served* to a surface that can actually display
  them.
  """

  @doc "Pocket catalog entries."
  def entries,
    do: [
      %{
        name: "pocket_list",
        type: :read,
        tier: :safe,
        description:
          "Every Pocket the operator has — their own named, typed folders of media (icons, badges, banners, fonts, media, pages, or free). Each entry carries the kind, the one-line description the operator wrote, the roles it declares, how many files it holds, and whether its bytes live in the workspace (local) or in a folder the operator mounted from elsewhere. Invalid Pockets are reported SEPARATELY rather than omitted: a folder whose POCKET.md is missing or malformed is a broken Pocket, not an absent one, and telling the operator which it is the whole reason the field exists. Read this before answering anything about what media the operator has on hand.",
        args: %{}
      },
      %{
        name: "pocket_describe",
        type: :read,
        tier: :safe,
        description:
          "One Pocket in full: its kind, description, roles, where its files live, every file it holds with size and whether that file is readable as text, and — the part a plain folder has never been able to carry — the operator's own prose from below the frontmatter, which is where they said what the Pocket is FOR and how its files relate to each other. Read the body before proposing anything about a Pocket's contents; it routinely says which file is the master and which are derived. Refused with the same reason the loader gives (no_manifest, name_mismatch, invalid_name, unknown_kind, invalid_roles) when the Pocket does not load.",
        args: %{"name" => %{type: :string, required: true}}
      },
      %{
        name: "pocket_read",
        type: :read,
        tier: :safe,
        description:
          "Read one file inside a Pocket. file is a BARE filename as listed by pocket_describe — never a path: separators, .. and leading dots are refused before the filesystem is touched, and a symlink is seen and refused rather than followed, so this cannot reach outside the Pocket. Text is returned in content, truncated at 64 KB with truncated true. A BINARY file (an image, a font, an audio clip) succeeds but returns content null with text false and its size: its bytes are for a surface that can display them, not for a transcript, and describing it is the useful answer. Returns not_found for a file the Pocket does not list.",
        args: %{
          "name" => %{type: :string, required: true},
          "file" => %{type: :string, required: true}
        }
      }
    ]
end
