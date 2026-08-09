defmodule BusterClaw.Pockets.Operator do
  @moduledoc """
  The acts on a Pocket that **only a person may perform** — mounting one at a
  directory elsewhere on the machine, and unmounting it again.

  ## Why this is a separate module, and it is not tidiness

  Roadmap D4: *the agent may read a mounted Pocket, never mount one.* That is
  meant to be true **by structure**, not by a policy check, the way The Clinch
  separated *using* a credential from *managing* one.

  `BusterClaw.Commands.Pocket` calls `BusterClaw.Pockets`, and `Pockets` calls
  `BusterClaw.Pockets.Mounts` to learn a Pocket's binding. So the moment a mount
  *writer* is exposed on `Pockets`, the writer is transitively reachable from the
  command surface — and `BusterClaw.Commands.PocketTest`'s call-graph guard
  correctly fails the build. It did exactly that when these two functions were
  first written there, which is the whole reason this module exists.

  Nothing on the command surface calls this module, and nothing should. Its
  callers are the operator's own UI, and tests.

  ## Why the checks are here rather than in `Mounts`

  Both refusals below need to *load* a Pocket, and `Mounts` calling back into
  `Pockets` would be a dependency cycle (`check_cycles.sh` accepts exactly two,
  neither of them this). Composing the two modules from above costs nothing and
  keeps `Mounts` a pure registry that knows about paths and permissions and
  nothing about manifests.
  """

  alias BusterClaw.Pockets
  alias BusterClaw.Pockets.Mounts

  # Pockets the app itself writes into, which therefore cannot move outside the
  # workspace. Exactly one today.
  #
  # `BusterClaw.Appearance` stores each background slot as a WORKSPACE-RELATIVE
  # pointer and resolves it with `workspace_path/1`, so a file it can address is
  # by construction inside the workspace. Point that Pocket at a mount and every
  # slot resolves outside its own fence, reads as empty — and `appearance.ex`
  # records what happens next in its own words: *"a slot misread as empty gets a
  # second image landed on it."* The pool would quietly overwrite the operator's
  # images.
  #
  # This is a fact about that storage model, not a policy. If the pool ever
  # stores absolute paths, delete this list.
  @app_owned ~w(backgrounds)

  @doc """
  Mount a Pocket at a directory elsewhere on the machine.

  **This is the entry point the operator surface calls** — not `Mounts.mount/3`
  directly, which knows nothing about roles.

  Two refusals beyond the target checks `Mounts` already makes:

  - `:app_owned` — a Pocket the app writes into (see `@app_owned` above).
  - `:role_bound` — a Pocket declaring a role that has a live consumer. A surface
    asking for a role expects to write to what it gets back; a read-only mount
    would break it, and a writable one would put a surface's writes somewhere the
    operator chose for other reasons.

  A Pocket with no manifest yet still mounts — describe it afterwards. It cannot
  gain a role that way, because `Pockets.for_role/1` skips mounted Pockets.
  """
  def mount(name, path, opts \\ []) when is_binary(name) do
    with :ok <- check_app_owned(name),
         :ok <- check_role_bound(name) do
      Mounts.mount(name, path, opts)
    end
  end

  @doc """
  Forget a mount. Deletes nothing on disk — that asymmetry is why unmounting and
  deleting a Pocket are different words.
  """
  defdelegate unmount(name), to: Mounts

  @doc "The Pockets that may never be mounted, because the app writes into them."
  def app_owned, do: @app_owned

  defp check_app_owned(name) do
    if name in @app_owned, do: {:error, :app_owned}, else: :ok
  end

  defp check_role_bound(name) do
    case Pockets.load(name) do
      {:ok, %{roles: declared}} ->
        if Enum.any?(declared, &(&1 in Pockets.roles())),
          do: {:error, :role_bound},
          else: :ok

      _ ->
        :ok
    end
  end
end
