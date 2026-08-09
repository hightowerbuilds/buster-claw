defmodule BusterClaw.Pockets do
  @moduledoc """
  Loads the operator's Pockets from `<workspace>/pockets/`.

  A Pocket is one directory holding a `POCKET.md` manifest and the media it
  describes. `BusterClaw.Pocket` defines the shape and the reasoning; this module
  only finds, parses, validates and lists them.

  Discovered at runtime with no recompile, exactly like skills
  (`BusterClaw.Skills`), job descriptions and trusted-sender lists — file-first,
  git-diffable, operator-editable.

  ## Local and mounted

  A Pocket's manifest **always** lives at `<workspace>/pockets/<name>/POCKET.md`,
  even when its bytes do not. A mount moves where the *contents* are read from,
  never where the description is written — that split is the whole of roadmap
  D4/D5, because `POCKET.md` is a file the agent can write and the mount path is
  not.

  So `pocket_dir/1` is the manifest's home and `pocket.dir` is where the files
  are. They are the same directory for a local Pocket and different for a mounted
  one, and `BusterClaw.Pockets.Mounts` is the only thing that can make them
  differ. One consequence worth knowing: files sitting beside a mounted Pocket's
  manifest become invisible, because `contents/1` reads the mount.

  ## Invalid is a state, not a silence

  A malformed Pocket is logged, skipped by `list/0`, and returned by
  `list_with_errors/0` so the Home tab can show it *as invalid*. `Skills` proved
  the failure mode: skipping is right, but skipping quietly makes a broken folder
  look like a missing one, and the operator has no way to tell which they are
  looking at.
  """

  require Logger

  alias BusterClaw.FileManager
  alias BusterClaw.Library.{Artifact, Frontmatter}
  alias BusterClaw.Pockets.Mounts

  @subdir "pockets"
  @manifest "POCKET.md"

  @kinds ~w(icons badges banners fonts media pages free)a
  @kind_strings Enum.map(@kinds, &Atom.to_string/1)

  # Mirrors the skill-name rule, and for the same reason: the name is used to
  # address a Pocket from a manifest, a command and a URL, so it may not contain
  # a path separator, a leading dot, or anything needing escaping.
  @name_re ~r/\A[a-z0-9][a-z0-9-]*\z/

  @doc "Absolute path to the pockets directory under the workspace."
  def dir, do: Artifact.workspace_path(@subdir)

  @doc """
  Absolute path to one Pocket's own directory under the workspace.

  This is where `POCKET.md` lives, always. It is **not** necessarily where the
  Pocket's files live — for a mounted Pocket that is `pocket.dir`, which the
  loader fills in from `BusterClaw.Pockets.Mounts`.
  """
  def pocket_dir(name) when is_binary(name), do: Path.join(dir(), name)

  @doc "Absolute path to a Pocket's manifest."
  def manifest_path(name) when is_binary(name), do: Path.join(pocket_dir(name), @manifest)

  @doc "The kinds a Pocket may declare."
  def kinds, do: @kinds

  @doc """
  The roles that currently have a consumer — a surface that asks for them.

  Deliberately short. A role is added here **when something asks for it**, not
  when someone imagines it might: an unused role is the speculative breadth that
  cost the extension mechanism its life, one name at a time.

  A Pocket may declare a role that is not on this list. It simply never binds —
  see `for_role/1`.
  """
  # `background` is Appearance's pool. The six `nav_*`/`home_banner` roles are the
  # brand slots — listed here rather than read from `BusterClaw.Pockets.Brand`,
  # which would be a dependency cycle (Brand already calls this module).
  # `BusterClaw.PocketsTest` asserts the two lists agree, so the duplication
  # cannot drift.
  def roles, do: ~w(background nav_home nav_workspace nav_browser nav_terminal
                    nav_settings home_banner)

  @doc """
  The Pocket filling `role`, or `nil`.

  Ties break by name, so the answer is stable rather than filesystem-ordered.

  **An unknown role is not an error.** A manifest may name a role no surface asks
  for yet — it stays inert until one does, and a Pocket is never refused for
  being newer than the app that reads it.
  """
  def for_role(role) when is_binary(role) do
    # A MOUNTED Pocket never fills a role — see `mount/3`. Enforced here as well
    # as there so a mount recorded *before* a manifest declared the role cannot
    # bind afterwards through the back door.
    list()
    |> Enum.filter(&(&1.binding == :local))
    |> Enum.find(&(role in &1.roles))
  end

  def for_role(_role), do: nil

  @doc """
  Resolve `filename` inside `pocket` to an absolute path the app may read, or
  `nil`.

  **This is the one function that decides reach**, and every surface that reads a
  Pocket's bytes goes through it. Mounts landed here and nowhere else, exactly as
  the Phase 1 contract promised: `FileManager.within?/2` is untouched (roadmap
  D3), and this resolver gained one guard rather than the containment layer
  losing one.

  Four guards, in order, and each defeats a different attack:

  1. `filename` must be a **bare name** — no separator, no `..`, no leading dot.
     A caller cannot ask for a path, only for a file the Pocket lists.
  2. The Pocket's root must be **admissible**: inside `<workspace>/pockets/`, or
     at/inside a root the operator explicitly registered in
     `BusterClaw.Pockets.Mounts`. Nothing else, ever. This is the guard mounts
     added, and it is what stops a `%{dir: "/etc"}` handed in by a caller — or a
     mount root that has since been revoked — from resolving to anything.
  3. The resolved path is **canonicalized and re-checked** against the Pocket's
     directory (`FileManager.within?/2`), so a symlink planted inside a Pocket
     cannot escape it. **A mount is a new root, not a hole.**
  4. It must be a **regular file**, checked with `lstat` so a symlink is seen
     rather than followed.

  Guard 2 is re-asked on every call and nothing is cached, which is why
  unmounting makes bytes unreachable the instant the row is deleted.

  Also accepts a Pocket *name*, loading it first. A Pocket that does not load
  resolves to `nil`: an unreadable manifest must never make its bytes reachable.
  """
  def resolve(%{dir: pocket_dir}, filename) when is_binary(filename) do
    with true <- bare_name?(filename),
         true <- admissible_root?(pocket_dir),
         path = Path.join(pocket_dir, filename),
         true <- FileManager.within?(path, pocket_dir),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path) do
      path
    else
      _ -> nil
    end
  end

  def resolve(name, filename) when is_binary(name) and is_binary(filename) do
    case load(name) do
      {:ok, pocket} -> resolve(pocket, filename)
      _ -> nil
    end
  end

  # LAST, and it has to be: a catch-all defined above the by-name clause
  # swallowed it, and every valid request 404'd while the fence looked correct.
  def resolve(_pocket, _filename), do: nil

  @doc """
  Served URL for one of a Pocket's files, with a cache-busting stamp, or `nil`.

  Revalidation-based caching like `AppearanceController`'s, and for the same
  reason: workspace files are shared by every instance of the app and by the
  agent, so bytes can change under a URL whose stamp some other instance minted.
  """
  def asset_url(%{name: name} = pocket, filename) do
    case resolve(pocket, filename) do
      nil ->
        nil

      path ->
        stamp =
          case File.stat(path, time: :posix) do
            {:ok, %{mtime: mtime, size: size}} -> "#{mtime}-#{size}"
            _ -> "0"
          end

        "/pockets/#{URI.encode(name)}/#{URI.encode(filename)}?v=#{stamp}"
    end
  end

  def asset_url(_pocket, _filename), do: nil

  @doc """
  Whether `caller` may WRITE bytes into `pocket`.

  Read is not asked here — `resolve/2` answers that, and it answers the same for
  every caller. This function exists for the write half only, and it is the
  contract any future write path must call rather than checking `binding`
  itself.

  - `:local` — `true`. The Pocket is inside the workspace, so writing to it is
    governed by `FileManager.within?/2` exactly as every other workspace path is.
    Claiming otherwise here would be a fence that does not exist.
  - `{:mounted, _path, writable}` — the operator's stored grant AND
    `BusterClaw.Pockets.Mounts.attended?/1`. **Read-only by default, and an
    unattended run never gets write regardless of the stored value** (roadmap
    D5). See `Mounts` for why detecting "unattended" takes two checks.

  `caller` is the same atom `BusterClaw.Commands.call/3` and `PolicyEngine` use
  (`:trusted | :agent_untrusted | :agent | :mcp`). It has **no default**: a gate
  that grants by omission is a gate someone forgets to pass an argument to.
  """
  def writable?(%{binding: :local}, _caller), do: true

  def writable?(%{binding: {:mounted, _path, writable}}, caller) do
    writable and Mounts.attended?(caller)
  end

  def writable?(_pocket, _caller), do: false

  # Guard 2 of `resolve/2`, and the whole of what mounts changed about reach.
  #
  # The workspace case is checked FIRST and answers without a query, so the
  # common path never touches the registry. Only a root outside `pockets/` costs
  # a lookup, and only a root the operator registered survives it.
  defp admissible_root?(root) when is_binary(root) do
    FileManager.within?(root, dir()) or Mounts.registered_root?(root)
  end

  defp admissible_root?(_root), do: false

  # A caller may name a file, never a path. This is checked before any join, so
  # `..` never reaches the filesystem at all.
  defp bare_name?(name) do
    name != "" and
      name == Path.basename(name) and
      not String.starts_with?(name, ".") and
      not String.contains?(name, "/")
  end

  @doc """
  Create a Pocket's directory and, if it has no manifest yet, write one.

  Never overwrites an existing `POCKET.md`: the operator's edits to their own
  Pocket outrank ours. That does mean a shipped manifest cannot be corrected by a
  later build — the app-wide seeded-defaults problem — which is exactly why the
  *app's own* assets must not be seeded this way. See the roadmap's X.5.a.
  """
  def ensure_pocket(name, fields) when is_binary(name) and is_map(fields) do
    with :ok <- check_name(name) do
      File.mkdir_p!(pocket_dir(name))
      path = manifest_path(name)

      unless File.exists?(path) do
        File.write!(path, render_manifest(name, fields))
      end

      :ok
    end
  end

  defp render_manifest(name, fields) do
    kind = fields |> Map.get(:kind, :free) |> to_string()
    description = fields |> Map.get(:description, "") |> to_string()
    roles = Map.get(fields, :roles, [])
    body = fields |> Map.get(:body, "") |> to_string()

    """
    ---
    name: #{name}
    kind: #{kind}
    description: #{description}
    roles: #{Jason.encode!(roles)}
    ---

    #{body}
    """
  end

  @doc """
  Create the pockets directory. On-demand per the workspace registry: called when
  the operator opens the surface that owns it, never at install.
  """
  def ensure do
    File.mkdir_p(dir())
    :ok
  end

  @doc "Every valid Pocket, sorted by name. Invalid ones are logged and skipped."
  def list do
    list_with_errors()
    |> Enum.flat_map(fn
      {:ok, pocket} -> [pocket]
      {:error, _name, _reason} -> []
    end)
  end

  @doc """
  Every Pocket directory found, each as `{:ok, pocket}` or
  `{:error, name, reason}`, sorted by name.

  The error arm is the whole point — see the moduledoc.
  """
  def list_with_errors do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.filter(&File.dir?(pocket_dir(&1)))
        |> Enum.map(fn name ->
          case load(name) do
            {:ok, pocket} -> {:ok, pocket}
            {:error, reason} -> {:error, name, reason}
          end
        end)

      _ ->
        []
    end
  end

  @doc """
  Load and validate one Pocket by directory name.

  Returns `{:ok, t:BusterClaw.Pocket.t/0}` or `{:error, t:BusterClaw.Pocket.error/0}`.
  """
  def load(name) when is_binary(name) do
    with :ok <- check_name(name),
         {:ok, content} <- read_manifest(name) do
      %{fields: fields, body: body} = Frontmatter.split(content)

      case validate(name, fields, body) do
        {:ok, _pocket} = ok ->
          ok

        {:error, reason} = err ->
          Logger.warning("Pockets: ignoring invalid pocket #{inspect(name)} — #{inspect(reason)}")
          err
      end
    end
  end

  def load(_name), do: {:error, :invalid_name}

  @doc """
  The files a Pocket holds, as `%{name, path, bytes}`, sorted by name.

  Reads from `pocket.dir` — the mount path for a mounted Pocket — so no caller
  has to know which case it is in. Directories and dotfiles are skipped, and so
  is the manifest itself: it describes the Pocket rather than being part of its
  contents.

  Fenced by the same admissibility guard as `resolve/2`, so an unregistered root
  lists nothing rather than listing whatever is there. A mount whose target has
  been deleted, renamed, or unmounted therefore reads as **empty** — the Pocket
  is still there and still describes itself, it simply has no contents, and
  nothing raises on the way to finding that out.
  """
  def contents(%{dir: pocket_dir}) do
    with true <- admissible_root?(pocket_dir),
         {:ok, entries} <- File.ls(pocket_dir) do
      entries
      |> Enum.sort()
      |> Enum.reject(&(&1 == @manifest or String.starts_with?(&1, ".")))
      |> Enum.flat_map(&file_entry(pocket_dir, &1))
    else
      _ -> []
    end
  end

  def contents(_pocket), do: []

  # --- internals ----------------------------------------------------------

  defp file_entry(pocket_dir, name) do
    path = Path.join(pocket_dir, name)

    # `lstat`, not `stat`: a symlink must be SEEN as a symlink and skipped rather
    # than silently followed out of the Pocket. The same call `Attachments` makes,
    # for the same reason — a mount is how a Pocket reaches outside itself, and it
    # is the only way.
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        [%{name: name, path: path, bytes: size}]

      _ ->
        []
    end
  end

  defp check_name(name) do
    if Regex.match?(@name_re, name), do: :ok, else: {:error, :invalid_name}
  end

  defp read_manifest(name) do
    case File.read(manifest_path(name)) do
      {:ok, content} -> {:ok, content}
      _ -> {:error, :no_manifest}
    end
  end

  defp validate(name, fields, body) do
    with :ok <- check_declared_name(name, fields),
         {:ok, kind} <- check_kind(fields),
         {:ok, roles} <- check_roles(fields) do
      {binding, dir} = binding_for(name)

      {:ok,
       %{
         name: name,
         kind: kind,
         description: string_field(fields, "description"),
         roles: roles,
         binding: binding,
         dir: dir,
         body: body
       }}
    end
  end

  # The reach half, and the reason it is a separate function from everything
  # above it: `fields` is `POCKET.md`, which the agent can write, and NOTHING
  # here may be read from it. The registry is the only input.
  #
  # A mount is reported even when its target has gone missing. The Pocket is
  # still mounted — that is a true and useful thing for the UI to say — and the
  # missing target shows up as empty contents rather than as a load failure.
  defp binding_for(name) do
    case Mounts.fetch(name) do
      {:ok, %{path: path, writable: writable}} -> {{:mounted, path, writable}, path}
      :error -> {:local, pocket_dir(name)}
    end
  end

  # The directory is the truth. A manifest naming something else is refused
  # rather than renamed, so a Pocket can never be addressed by two names.
  defp check_declared_name(name, fields) do
    case string_field(fields, "name") do
      "" -> :ok
      ^name -> :ok
      _ -> {:error, :name_mismatch}
    end
  end

  defp check_kind(fields) do
    case string_field(fields, "kind") do
      "" -> {:ok, :free}
      kind when kind in @kind_strings -> {:ok, String.to_existing_atom(kind)}
      other -> {:error, {:unknown_kind, other}}
    end
  end

  # `roles: ["app_icon", "badge"]` — a JSON list, which is what
  # `Frontmatter.parse_value/1` decodes. A bare `[app_icon, badge]` is not valid
  # JSON, falls through as a raw string, and is refused here rather than being
  # read as a one-role list containing punctuation.
  defp check_roles(fields) do
    case Map.get(fields, "roles") do
      nil ->
        {:ok, []}

      "" ->
        {:ok, []}

      list when is_list(list) ->
        if Enum.all?(list, &valid_role?/1),
          do: {:ok, list},
          else: {:error, :invalid_roles}

      _ ->
        {:error, :invalid_roles}
    end
  end

  # Roles stay STRINGS, and deliberately. `POCKET.md` is a file the agent can
  # write, so `String.to_atom/1` on its contents is unbounded atom creation from
  # attacker-influenced input — atoms are never garbage collected, and the table
  # is a fixed-size VM resource. Phase 2 compares against a known table, which is
  # the moment a name could safely become an atom; there is no reason for it to
  # become one before then, and none after either.
  #
  # The shape is still checked now so a manifest written today parses unchanged
  # when that table arrives.
  defp valid_role?(role), do: is_binary(role) and Regex.match?(~r/\A[a-z0-9_]+\z/, role)

  defp string_field(fields, key) do
    fields |> Map.get(key, "") |> to_string() |> String.trim()
  end
end
