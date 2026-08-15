defmodule BusterClaw.Appearance.Migration do
  @moduledoc """
  One-way upgrades of stored `Settings` keys for installs that predate the
  shared background image pool.

  **This module exists to be deleted.** Every function here serves installs
  older than 08-08 and does nothing on a fresh one; when the last such install
  is gone, `rm` this file and the three calls in `BusterClaw.Appearance.ensure/0`.
  It was split out of `Appearance` on 08-14 for exactly that reason — the code is
  dead weight on every read of a module that is otherwise about *current*
  behaviour.

  ## Why the arguments look like this

  Every function takes its `Settings` key names rather than building them. That
  is not ceremony, it is the only shape that works:

  * `Appearance` owns the key formats (`path_key/1`, `stamp_key/1`). Calling back
    for them would make `Appearance ↔ Appearance.Migration` a dependency cycle,
    and `scripts/check_cycles.sh` fails on a third cycle by design.
  * Rebuilding the formats here instead would put two copies of a `Settings` key
    string in the tree, which is the failure this repo keeps re-finding — a
    format that drifts on one side and breaks silently on the other.

  So the dependency runs one way, `Appearance → Migration`, and the key formats
  keep exactly one home.

  ## The ordering constraint, which now spans a module boundary

  `rewrite_renamed_dir/2` **must** run before the pool migration, and the reason
  is not obvious: `Appearance.next_empty_slot/0` file-checks each slot through a
  fence rooted at the current directory, so a pointer still carrying an old
  prefix fails that fence and its slot reads as *empty*. Migrate before
  rewriting and a second image lands on top of an occupied slot.

  `Appearance.ensure/0` calls these in the right order. Because that order is now
  a fact about a caller rather than about one function body, it is written here
  as well — a constraint you can only see from one side is a constraint that gets
  broken from the other.
  """

  require Logger

  alias BusterClaw.Settings

  # This directory has moved TWICE: `appearance/` → `backgrounds/` (a content
  # rename) → `pockets/backgrounds/` (a pile of the operator's images is a
  # Pocket). `Workspace.ensure/0` moves the files, and it boots before this.
  #
  # Cheap and idempotent by shape: a pointer already under `pockets/backgrounds/`
  # matches neither old prefix and is left alone.
  @old_prefixes ["appearance/", "backgrounds/"]

  @doc """
  Repoint any stored image path that still carries a pre-rename directory
  prefix at `subdir`.

  `keys` is every `Settings` key that can hold such a path — the pool's own, and
  the legacy pre-pool keys too, so an install crossing every migration in one
  launch is repaired in a single pass.

  Idempotent. See the moduledoc on why this runs before anything else.
  """
  def rewrite_renamed_dir(keys, subdir) when is_list(keys) and is_binary(subdir) do
    Enum.each(keys, fn key ->
      with rel when is_binary(rel) <- present(Settings.get(key)),
           {:ok, rest} <- strip_old_prefix(rel) do
        Settings.put(key, Path.join(subdir, rest))
      else
        _ -> :ok
      end
    end)
  end

  defp strip_old_prefix(rel) do
    Enum.find_value(@old_prefixes, :error, fn prefix ->
      case rel do
        ^prefix <> rest -> {:ok, rest}
        _ -> nil
      end
    end)
  end

  @doc """
  Fold the five old terminal background slots into the pool, keeping their
  numbers.

  `slot_keys` is `[{n, path_key, stamp_key}]` for the slots to carry over. The
  mode becomes an explicit `"image:<n>"` pointing at whichever slot was active.
  """
  def migrate_terminal_slots(slot_keys) when is_list(slot_keys) do
    Enum.each(slot_keys, fn {n, path_key, stamp_key} ->
      case present(Settings.get("terminal_background_#{n}_path")) do
        nil ->
          :ok

        path ->
          Settings.put(path_key, path)
          Settings.put(stamp_key, Settings.get("terminal_background_#{n}_updated_at", stamp()))
      end

      Settings.delete("terminal_background_#{n}_path")
      Settings.delete("terminal_background_#{n}_updated_at")
    end)

    active = present(Settings.get("terminal_background_active"))
    mode = present(Settings.get("terminal_background_mode"))

    # An unset mode meant "image" when a slot was active (the pre-shader
    # behavior), so infer it rather than dropping the user's background.
    if mode in [nil, "image"] and active,
      do: Settings.put("terminal_background_mode", "image:#{active}")

    Settings.delete("terminal_background_active")
  end

  @doc """
  Move the old standalone homepage image into `slot`, which the caller resolves
  *after* `migrate_terminal_slots/1` has run — the homepage image had no slot of
  its own and lands in the first one still free.

  `slot` is `nil` when the pool is already full, which is logged and skipped
  rather than overwriting somebody's image. The stale keys are cleared either
  way, so a full pool does not leave the migration permanently half-done.
  """
  def migrate_home_image(slot, path_key, stamp_key) do
    case present(Settings.get("home_background_image_path")) do
      nil ->
        :ok

      path ->
        put_home_image(slot, path, path_key, stamp_key)
    end

    Settings.delete("home_background_image_path")
    Settings.delete("home_background_image_updated_at")
  end

  defp put_home_image(nil, _path, _path_key, _stamp_key) do
    Logger.warning("Appearance.ensure: pool full, homepage image not migrated")
  end

  defp put_home_image(slot, path, path_key, stamp_key) do
    Settings.put(path_key, path)
    Settings.put(stamp_key, Settings.get("home_background_image_updated_at", stamp()))

    if present(Settings.get("home_background_mode")) == "image",
      do: Settings.put("home_background_mode", "image:#{slot}")
  end

  # Value helpers, not shared formats — duplicated from `Appearance` on purpose.
  # A `present/1` in two modules cannot drift into a bug the way a Settings key
  # string can; roughly ten modules in this tree carry their own already.
  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value
  defp present(_value), do: nil

  defp stamp, do: Integer.to_string(System.system_time(:second))
end
