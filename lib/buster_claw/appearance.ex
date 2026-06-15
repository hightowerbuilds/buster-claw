defmodule BusterClaw.Appearance do
  @moduledoc """
  Global appearance preferences richer than a plain `Settings` value — the
  user-uploaded terminal background images.

  Up to `max_slots/0` images live under `<workspace>/appearance/` (writable in
  both dev and the packaged release, unlike the read-only `priv/static` bundle).
  One slot is "active" and painted behind the in-app terminal. `Settings` holds
  each slot's relative path plus an `updated_at` stamp (used to cache-bust the
  served URL) and the active slot number. `BusterClawWeb.AppearanceController`
  streams a slot's bytes back to the webview.

  A single *active* image is intentional: in a split pane both terminals share one
  continuous background painted on the split container (see `SplitLive`), so only
  the active slot is ever rendered behind the terminal.
  """

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Settings

  @max_slots 5
  @active_key "terminal_background_active"
  @subdir "appearance"
  @basename "terminal-background"
  @topic "appearance:terminal_background"

  # Accepted upload extensions mapped to the content-type used when serving.
  @content_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".webp" => "image/webp",
    ".gif" => "image/gif"
  }

  @doc "PubSub topic broadcast when the active terminal background changes."
  def topic, do: @topic

  @doc "How many background slots a user can fill."
  def max_slots, do: @max_slots

  @doc "Upload extensions accepted by the picker (`allow_upload` `:accept`)."
  def accepted_extensions, do: Map.keys(@content_types)

  @doc "Absolute path to the appearance directory under the workspace."
  def dir, do: Path.join(Artifact.workspace_root(), @subdir)

  @doc "Content-type for a stored image path, by extension."
  def content_type(path) do
    ext = path |> Path.extname() |> String.downcase()
    Map.get(@content_types, ext, "application/octet-stream")
  end

  @doc """
  All slots as `[%{slot: n, url: served_url | nil, filled: bool, active: bool}]`
  for `1..max_slots`, in order.
  """
  def slots do
    active = active_slot()

    for n <- 1..@max_slots do
      url = slot_url(n)
      %{slot: n, url: url, filled: not is_nil(url), active: n == active}
    end
  end

  @doc "Served URL (with cache-busting stamp) for slot `n`, or `nil` when empty."
  def slot_url(n) when n in 1..@max_slots do
    if slot_present?(n) do
      "/appearance/terminal-background/#{n}?v=#{Settings.get(stamp_key(n), "0")}"
    end
  end

  def slot_url(_), do: nil

  @doc "Absolute path to slot `n`'s image if present, else `nil` (controller-facing)."
  def slot_image(n) when n in 1..@max_slots, do: slot_abs_path(n)
  def slot_image(_), do: nil

  @doc "The active slot number (`1..max_slots`) or `nil` when none is set/present."
  def active_slot do
    case Integer.parse(Settings.get(@active_key, "")) do
      {n, ""} when n in 1..@max_slots -> if slot_present?(n), do: n, else: nil
      _ -> nil
    end
  end

  @doc "The lowest empty slot number, or `nil` when every slot is filled."
  def next_empty_slot, do: Enum.find(1..@max_slots, &(not slot_present?(&1)))

  @doc "Served URL of the *active* background (terminal/split), or `nil`."
  def terminal_background_url do
    case active_slot() do
      nil -> nil
      n -> slot_url(n)
    end
  end

  @doc """
  Save an uploaded image into `slot`. `src_path` is a readable file (e.g. a
  LiveView upload temp path); `client_name` supplies the extension. The first
  image saved becomes active. Returns `{:ok, url}`, `{:error, :unsupported_type}`,
  or `{:error, :invalid_slot}`.
  """
  def put_terminal_background(slot, src_path, client_name) when slot in 1..@max_slots do
    ext = client_name |> Path.extname() |> String.downcase()

    case Map.has_key?(@content_types, ext) do
      true ->
        File.mkdir_p!(dir())
        # Drop any prior image in this slot (possibly a different extension).
        clear_slot_files(slot)
        dest = Path.join(dir(), slot_basename(slot) <> ext)
        File.cp!(src_path, dest)

        Settings.put(path_key(slot), Path.relative_to(dest, Artifact.workspace_root()))
        Settings.put(stamp_key(slot), stamp())

        # The first background a user adds becomes the active one.
        if is_nil(active_slot()), do: Settings.put(@active_key, Integer.to_string(slot))

        broadcast()
        {:ok, slot_url(slot)}

      false ->
        {:error, :unsupported_type}
    end
  end

  def put_terminal_background(_slot, _src, _name), do: {:error, :invalid_slot}

  @doc """
  Make `slot` the active background (it must be filled). Returns `{:ok, url}` or
  `{:error, :empty_slot}`.
  """
  def set_active_slot(slot) when slot in 1..@max_slots do
    case slot_abs_path(slot) do
      nil ->
        {:error, :empty_slot}

      _abs ->
        Settings.put(@active_key, Integer.to_string(slot))
        broadcast()
        {:ok, slot_url(slot)}
    end
  end

  def set_active_slot(_), do: {:error, :empty_slot}

  @doc """
  Remove `slot`'s image. If it was the active slot, the lowest remaining filled
  slot becomes active (or none, when all slots are now empty).
  """
  def clear_slot(slot) when slot in 1..@max_slots do
    was_active = active_slot() == slot
    clear_slot_files(slot)
    Settings.delete(path_key(slot))
    Settings.delete(stamp_key(slot))

    if was_active do
      case next_filled_slot() do
        nil -> Settings.delete(@active_key)
        n -> Settings.put(@active_key, Integer.to_string(n))
      end
    end

    broadcast()
    :ok
  end

  def clear_slot(_), do: :ok

  # --- internals ---

  defp slot_basename(n), do: "#{@basename}-#{n}"
  defp path_key(n), do: "terminal_background_#{n}_path"
  defp stamp_key(n), do: "terminal_background_#{n}_updated_at"

  defp slot_rel(n), do: present(Settings.get(path_key(n)))

  defp slot_present?(n), do: not is_nil(slot_rel(n))

  # File-checked absolute path — used only when actually serving the bytes, so a
  # stored path whose file has gone missing 404s instead of being served.
  defp slot_abs_path(n) do
    with rel when is_binary(rel) <- slot_rel(n),
         abs = Path.join(Artifact.workspace_root(), rel),
         true <- File.regular?(abs) do
      abs
    else
      _ -> nil
    end
  end

  defp next_filled_slot, do: Enum.find(1..@max_slots, &slot_present?(&1))

  defp clear_slot_files(slot) do
    Enum.each(accepted_extensions(), fn ext ->
      File.rm(Path.join(dir(), slot_basename(slot) <> ext))
    end)
  end

  defp broadcast do
    Phoenix.PubSub.broadcast(
      BusterClaw.PubSub,
      @topic,
      {:terminal_background, terminal_background_url()}
    )
  end

  defp stamp, do: Integer.to_string(System.system_time(:second))

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value
end
