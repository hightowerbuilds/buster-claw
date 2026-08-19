defmodule BusterClaw.Seed do
  @moduledoc """
  Seeded workspace defaults that can be **upgraded without destroying the
  operator's edits** — the mechanism `UPDATE_ROADMAP` `G-44` describes.

  ## The problem this replaces

  The house seeding idiom was `maybe_write/2`: write the default if the file does
  not exist, otherwise do nothing. That is correct as far as it goes — it is what
  stops an update from overwriting a file the operator has spent time on — but its
  consequence is that **every shipped default is frozen at install time, forever.**
  Ship a better default and nobody who already installed ever receives it.

  It stopped being a design note on 08-18. BusterPhone became intake-only and
  `sms_send` left the command catalog, which meant every existing workspace was
  holding a seeded job prompt instructing the agent to run **a command that no
  longer exists**. Not a stale default — a broken one.

  ## The mechanism

  Each seed declares every version of itself ever shipped, as sha256 digests,
  oldest first. On boot:

    * file missing → write it (`:created`)
    * bytes match the current default → nothing to do (`:current`)
    * bytes match **any earlier shipped version** → the operator never touched it,
      so it is safe to replace (`:upgraded`)
    * anything else → it is theirs (`:kept`)

  The comparison is bytes, not timestamps, because a timestamp says when a file
  changed and not whether the change was ours or theirs.

  ## Why digests rather than the full prior text

  `G-44` says the app "must retain" the previous defaults to compare against.
  Retaining their **digests** is sufficient for the only question being asked —
  *is this file unmodified?* — and costs 64 bytes per version instead of a
  document. The tradeoff is real and worth naming: with digests the app cannot
  show the operator a diff of what it would have changed. It can only say that it
  declined. If a future surface wants to show the diff, this is the decision to
  revisit.

  ## Fails safe, in one direction only

  An unrecognised digest is always treated as **the operator's**. So the failure
  mode of a forgotten version entry is "a file that could have upgraded didn't" —
  never "a file the operator wrote got destroyed." That asymmetry is deliberate,
  and it is why the version lists are guarded by a test rather than by care: see
  `BusterClaw.SeedTest`, which pins each current digest so that editing a default
  without appending its new digest fails the build.
  """

  require Logger

  @type outcome :: :created | :current | :upgraded | :kept | :error

  @doc """
  Reconcile one seeded file against its shipped defaults.

  `versions` is every digest this seed has ever shipped, oldest first, with the
  **current** default's digest last. Returns `{:ok, outcome}`.

  Best-effort like the seeding it replaces: an unreadable or unwritable path is
  logged and reported, never raised. Boot must not fail because a workspace file
  is odd.
  """
  @spec write(Path.t(), binary(), [String.t()]) :: {:ok, outcome()}
  def write(path, content, versions) when is_binary(content) and is_list(versions) do
    if File.exists?(path) do
      reconcile(path, content, versions)
    else
      create(path, content)
    end
  end

  @doc "Lowercase hex sha256 of `content` — the identity a seed version is known by."
  @spec digest(binary()) :: String.t()
  def digest(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp create(path, content) do
    case File.write(path, content) do
      :ok ->
        {:ok, :created}

      {:error, reason} ->
        Logger.warning("Seed: could not create #{path}: #{inspect(reason)}")
        {:ok, :error}
    end
  end

  defp reconcile(path, content, versions) do
    case File.read(path) do
      {:ok, on_disk} ->
        classify(path, on_disk, content, versions)

      {:error, reason} ->
        Logger.warning("Seed: could not read #{path}: #{inspect(reason)}")
        {:ok, :error}
    end
  end

  defp classify(path, on_disk, content, versions) do
    on_disk_digest = digest(on_disk)

    cond do
      on_disk_digest == digest(content) ->
        {:ok, :current}

      on_disk_digest in versions ->
        upgrade(path, content, on_disk_digest)

      true ->
        # Deliberately `info`, not `warning`. A customized seed is the system
        # working — the operator made it theirs — and a warning every boot for
        # normal use trains people to ignore the log. It is still said out loud,
        # because `G-44`'s requirement is that the app names what it declined to
        # update, and a silent decline is how an install quietly runs last year's
        # defaults forever.
        Logger.info(
          "Seed: kept #{Path.basename(path)} — it has been edited, so a newer " <>
            "shipped default was not applied"
        )

        {:ok, :kept}
    end
  end

  defp upgrade(path, content, from_digest) do
    case File.write(path, content) do
      :ok ->
        Logger.info(
          "Seed: upgraded #{Path.basename(path)} from #{String.slice(from_digest, 0, 12)} " <>
            "— it still matched a shipped default, so it was not the operator's"
        )

        {:ok, :upgraded}

      {:error, reason} ->
        Logger.warning("Seed: could not upgrade #{path}: #{inspect(reason)}")
        {:ok, :error}
    end
  end
end
