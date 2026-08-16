defmodule BusterClaw.Appearance.ShaderApproval do
  @moduledoc """
  Which workspace shaders the operator has approved for a command to apply.

  `AGENT_APPLIED_SHADERS_ROADMAP` Phase 1. `background_set` may apply a built-in
  design to any surface, but a workspace `shaders/*.wgsl` only once the operator
  has seen it — because a shader is a **file**, this workspace is writable, and
  no command can tell a file the model wrote from one the operator wrote.

  ## Keyed by content, not by name

  The store maps a shader's name to a SHA-256 of the bytes that were approved,
  and `approved?/1` re-hashes the file every time. That is the whole mechanism,
  and the reason is narrower than it first looks: **names are forgeable.**
  Approving by name alone would let a run overwrite `nebula.wgsl` with different
  contents and apply it under a name the operator had blessed — the same
  file-write shortcut that made "no command authors a shader" insufficient and
  produced the refusal this module relaxes.

  It is *not* here to police iteration. That was considered and rejected: the
  operator's ask was "change the background selection", explicitly separate from
  authoring, so the re-arm on edit is a consequence of the design rather than its
  purpose (roadmap VIII.2).

  ## The store lives outside the workspace

  In `app_settings`, not in `shaders/`. A manifest inside the workspace would be
  self-certifying and worthless — anything that can write the shader can write
  the file that vouches for it.

  ## Backfill

  Every shader present the first time this module is asked anything is approved
  at its current bytes, once, and a separate key records that it happened. Those
  files predate the question; making the operator click 22 of them buys nothing
  (roadmap VIII.3).

  The marker is its own key deliberately. "No approvals" and "never backfilled"
  are different states, and collapsing them would re-approve every shader in the
  workspace the moment an operator cleared their approvals — turning a
  revocation into a no-op.

  ## Why this is not in `Appearance`

  Two reasons, and both matter. `appearance.ex` is at its size cap. And
  `commands/appearance.ex` is held to a **name-blind reach list** plus a guard
  that greps every file under `commands/` for a settings write — so the command
  layer must reach approval through `Appearance` and must never name the store,
  even in a comment. A separate module keeps that boundary obvious rather than
  remembered.
  """

  alias BusterClaw.Settings
  alias BusterClaw.Shaders

  @approvals_key "shader_approvals"
  @backfilled_key "shader_approvals_backfilled_at"

  @doc """
  Record the current bytes of `name` as approved. Returns `{:ok, hash}`, or
  `{:error, reason}` from `Shaders.read/1` for a shader that cannot be served.

  A shader that fails validation cannot be approved, which is deliberate: the
  bytes being approved are the bytes that would render.
  """
  def approve(name) when is_binary(name) do
    with {:ok, hash} <- hash(name) do
      approvals()
      |> Map.put(name, hash)
      |> write()

      {:ok, hash}
    end
  end

  def approve(_name), do: {:error, :invalid_name}

  @doc """
  Whether `name`'s **current** contents are approved.

  False for an unknown shader, for one whose file has changed since it was
  approved, and for one that no longer reads.
  """
  def approved?(name) when is_binary(name) do
    case hash(name) do
      {:ok, current} -> Map.get(approvals(), name) == current
      {:error, _reason} -> false
    end
  end

  def approved?(_name), do: false

  @doc """
  The approval map, `%{name => hash}`, backfilling on first use.

  Public so a caller that has to report approval for a whole catalog does it with
  one read rather than one per shader.
  """
  def approvals do
    backfill()

    case Jason.decode(Settings.get(@approvals_key) || "{}") do
      {:ok, %{} = map} -> map
      # A corrupt value is treated as no approvals rather than crashing a render
      # path. It fails CLOSED: shaders stop applying by command until the
      # operator clicks one, which rewrites the key.
      _ -> %{}
    end
  end

  @doc "Forget one shader's approval. The next command call must ask again."
  def revoke(name) when is_binary(name) do
    approvals() |> Map.delete(name) |> write()
    :ok
  end

  # Approves everything in the workspace once, then stamps. Faces are skipped
  # because a shaderface is never a background — approving one would put a name
  # in the store that no surface can ever select.
  #
  # Built-ins are NOT filtered out, and that is the point of doing it here rather
  # than in `Appearance`: this module would otherwise need the built-in list,
  # which lives in `Appearance`, which delegates to this module — a compile
  # cycle for no benefit. Approving a built-in is inert: the command check
  # accepts built-ins before it ever asks about approval.
  defp backfill do
    if is_nil(Settings.get(@backfilled_key)) do
      approved =
        Shaders.list()
        |> Enum.reject(&Shaders.face?/1)
        |> Enum.reduce(%{}, fn name, acc ->
          case hash(name) do
            {:ok, hash} -> Map.put(acc, name, hash)
            {:error, _reason} -> acc
          end
        end)

      write(approved)
      Settings.put(@backfilled_key, DateTime.utc_now() |> DateTime.to_iso8601())
    end

    :ok
  end

  defp hash(name) do
    with {:ok, body} <- Shaders.read(name) do
      {:ok, :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)}
    end
  end

  defp write(map), do: Settings.put(@approvals_key, Jason.encode!(map))
end
