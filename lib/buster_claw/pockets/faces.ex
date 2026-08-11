defmodule BusterClaw.Pockets.Faces do
  @moduledoc """
  Contact shaderfaces, backed by **one Pocket holding every face**.

  A contact's `face_shader` column names a face; this module is the only thing
  that turns that name into bytes the `ShaderFace` hook can fetch. A contact with
  no `face_shader` is untouched by any of it — the built-in generative face
  keyed on `face_seed` still renders, and always will.

  ## Why one Pocket, not one per contact

  The first cut of this was a Pocket per contact, and the operator reversed it.
  Three reasons, recorded because the reversal is the interesting part:

  1. `Pockets.resolve/2` takes `(pocket, filename)` — it canonicalizes a **bare
     filename inside a Pocket** and `lstat`s it so a planted symlink is refused
     rather than followed. That signature exists *for* many files in one Pocket.
     A Pocket per contact would have called it as `(pocket, the_one_file)` and
     paid the whole cost of the design for none of it.
  2. `BusterClaw.Pockets.Brand` is already one-Pocket-per-slot backing many
     slots, and its reasoning transfers whole rather than being adapted.
  3. Contacts are unbounded and user-created; Pockets are curated. A Pocket
     auto-created per contact inverts what a Pocket is, and would have meant a
     mount registry entry per person in the address book.

  ## Why a fixed name and not a role (the Brand D10 call, again)

  `pockets/contact-faces/` fills this and nothing else does.

  `Pockets.for_role/1` finds whichever Pocket *declares* a role, and `POCKET.md`
  is a file the agent can write — so a role-bound face Pocket would let an agent
  redirect **every contact's face at once** by writing a manifest into a
  directory it already has write access to. A fixed name closes that, exactly as
  `Pockets.Brand` closed it for the dock icons. It also means `Pockets.roles/0`
  is not edited, and the list of roles that actually have a consumer stays as
  short as its own moduledoc asks for.

  ## `<workspace>/shaders/` stays a fallback, and why

  Resolution is Pocket first, workspace second:

      face_shader          →  pockets/contact-faces/<name>.wgsl   (if present)
                           →  <workspace>/shaders/<name>.wgsl     (if present)
                           →  nil, and the generative face renders

  This is `Pockets.Brand`'s shape — operator art wins, existing art is the
  default — and it is the reason **no contact loses its face on upgrade**: every
  face picked before this module existed named a workspace shader, and every one
  of them still resolves. It also keeps the shader-designer skill's output
  (which writes to `<workspace>/shaders/`) usable as a face the moment it is
  written, with no copy step.

  A name held by both wins from the Pocket, and appears **once** in the picker.
  The two are one namespace on purpose: `face_shader` stores a bare name, so two
  entries reading `swirl` with no way to say which would be a picker that cannot
  express what it selects.

  ## `nil` for a face that has gone missing

  A `face_shader` naming something that no longer exists anywhere resolves to
  `nil` rather than to a URL that 404s. The hook falls back on a failed fetch
  either way, so this is not a correctness fix — it saves a request, and it
  means "no custom face" has one representation instead of two.

  ## The manifest-less edge, stated rather than hidden

  A `contact-faces/` folder created by hand with **no `POCKET.md`** is inert:
  `Pockets.resolve/2` refuses a Pocket that does not load, so its files could be
  listed but never served. Rather than leave that as a trap, `ensure/0` writes
  the manifest when the Phone tab opens — on-demand creation, per the workspace
  registry's rule that a directory is made when the operator opens the surface
  that owns it, never at install.
  """

  alias BusterClaw.Pockets
  alias BusterClaw.Shaders

  @pocket "contact-faces"
  @ext ".wgsl"

  @doc "The one Pocket that backs contact faces. See the moduledoc: fixed, not a role."
  def pocket_name, do: @pocket

  @doc """
  Create the faces Pocket and its manifest if they do not exist.

  Idempotent, and never overwrites an operator-edited `POCKET.md` —
  `Pockets.ensure_pocket/2` guarantees both.
  """
  def ensure do
    Pockets.ensure_pocket(@pocket, %{
      kind: :free,
      description: "WGSL shaderfaces for your contacts.",
      roles: [],
      body: """
      Drop `.wgsl` faces here — one file per face, named however you like. Each
      one shows up in the Face picker on a contact, under the name of the file
      without its extension.

      A face is the body of a `fs_main` fragment entry point; the shared prelude
      is prepended in the browser. The `shader-designer` skill writes them, and
      faces still in `../../shaders/` keep working — this folder just wins when
      both hold the same name.
      """
    })
  end

  @doc "Face names held by the Pocket, sorted. Empty when the Pocket does not load."
  def list do
    case Pockets.load(@pocket) do
      {:ok, pocket} ->
        pocket
        |> Pockets.contents()
        |> Enum.map(& &1.name)
        |> Enum.filter(&face_file?/1)
        |> Enum.map(&Path.rootname/1)
        |> Enum.sort()

      _ ->
        []
    end
  end

  @doc """
  Every face the picker may offer: the Pocket's, plus `<workspace>/shaders/`.

  De-duplicated — a name in both is one choice, resolved from the Pocket.
  """
  def choices do
    (list() ++ Shaders.list()) |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  The URL the `ShaderFace` hook fetches raw WGSL from for `name`, or `nil`.

  `nil` means "render the generative face" — see the moduledoc.
  """
  def source_url(name) when is_binary(name) do
    pocket_url(name) || workspace_url(name)
  end

  def source_url(_name), do: nil

  # --- internals ----------------------------------------------------------

  # `asset_url/2` runs the full `resolve/2` fence (bare name, admissible root,
  # canonicalized, `lstat`) and returns nil on any refusal, so a face that is a
  # symlink or a directory reads here as a face that is not there.
  defp pocket_url(name) do
    case Pockets.load(@pocket) do
      {:ok, pocket} -> Pockets.asset_url(pocket, name <> @ext)
      _ -> nil
    end
  end

  # `Shaders.exists?/1` re-reads and re-validates the file (name regex, size cap,
  # `fs_main` present), so this never points at something the shader route would
  # itself refuse.
  defp workspace_url(name) do
    if Shaders.exists?(name), do: "/shaders/#{URI.encode(name)}", else: nil
  end

  defp face_file?(name), do: name |> Path.extname() |> String.downcase() == @ext
end
