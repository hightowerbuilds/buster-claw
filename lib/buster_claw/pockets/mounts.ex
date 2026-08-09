defmodule BusterClaw.Pockets.Mounts do
  @moduledoc """
  The mount registry — the app's own record of which Pockets are backed by a
  directory somewhere else on the machine.

  This is the "strengthened symlink" of `daily-growth/archive/08-09-26-pockets-roadmap.md` Part IV, and the
  strength is not in the mechanism. A mount does exactly what a symlink does:
  it says *the bytes are over there*. What a symlink cannot carry is an author,
  a purpose, a permission and an off switch, and those four are the entire
  content of this module.

  ## Why this exists at all instead of `File.ln_s/2`

  Three layers of this codebase exist specifically to defeat symlinks, and they
  are right to: at the filesystem level there is no difference between the link
  the operator made on purpose and one an attacker planted, so nothing can tell
  them apart.

    * `FileManager.within?/2` canonicalizes **every** path component with
      `read_link` before its containment check.
    * `Notes` walks with `lstat` and refuses `:symlink` entries.
    * `Agent.Attachments` uses `lstat` rather than `stat` so a link is *seen* as
      a link and refused outright.

  A Pocket built on a real symlink would therefore be fought by our own security
  code on every read, and the only way to make it work would be to weaken the
  guard for everybody. **`within?/2` does not change** (roadmap D3). A mount is
  the same idea with the missing half supplied: a *declared* root, which
  `BusterClaw.Pockets` admits because it is in this list and for no other reason.

  ## Where the registry lives, and why it is `Settings`

  One row per mount in `BusterClaw.Settings` (the `app_settings` table), keyed
  `pocket_mount:<name>`, valued as a small JSON object.

  The requirement that decides this is one sentence from the roadmap:

  > **`POCKET.md` lives inside the workspace, and the agent can write files in
  > the workspace.**

  So the mount path and the `writable` flag may not live in the manifest, or in
  any file under the workspace, or in the mounted folder itself — an agent that
  can write any of those mounts a folder by editing text. That rules out every
  file-first idiom this codebase otherwise prefers (`Skills`, job descriptions,
  trusted-sender lists, `policy.md`), which is worth stating plainly because
  going against the house style needs a reason and this is it.

  What remains is app-owned state with no file behind it, and this codebase has
  exactly one of those: `Settings`. It is the right one on three counts.

    1. **It is not on the agent's map.** The agent reaches the workspace through
       file commands and a shell; it reaches the app through the command
       catalog. `Settings` is behind neither — no command in the catalog reads
       or writes a setting, and `pocket_mounts_test.exs` asserts that as a
       lockstep test rather than a hope. That is roadmap D4 (*the agent may read
       a mounted Pocket, never mount one*) enforced by structure, the same shape
       The Clinch used to separate *using* a credential from *managing* one.
    2. **There is direct precedent for exactly this data.** `Appearance` already
       keeps the background pool's slot→path pointers in `Settings` — paths the
       app resolves, deliberately kept out of the agent-editable tree.
    3. **One row per mount, so one writer per row.** Unmounting is a `delete`,
       and adding a mount can never lose another mount's record the way a
       read-modify-write of a single JSON blob can.

  ## What is recorded

  `%{name, path, writable, mounted_at}` — the four things a symlink cannot
  carry. `mounted_at` is not decoration: *who made this and when* is the first
  question anyone asks of a link into their home directory, and the filesystem
  has never been able to answer it.

  ## Read-only by default, and never unattended (D5)

  `writable` defaults to `false` and is an operator grant per mount. On top of
  it, `attended?/1` refuses write to anything that is not a human at a surface.

  **It takes two checks, not one, and the reason is a real finding rather than
  belt-and-braces.** The obvious mechanism is the caller atom
  (`:trusted | :agent_untrusted | :agent | :mcp`) that `PolicyEngine` already
  authorizes against — but that atom is derived from which API token the caller
  holds, and `Dispatcher.token_for/1` hands an unattended shift the **full**
  token whenever its queue provenance is trusted. So an unattended run can and
  does present as `:trusted`, and the caller atom alone does not mean "a human
  is watching". The second check is the app's own record of the machine's state:
  an active `Orchestration` shift flagged `unattended`.

  Both are existing mechanisms; neither is invented here. Together they are
  fail-closed in the direction D5 asks for — while an unattended shift is up,
  *nobody* writes a mounted Pocket, including the operator. That is the safe
  direction, it is coarse on purpose, and read is untouched.

  ## What this module deliberately does not do

  It does not know what a Pocket *is* — no manifest, no kind, no roles. It
  answers "is this root registered, and may this caller write to it", which is
  the whole of what `BusterClaw.Pockets` needs from it, and it keeps the
  dependency pointing one way.
  """

  require Logger

  alias BusterClaw.FileManager
  alias BusterClaw.Orchestration
  alias BusterClaw.Settings

  @prefix "pocket_mount:"

  # The same rule as a Pocket's directory name, duplicated here rather than
  # imported so this module never has to call back into `BusterClaw.Pockets`.
  # A mount key that is not a legal Pocket name can never be looked up, so the
  # two must not drift — `pocket_mounts_test.exs` asserts they agree.
  @name_re ~r/\A[a-z0-9][a-z0-9-]*\z/

  @typedoc """
  One recorded mount. `path` is absolute and expanded; `mounted_at` is an
  ISO-8601 string (stored as text, never re-parsed by anything that decides
  reach — it is provenance for a human to read).
  """
  @type t :: %{
          name: String.t(),
          path: String.t(),
          writable: boolean(),
          mounted_at: String.t() | nil
        }

  @typedoc "Why a mount was refused. Every one is returned, never raised."
  @type error ::
          :invalid_name
          | :invalid_path
          | :not_absolute
          | :not_found
          | :not_a_directory
          | :too_broad

  @doc """
  Every recorded mount, sorted by Pocket name.

  One query. A row whose JSON will not decode is logged and skipped rather than
  crashing the list — a corrupt row must degrade to "not mounted", which is the
  closed direction.
  """
  @spec list() :: [t()]
  def list do
    Settings.get_all()
    |> Enum.flat_map(fn
      {@prefix <> name, value} -> decode(name, value)
      _other -> []
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "The mount for `name`, or `:error` when that Pocket is local."
  @spec fetch(String.t()) :: {:ok, t()} | :error
  def fetch(name) when is_binary(name) do
    with :ok <- check_name(name),
         value when is_binary(value) <- Settings.get(key(name)),
         [mount] <- decode(name, value) do
      {:ok, mount}
    else
      _ -> :error
    end
  end

  def fetch(_name), do: :error

  @doc "Whether `name` is currently mounted."
  @spec mounted?(String.t()) :: boolean()
  def mounted?(name), do: match?({:ok, _}, fetch(name))

  @doc """
  Whether `root` is a directory the app has been told it may reach.

  **This is the admission decision**, and it is the only thing standing between
  a mount and an arbitrary path: a root is registered when it is at or inside
  some recorded mount's path. Containment is `FileManager.within?/2`, unchanged
  and unweakened, so the `<> "/"` boundary holds — a registered `/Users/x/Pockets`
  does not admit `/Users/x/Pockets-evil`.

  Local Pockets are not this function's business; `BusterClaw.Pockets` checks
  the workspace case first and never gets here for them.
  """
  @spec registered_root?(String.t()) :: boolean()
  def registered_root?(root) when is_binary(root) do
    Enum.any?(list(), &FileManager.within?(root, &1.path))
  end

  def registered_root?(_root), do: false

  @doc """
  Record a mount. **Operator act only** — see the moduledoc on D4.

  `opts` takes `writable: true` to grant write; it defaults to read-only, which
  is the useful case (my icons, my exports, my font library) and the safe one.

  The target must be an existing directory. A path that is a file, that does not
  exist, that is relative, or that is `/` or the home directory itself is
  refused before anything is written.

  Re-mounting a name overwrites its row, which is how the permission is changed.
  """
  @spec mount(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def mount(name, path, opts \\ []) when is_binary(name) do
    with :ok <- check_name(name),
         {:ok, dir} <- check_target(path) do
      mount = %{
        name: name,
        path: dir,
        writable: Keyword.get(opts, :writable, false) == true,
        mounted_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

      Settings.put(key(name), encode(mount))
      {:ok, mount}
    end
  end

  @doc """
  Forget a mount. **Operator act only.**

  Deletes nothing on disk — that asymmetry is the point of a recorded mount, and
  it is why unmounting and deleting a Pocket are different words. The bytes
  become unreachable through `BusterClaw.Pockets` the moment this returns,
  because the resolver re-asks `registered_root?/1` on every call and holds no
  cache.
  """
  @spec unmount(String.t()) :: :ok
  def unmount(name) when is_binary(name) do
    Settings.delete(key(name))
    :ok
  end

  def unmount(_name), do: :ok

  @doc """
  Whether `caller` is a human at a surface right now.

  `:trusted` **and** no unattended shift running. See the moduledoc for why one
  of those two is not enough: an unattended run holding the full API token
  presents as `:trusted`.
  """
  @spec attended?(atom()) :: boolean()
  def attended?(caller), do: caller == :trusted and not unattended_shift?()

  @doc """
  Whether `caller` may write into `mount`.

  The stored grant AND `attended?/1`. Anything that is not a mount — `nil`, a
  local Pocket, a stray map — is `false`; this function answers only for a
  mounted root.
  """
  @spec writable?(t() | nil | term(), atom()) :: boolean()
  def writable?(%{writable: true}, caller), do: attended?(caller)
  def writable?(_mount, _caller), do: false

  @doc """
  Whether `name` is a legal Pocket/mount name.

  Public only so the lockstep test can assert this rule and the one
  `BusterClaw.Pockets` applies to a directory name have not drifted apart.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: check_name(name) == :ok

  # --- internals ----------------------------------------------------------

  defp key(name), do: @prefix <> name

  defp check_name(name) do
    if is_binary(name) and Regex.match?(@name_re, name), do: :ok, else: {:error, :invalid_name}
  end

  # The target is checked once, here, and the *expanded* path is what gets
  # stored — so a row is never a relative path whose meaning depends on the
  # working directory of whoever reads it next.
  #
  # A symlinked root is accepted rather than refused: on macOS `~/Desktop` and
  # `~/Documents` are symlinks into `~/Library/Mobile Documents/…` under iCloud,
  # and refusing those would refuse the two folders an operator is most likely
  # to point at. It costs nothing, because `within?/2` canonicalizes both sides
  # at read time — a symlink *inside* the mount still cannot escape it, which is
  # the property that actually matters.
  defp check_target(path) when is_binary(path) do
    with {:ok, expanded} <- expand(path),
         :ok <- check_breadth(expanded) do
      case File.stat(expanded) do
        {:ok, %File.Stat{type: :directory}} -> {:ok, expanded}
        {:ok, %File.Stat{}} -> {:error, :not_a_directory}
        {:error, _reason} -> {:error, :not_found}
      end
    end
  end

  defp check_target(_path), do: {:error, :invalid_path}

  defp expand(path) do
    cond do
      path == "" or String.contains?(path, <<0>>) -> {:error, :invalid_path}
      path == "~" or String.starts_with?(path, "~/") -> {:ok, Path.expand(path)}
      Path.type(path) == :absolute -> {:ok, Path.expand(path)}
      true -> {:error, :not_absolute}
    end
  end

  # The roadmap's own risk, written down: *"operators will mount their home
  # directory because it is the easiest thing to point at, and the sandbox
  # becomes decorative."* Refusing the two roots that make it decorative costs
  # nothing real — `~/Pictures` and `~/Library/Fonts` are still one click away —
  # and it is far cheaper to hold now than to retrofit.
  defp check_breadth(expanded) do
    if expanded in ["/", FileManager.home()], do: {:error, :too_broad}, else: :ok
  end

  defp encode(mount) do
    Jason.encode!(%{
      "path" => mount.path,
      "writable" => mount.writable,
      "mounted_at" => mount.mounted_at
    })
  end

  defp decode(name, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{"path" => path} = record} when is_binary(path) and path != "" ->
        [
          %{
            name: name,
            path: path,
            writable: Map.get(record, "writable") == true,
            mounted_at: string_or_nil(Map.get(record, "mounted_at"))
          }
        ]

      _other ->
        Logger.warning("Pockets.Mounts: ignoring unreadable mount row for #{inspect(name)}")
        []
    end
  end

  defp decode(_name, _value), do: []

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp unattended_shift? do
    match?(%{unattended: true}, Orchestration.active_shift())
  end
end
