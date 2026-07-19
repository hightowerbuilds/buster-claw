defmodule BusterClaw.Appearance do
  @moduledoc """
  Global appearance preferences richer than a plain `Settings` value — the
  user-uploaded terminal background images.

  The terminal background is a single active choice — `terminal_background/0`
  resolves it to `off`, a **shader** (a WebGPU design, same set as the homepage,
  including custom workspace `shaders/*.wgsl`), or an **image**. Up to
  `max_slots/0` images live under `<workspace>/appearance/` (writable in both dev
  and the packaged release, unlike the read-only `priv/static` bundle) as a saved
  library; one is "active" and painted when the mode is `image`. `Settings` holds
  each slot's relative path plus an `updated_at` stamp (used to cache-bust the
  served URL), the active slot number, and the mode.
  `BusterClawWeb.AppearanceController` streams a slot's bytes back to the webview.

  A single active choice is intentional: in a split pane both terminals share one
  continuous background painted on the split container (see `SplitLive`), so only
  the one active image (or one shader) is ever rendered behind the terminal.
  """

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Settings
  alias BusterClaw.Shaders

  @max_slots 5
  @active_key "terminal_background_active"
  # The terminal background is a single active choice: `"off"`, a shader name
  # (built-in or a workspace `shaders/*.wgsl`), or `"image"` (paints the active
  # slot below). The image slots stay a saved library either way. Unset is
  # inferred for back-compat: `"image"` when a slot is active, else `"off"`.
  @term_mode_key "terminal_background_mode"
  # Optional custom 3-color palette applied to the terminal shader (mirrors the
  # homepage's), independent of the homepage's own palette.
  @term_custom_key "terminal_background_custom"
  @term_colors_key "terminal_background_colors"
  @subdir "appearance"
  @basename "terminal-background"
  @topic "appearance:terminal_background"

  # --- homepage background ---
  # The homepage background is a single choice: a named shader design or one
  # uploaded image. The mode is a plain Settings value; the (single) image reuses
  # the same file-in-<workspace>/appearance + path/stamp-in-Settings pattern as
  # the terminal slots, minus the slotting. A change broadcasts on @home_topic so
  # the open homepage re-renders live.
  @home_mode_key "home_background_mode"
  @home_image_path_key "home_background_image_path"
  @home_image_stamp_key "home_background_image_updated_at"
  @home_basename "home-background"
  @home_topic "appearance:home_background"
  @home_shaders ~w(smoke waves mandel weather)
  @home_default_mode "smoke"
  # Custom 3-color palette (one shared set, applied to the selected shader when
  # `custom` is on). Default seed = the smoke palette.
  @home_custom_key "home_background_custom"
  @home_colors_key "home_background_colors"
  @home_default_colors ["#0e0e0e", "#ff4d1c", "#f4f1ea"]

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
  def dir, do: Artifact.workspace_path(@subdir)

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
    if abs = slot_abs_path(n) do
      "/appearance/terminal-background/#{n}?v=#{file_stamp(abs, stamp_key(n))}"
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

  @doc "Served URL of the *active* image slot (terminal/split), or `nil`."
  def terminal_background_url do
    case active_slot() do
      nil -> nil
      n -> slot_url(n)
    end
  end

  @doc "Built-in shader names selectable behind the terminal (same set as the homepage)."
  def terminal_shaders, do: @home_shaders

  @doc """
  The stored terminal background mode: `\"off\"`, a shader name, or `\"image\"`.
  Unset falls back to `\"image\"` when a slot is active (preserving the pre-shader
  behavior), else `\"off\"`. A saved-but-now-invalid mode (a removed custom
  shader, or `\"image\"` with no active slot) degrades the same way.
  """
  def terminal_background_mode do
    case present(Settings.get(@term_mode_key)) do
      nil -> inferred_term_mode()
      "off" -> "off"
      "image" -> if active_slot(), do: "image", else: "off"
      mode -> if terminal_shader_mode?(mode), do: mode, else: inferred_term_mode()
    end
  end

  defp inferred_term_mode, do: if(active_slot(), do: "image", else: "off")

  # A terminal mode names a renderable shader: a built-in, or a workspace shader
  # file that isn't a contact face. `"off"`/`"image"` are not shader files, so
  # they fall through to false.
  defp terminal_shader_mode?(mode) when mode in @home_shaders, do: true

  defp terminal_shader_mode?(mode) when is_binary(mode),
    do: not Shaders.face?(mode) and Shaders.exists?(mode)

  defp terminal_shader_mode?(_mode), do: false

  @doc "Whether a custom palette overrides the terminal shader's built-in colors."
  def terminal_background_custom?, do: Settings.get(@term_custom_key, "false") == "true"

  @doc "Toggle the terminal shader's custom palette on/off."
  def set_terminal_background_custom(on) when is_boolean(on) do
    Settings.put(@term_custom_key, to_string(on))
    broadcast()
    :ok
  end

  @doc "The terminal shader's 3 custom palette colors as `[hex, hex, hex]`."
  def terminal_background_colors, do: read_colors(@term_colors_key)

  @doc "Set the terminal shader's 3 custom palette colors (each `#rrggbb`)."
  def set_terminal_background_colors(colors) when is_list(colors) do
    with {:ok, cleaned} <- put_colors(@term_colors_key, colors) do
      broadcast()
      {:ok, cleaned}
    end
  end

  @doc """
  The resolved terminal background as
  `%{kind: :none | :shader | :image, shader, source_url, image_url, custom, colors}`.

  `source_url` (`/shaders/<name>`) is set only for a custom (workspace) shader —
  built-ins are bundled and need no fetch. `custom`/`colors` carry the optional
  palette and are meaningful only for `:shader`. This is the single source of
  truth the terminal/split views render from, and the payload broadcast on
  `topic/0`.
  """
  def terminal_background do
    mode = terminal_background_mode()
    palette = %{custom: terminal_background_custom?(), colors: terminal_background_colors()}

    base =
      cond do
        terminal_shader_mode?(mode) ->
          %{
            kind: :shader,
            shader: mode,
            source_url: if(mode in @home_shaders, do: nil, else: "/shaders/#{mode}"),
            image_url: nil
          }

        mode == "image" and not is_nil(terminal_background_url()) ->
          %{kind: :image, shader: nil, source_url: nil, image_url: terminal_background_url()}

        true ->
          %{kind: :none, shader: nil, source_url: nil, image_url: nil}
      end

    Map.merge(base, palette)
  end

  @doc """
  Set the terminal background: `\"off\"`, a shader name (`terminal_shaders/0` or a
  workspace shader), or `\"image\"` (needs an active slot). Returns `{:ok, mode}`,
  `{:error, :no_image}`, or `{:error, :invalid_mode}`.
  """
  def set_terminal_background_mode("off"), do: put_term_mode("off")

  def set_terminal_background_mode("image") do
    if active_slot(), do: put_term_mode("image"), else: {:error, :no_image}
  end

  def set_terminal_background_mode(mode) when mode in @home_shaders, do: put_term_mode(mode)

  def set_terminal_background_mode(mode) when is_binary(mode) do
    # Refuse shaderfaces at the boundary — a contact's face is never wall art.
    if Shaders.exists?(mode) and not Shaders.face?(mode) do
      put_term_mode(mode)
    else
      {:error, :invalid_mode}
    end
  end

  def set_terminal_background_mode(_mode), do: {:error, :invalid_mode}

  defp put_term_mode(mode) do
    Settings.put(@term_mode_key, mode)
    broadcast()
    {:ok, mode}
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
        # Choosing an image is choosing the image background — switch the mode
        # away from any shader so the pick actually shows.
        Settings.put(@term_mode_key, "image")
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
        nil ->
          Settings.delete(@active_key)
          # No image left to fall back to; if the mode was image, turn it off
          # rather than leaving a dangling "image" that resolves to nothing.
          if terminal_background_mode() == "image", do: Settings.put(@term_mode_key, "off")

        n ->
          Settings.put(@active_key, Integer.to_string(n))
      end
    end

    broadcast()
    :ok
  end

  def clear_slot(_), do: :ok

  # --- homepage background ---

  @doc "PubSub topic broadcast when the homepage background changes."
  def home_topic, do: @home_topic

  @doc "The built-in shader design names selectable for the homepage."
  def home_shaders, do: @home_shaders

  @doc """
  Names of valid custom shader patterns (workspace `shaders/*.wgsl`), excluding
  any that collide with a built-in name (the built-in wins) and excluding
  contact shaderfaces (`face` / `face-*`) — a contact's face is never offered
  as the homepage background, though the reverse (a background as a face) is
  fine.
  """
  def custom_shaders do
    Enum.reject(Shaders.list(), &(&1 in @home_shaders or Shaders.face?(&1)))
  end

  @doc """
  Current homepage background as
  `%{mode, image_url, custom, colors, custom_shader, source_url}`.

  `mode` is a built-in shader name (`\"smoke\"` default), a **custom** shader name,
  or `\"image\"`; it falls back to the default if the saved mode is stale (a
  removed shader, or `\"image\"` with no image on disk). `custom_shader` is true
  when `mode` is a workspace shader, and `source_url` (`/shaders/<name>`) tells
  the hook where to fetch its WGSL — `nil` for built-ins/image.
  """
  def home_background_state do
    url = home_background_image_url()

    mode =
      cond do
        home_background_mode() == "off" -> "off"
        home_background_mode() == "image" and not is_nil(url) -> "image"
        home_background_mode() in @home_shaders -> home_background_mode()
        custom_shader_mode?(home_background_mode()) -> home_background_mode()
        true -> @home_default_mode
      end

    %{
      mode: mode,
      image_url: url,
      custom: home_background_custom?(),
      colors: home_background_colors(),
      custom_shader: custom_shader_mode?(mode),
      source_url: if(custom_shader_mode?(mode), do: "/shaders/#{mode}", else: nil)
    }
  end

  # A mode is a custom shader when it's neither "image" nor a built-in, isn't a
  # contact shaderface (a face stored as the mode — e.g. set before faces were
  # fenced off — degrades to the default rather than rendering), and a valid
  # workspace shader file of that name exists.
  defp custom_shader_mode?("image"), do: false
  defp custom_shader_mode?(mode) when mode in @home_shaders, do: false

  defp custom_shader_mode?(mode) when is_binary(mode) do
    not Shaders.face?(mode) and Shaders.exists?(mode)
  end

  defp custom_shader_mode?(_mode), do: false

  @doc "Whether custom palette colors override the shader's built-in defaults."
  def home_background_custom?, do: Settings.get(@home_custom_key, "false") == "true"

  @doc "Toggle custom palette colors on/off."
  def set_home_background_custom(on) when is_boolean(on) do
    Settings.put(@home_custom_key, to_string(on))
    broadcast_home()
    :ok
  end

  @doc "The 3 custom palette colors as `[hex, hex, hex]` (defaults if unset)."
  def home_background_colors, do: read_colors(@home_colors_key)

  @doc "Set the 3 custom palette colors (each a `#rrggbb` hex). Bad values fall to black."
  def set_home_background_colors(colors) when is_list(colors) do
    with {:ok, cleaned} <- put_colors(@home_colors_key, colors) do
      broadcast_home()
      {:ok, cleaned}
    end
  end

  # Shared 3-color palette storage (homepage + terminal), stored as a
  # comma-joined `#rrggbb` triple. A malformed/short stored value falls back to
  # the default palette; a bad value on write falls to black.
  defp read_colors(key) do
    with s when is_binary(s) <- Settings.get(key),
         [_, _, _] = cs <- String.split(s, ",", trim: true) do
      cs
    else
      _ -> @home_default_colors
    end
  end

  defp put_colors(key, colors) do
    cleaned = colors |> Enum.map(&sanitize_hex/1) |> Enum.take(3)

    if length(cleaned) == 3 do
      Settings.put(key, Enum.join(cleaned, ","))
      {:ok, cleaned}
    else
      {:error, :invalid}
    end
  end

  @doc "The stored homepage background mode (shader name or `\"image\"`)."
  def home_background_mode, do: Settings.get(@home_mode_key, @home_default_mode)

  @doc """
  Set the homepage background mode: a shader name from `home_shaders/0`,
  `\"image\"` (only honored when an image is present), or `\"off\"` (no shader,
  no image — the plain base background; also the graceful answer for machines
  where WebGPU misbehaves). Returns `{:ok, mode}` or
  `{:error, :invalid_mode}` / `{:error, :no_image}`.
  """
  def set_home_background_mode("off") do
    Settings.put(@home_mode_key, "off")
    broadcast_home()
    {:ok, "off"}
  end

  def set_home_background_mode("image") do
    if home_background_image_url() do
      Settings.put(@home_mode_key, "image")
      broadcast_home()
      {:ok, "image"}
    else
      {:error, :no_image}
    end
  end

  def set_home_background_mode(mode) when mode in @home_shaders do
    Settings.put(@home_mode_key, mode)
    broadcast_home()
    {:ok, mode}
  end

  def set_home_background_mode(mode) when is_binary(mode) do
    # Shaderfaces are refused here — at the boundary, not just in the picker —
    # so no caller (UI, command, or API) can put a contact's face on the wall.
    if Shaders.exists?(mode) and not Shaders.face?(mode) do
      Settings.put(@home_mode_key, mode)
      broadcast_home()
      {:ok, mode}
    else
      {:error, :invalid_mode}
    end
  end

  def set_home_background_mode(_), do: {:error, :invalid_mode}

  @doc "Served URL (cache-busted) of the homepage background image, or `nil`."
  def home_background_image_url do
    if abs = home_image_abs_path() do
      "/appearance/home-background?v=#{file_stamp(abs, @home_image_stamp_key)}"
    end
  end

  @doc "Absolute path to the homepage background image if present (controller-facing)."
  def home_background_image, do: home_image_abs_path()

  @doc """
  Save an uploaded homepage background image and switch the mode to `\"image\"`.
  Returns `{:ok, url}` or `{:error, :unsupported_type}`.
  """
  def put_home_background_image(src_path, client_name) do
    ext = client_name |> Path.extname() |> String.downcase()

    if Map.has_key?(@content_types, ext) do
      File.mkdir_p!(dir())
      clear_home_image_files()
      dest = Path.join(dir(), @home_basename <> ext)
      File.cp!(src_path, dest)

      Settings.put(@home_image_path_key, Path.relative_to(dest, Artifact.workspace_root()))
      Settings.put(@home_image_stamp_key, stamp())
      Settings.put(@home_mode_key, "image")

      broadcast_home()
      {:ok, home_background_image_url()}
    else
      {:error, :unsupported_type}
    end
  end

  @doc "Remove the homepage background image; falls back to the default shader mode."
  def clear_home_background_image do
    clear_home_image_files()
    Settings.delete(@home_image_path_key)
    Settings.delete(@home_image_stamp_key)
    if home_background_mode() == "image", do: Settings.put(@home_mode_key, @home_default_mode)
    broadcast_home()
    :ok
  end

  # --- internals ---

  defp slot_basename(n), do: "#{@basename}-#{n}"
  defp path_key(n), do: "terminal_background_#{n}_path"
  defp stamp_key(n), do: "terminal_background_#{n}_updated_at"

  defp slot_rel(n), do: present(Settings.get(path_key(n)))

  defp slot_present?(n), do: not is_nil(slot_rel(n))

  # File-checked absolute path — used only when actually serving the bytes, so a
  # stored path whose file has gone missing 404s instead of being served. The
  # `within_dir?/1` guard stops a tampered Settings `rel` (with `..` or an
  # absolute path) from escaping the appearance dir.
  defp slot_abs_path(n) do
    with rel when is_binary(rel) <- slot_rel(n),
         abs = Artifact.workspace_path(rel),
         true <- within_dir?(abs),
         true <- File.regular?(abs) do
      abs
    else
      _ -> nil
    end
  end

  # A served path must resolve inside the appearance dir; a stored `rel` that
  # normalizes outside it (via `..`/an absolute path) is rejected.
  defp within_dir?(abs) do
    base = Path.expand(dir())
    abs = Path.expand(abs)
    abs == base or String.starts_with?(abs, base <> "/")
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
      {:terminal_background, terminal_background()}
    )
  end

  defp broadcast_home do
    Phoenix.PubSub.broadcast(
      BusterClaw.PubSub,
      @home_topic,
      {:home_background, home_background_state()}
    )
  end

  defp sanitize_hex(hex) do
    h = hex |> to_string() |> String.trim()
    if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, h), do: String.downcase(h), else: "#000000"
  end

  defp home_image_abs_path do
    with rel when is_binary(rel) <- present(Settings.get(@home_image_path_key)),
         abs = Artifact.workspace_path(rel),
         true <- within_dir?(abs),
         true <- File.regular?(abs) do
      abs
    else
      _ -> nil
    end
  end

  defp clear_home_image_files do
    Enum.each(accepted_extensions(), fn ext ->
      File.rm(Path.join(dir(), @home_basename <> ext))
    end)
  end

  defp stamp, do: Integer.to_string(System.system_time(:second))

  # Cache-bust from the FILE's mtime, not the Settings stamp. The workspace is
  # shared by every instance/version of the app (and by the agent), but each
  # instance has its own settings DB — a file replaced by anyone else would
  # keep the old ?v= forever and the webview's cache would pin the stale bytes
  # (exactly the July-2026 home-background incident). The Settings stamp is
  # only the fallback when stat fails.
  defp file_stamp(abs, settings_key) do
    case File.stat(abs, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> "#{mtime}-#{size}"
      _ -> Settings.get(settings_key, "0")
    end
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value
end
