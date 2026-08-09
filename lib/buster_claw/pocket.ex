defmodule BusterClaw.Pocket do
  @moduledoc """
  The shared shape of a Pocket — a named, typed folder of the operator's own
  media. **Types and documentation only; no logic lives here.**

  It exists because four stages have to agree on what a Pocket *is*, and they
  arrive in four different phases: the loader that reads `POCKET.md`, the role
  table that decides which Pocket fills a slot, the mount registry that may point
  a Pocket at a directory outside the workspace, and the Home tab that draws it.

  Scoped in `daily-growth/archive/08-09-26-pockets-roadmap.md`.

  ## The one rule that shapes every field below

  **The manifest holds description. It never holds permission.**

  `POCKET.md` lives inside the workspace, and the agent can write files in the
  workspace. So a mount path in the manifest would mean an agent mounts a folder
  by editing Markdown, and a `writable: true` in the manifest would mean an agent
  grants itself write access to it. Both are escapes.

  Everything in `t:manifest/0` is therefore *descriptive* — a wrong value is a
  wrong label. Everything that decides **reach** (where a Pocket's bytes actually
  live, and whether they may be written) lives in an app-owned registry the
  command surface cannot address, and appears here only as `t:binding/0`, which
  the loader fills in from that registry rather than from the file.

  That split is what makes "the agent may read a mounted Pocket, never mount one"
  true by structure instead of by a policy check — the same shape The Clinch used
  to separate *using* a credential from *managing* one.

  ## A Pocket is data. Always.

  Inherited from the deleted extension mechanism's first locked decision: a
  bundle the app interprets is never executable code, because the BEAM has no
  code sandbox. A Pocket holds images, fonts, audio, documents. It cannot run,
  so it cannot grant itself anything.
  """

  @typedoc """
  What a Pocket holds, which decides how its files are validated and displayed.

  - `:icons` — small images meant to be seen at small sizes.
  - `:badges` — status glyphs, overlaid on other UI.
  - `:banners` — wide images meant to head a page.
  - `:fonts` — typefaces, served self-hosted and same-origin.
  - `:media` — audio, video, and images with no more specific role.
  - `:pages` — an HTML/CSS/asset bundle served as a document in its own context.
    **Not a program**; see the moduledoc.
  - `:free` — anything. The escape hatch, so a Pocket is never blocked on us
    having anticipated its kind.
  """
  @type kind :: :icons | :badges | :banners | :fonts | :media | :pages | :free

  @typedoc """
  A slot a surface can ask to fill. Roles are deliberately named for **what a
  surface needs**, not for what today's folders happen to hold, because they are
  the key that user Pockets shadow the app's own defaults on.

  **A string, not an atom, and it stays one.** A role name is read from
  `POCKET.md`, which the agent can write, so interning it would be unbounded atom
  creation from attacker-influenced input — and atoms are never collected. There
  is no phase in which this needs to be an atom.

  The table of known roles is Phase 2; the shape is fixed now so a manifest
  written today parses unchanged when it arrives.
  """
  @type role :: String.t()

  @typedoc """
  The descriptive half — parsed from `POCKET.md` frontmatter, writable by the
  operator *or the agent*, and load-bearing for nothing but presentation.

  `name` must equal the directory name (`[a-z0-9][a-z0-9-]*`), the same
  constraint a skill's name has against its filename stem. It is checked rather
  than trusted: the directory is the truth, and a mismatched manifest is a
  refused Pocket, not a renamed one.
  """
  @type manifest :: %{
          name: String.t(),
          kind: kind(),
          description: String.t(),
          roles: [role()]
        }

  @typedoc """
  The half that decides reach — from the app-owned registry, **never from the
  manifest**.

  - `:local` — the Pocket's bytes live in its own directory under
    `<workspace>/pockets/`, and every existing containment guard already covers
    it. This is the only binding Phase 1 can produce.
  - `{:mounted, path, writable}` — the Pocket's bytes live at an absolute `path`
    elsewhere on the machine, recorded by the operator through the UI. `writable`
    is an operator grant that an unattended run never receives regardless of its
    value.

  The registry is `BusterClaw.Pockets.Mounts`, which keeps one row per mount in
  `BusterClaw.Settings` — app-owned state with no file behind it, so there is no
  path on the agent's map that leads to it. Its moduledoc carries the reasoning
  for that choice and for why "unattended" takes two checks rather than one.
  """
  @type binding :: :local | {:mounted, String.t(), boolean()}

  @typedoc """
  One loaded Pocket.

  `dir` is where the app reads its files from — the Pocket's own directory when
  `binding` is `:local`, the mount path when it is not. It is resolved once, by
  the loader, so no caller has to know which case it is in.

  `body` is the operator's own prose from below the frontmatter. It is carried
  rather than re-read because it is shown directly under the contents in the Home
  tab, and it is the part a plain folder has never been able to hold.
  """
  @type t :: %{
          name: String.t(),
          kind: kind(),
          description: String.t(),
          roles: [role()],
          binding: binding(),
          dir: String.t(),
          body: String.t()
        }

  @typedoc """
  Why a Pocket was refused. Every one is logged and skipped rather than raised —
  one malformed folder must never take the list down — but it is also **shown in
  the UI as invalid**, because a silently skipped Pocket is indistinguishable
  from a missing one.
  """
  @type error ::
          :no_manifest
          | :name_mismatch
          | :invalid_name
          | {:unknown_kind, String.t()}
          | :invalid_roles
end
