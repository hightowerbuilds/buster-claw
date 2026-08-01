defmodule BusterClaw.Appearance do
  @moduledoc """
  Backgrounds for the two surfaces that have one — the **homepage** and the
  **terminal** — drawn from a single shared catalog.

  There is one pool of options (`options/0`): `off`, the built-in WebGPU shader
  designs, any workspace `shaders/*.wgsl` the user has written, and up to
  `max_images/0` uploaded images living in `<workspace>/appearance/` (writable in
  both dev and the packaged release, unlike the read-only `priv/static` bundle).
  Each surface independently points at one option. In Settings → Appearance the
  catalog is shown **once** and the user drags an option onto the Homepage or
  Terminal target; the same option may back both at the same time.

  ## Storage

  Per surface, `Settings` holds a mode, a custom-palette flag, and the palette.
  The mode is `"off"`, a shader name, or `"image:<slot>"` — one grammar for both
  surfaces. The image pool is separate from either surface: each slot stores a
  workspace-relative path plus an `updated_at` stamp, so deleting an image is a
  pool operation that both surfaces then degrade away from.

  Images were once stored per surface (five terminal slots plus a single,
  separate homepage file). `ensure/0` migrates that layout into the shared pool
  in place — it rewrites `Settings` keys only and never touches the files, so an
  older on-disk name keeps working under its new slot.

  A change broadcasts on the surface's topic (`topic/1`) so open terminals and
  the homepage re-render live. `BusterClawWeb.AppearanceController` streams a
  slot's bytes back to the webview.
  """

  require Logger

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Settings
  alias BusterClaw.Shaders

  @max_images 8
  @subdir "appearance"
  @image_basename "background"

  @builtin_shaders ~w(smoke waves mandel weather)
  @default_colors ["#0e0e0e", "#ff4d1c", "#f4f1ea"]

  @shader_labels %{
    "smoke" => "Smoke",
    "waves" => "Waves",
    "mandel" => "Mandelbrot",
    "weather" => "Weather"
  }

  # The two surfaces that carry a background. Everything below is written against
  # this table rather than per-surface: one code path, two configurations.
  @surfaces %{
    home: %{
      mode_key: "home_background_mode",
      custom_key: "home_background_custom",
      colors_key: "home_background_colors",
      topic: "appearance:home_background",
      message: :home_background,
      label: "Homepage",
      # The homepage has always drifted by default; an empty homepage reads as
      # broken, where an empty terminal reads as plain.
      default: "smoke"
    },
    terminal: %{
      mode_key: "terminal_background_mode",
      custom_key: "terminal_background_custom",
      colors_key: "terminal_background_colors",
      topic: "appearance:terminal_background",
      message: :terminal_background,
      label: "Terminal",
      default: "off"
    }
  }

  # Accepted upload extensions mapped to the content-type used when serving.
  @content_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".webp" => "image/webp",
    ".gif" => "image/gif"
  }

  @migrated_key "appearance_image_pool_migrated"

  @doc "The surfaces that have a background, in display order."
  def surfaces, do: [:home, :terminal]

  @doc "Human label for a surface (`:home` -> \"Homepage\")."
  def surface_label(surface), do: config(surface).label

  @doc "PubSub topic broadcast when `surface`'s background changes."
  def topic(surface), do: config(surface).topic

  @doc "PubSub topic for the terminal background (legacy alias of `topic(:terminal)`)."
  def topic, do: topic(:terminal)

  @doc "PubSub topic for the homepage background (legacy alias of `topic(:home)`)."
  def home_topic, do: topic(:home)

  @doc "How many images the shared pool holds."
  def max_images, do: @max_images

  @doc "Upload extensions accepted by the picker (`allow_upload` `:accept`)."
  def accepted_extensions, do: Map.keys(@content_types)

  @doc "Absolute path to the appearance directory under the workspace."
  def dir, do: Artifact.workspace_path(@subdir)

  @doc "Built-in shader design names."
  def builtin_shaders, do: @builtin_shaders

  @doc "Built-in shader names (legacy alias of `builtin_shaders/0`)."
  def home_shaders, do: @builtin_shaders

  @doc "Content-type for a stored image path, by extension."
  def content_type(path) do
    ext = path |> Path.extname() |> String.downcase()
    Map.get(@content_types, ext, "application/octet-stream")
  end

  @doc """
  Names of valid workspace shader patterns (`shaders/*.wgsl`), excluding any that
  collide with a built-in name (the built-in wins) and excluding contact
  shaderfaces (`face` / `face-*`) — a contact's face is never offered as a
  background, though the reverse (a background as a face) is fine.
  """
  def custom_shaders do
    Enum.reject(Shaders.list(), &(&1 in @builtin_shaders or Shaders.face?(&1)))
  end

  # --- the catalog ---------------------------------------------------------

  @doc """
  Every option a surface can be set to, in display order: `off`, the built-in
  shaders, the workspace shaders, then the image pool (filled slots first, then
  the empty ones so the grid keeps a stable shape).

  Each entry is `%{key, kind: :off | :shader | :image, label, url, slot, filled}`.
  `key` is what `set_background/2` takes and what the drag payload carries. Only
  an image carries a `url` — a shader is named, not pictured: the catalog shows
  no thumbnail for one, because the only honest preview of a shader is the
  shader, and that runs in the surface containers.
  """
  def options do
    [%{key: "off", kind: :off, label: "Off", url: nil, slot: nil, filled: true}] ++
      Enum.map(@builtin_shaders, &shader_option/1) ++
      Enum.map(custom_shaders(), &shader_option/1) ++
      images()
  end

  defp shader_option(name) do
    %{
      key: name,
      kind: :shader,
      label: Map.get(@shader_labels, name, humanize(name)),
      url: nil,
      slot: nil,
      filled: true
    }
  end

  defp humanize(name) do
    name
    |> String.replace("-", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc """
  The image pool as `[%{key, kind: :image, label, url, slot, filled}]` for
  `1..max_images`, filled slots first. An empty slot is included (as a
  placeholder tile) but is never a valid `set_background/2` target.
  """
  def images do
    {filled, empty} =
      1..@max_images
      |> Enum.map(&image_option/1)
      |> Enum.split_with(& &1.filled)

    filled ++ empty
  end

  defp image_option(slot) do
    url = image_url(slot)

    %{
      key: "image:#{slot}",
      kind: :image,
      label: "Image #{slot}",
      url: url,
      slot: slot,
      filled: not is_nil(url)
    }
  end

  @doc "Served URL (with a cache-busting stamp) for image `slot`, or `nil` when empty."
  def image_url(slot) when slot in 1..@max_images do
    if abs = image_abs_path(slot) do
      "/appearance/image/#{slot}?v=#{file_stamp(abs, stamp_key(slot))}"
    end
  end

  def image_url(_slot), do: nil

  @doc "Absolute path to `slot`'s image if present, else `nil` (controller-facing)."
  def image_path(slot) when slot in 1..@max_images, do: image_abs_path(slot)
  def image_path(_slot), do: nil

  @doc "The lowest empty slot number, or `nil` when the pool is full."
  def next_empty_slot, do: Enum.find(1..@max_images, &(not image_present?(&1)))

  @doc "Whether every slot in the pool is filled."
  def pool_full?, do: is_nil(next_empty_slot())

  # --- reading a surface ---------------------------------------------------

  @doc """
  The resolved background for `surface` as
  `%{kind, mode, shader, source_url, image_url, slot, custom, colors, custom_shader}`.

  `kind` is `:none | :shader | :image`; `mode` is the legacy-shaped
  `"off" | <shader> | "image"` the homepage template keys off. `source_url`
  (`/shaders/<name>`) is set only for a workspace shader — built-ins are bundled
  and need no fetch. `custom`/`colors` carry the optional palette and are
  meaningful only for a shader. This is the single source of truth the terminal
  and homepage render from, and the payload broadcast on `topic/1`.

  A stale stored mode (a shader file since deleted, an image slot since cleared)
  degrades to the surface's default rather than rendering nothing.
  """
  def background(surface) do
    palette = %{custom: custom?(surface), colors: colors(surface)}

    base =
      case resolve_mode(surface) do
        {:shader, name} ->
          %{
            kind: :shader,
            mode: name,
            shader: name,
            source_url: if(name in @builtin_shaders, do: nil, else: "/shaders/#{name}"),
            image_url: nil,
            slot: nil,
            custom_shader: name not in @builtin_shaders
          }

        {:image, slot} ->
          %{
            kind: :image,
            mode: "image",
            shader: nil,
            source_url: nil,
            image_url: image_url(slot),
            slot: slot,
            custom_shader: false
          }

        :off ->
          %{
            kind: :none,
            mode: "off",
            shader: nil,
            source_url: nil,
            image_url: nil,
            slot: nil,
            custom_shader: false
          }
      end

    Map.merge(base, palette)
  end

  @doc "The resolved terminal background (legacy alias of `background(:terminal)`)."
  def terminal_background, do: background(:terminal)

  @doc "The resolved homepage background (legacy alias of `background(:home)`)."
  def home_background_state, do: background(:home)

  @doc "Served URL of the image behind the terminal, or `nil` when it isn't an image."
  def terminal_background_url, do: background(:terminal).image_url

  @doc """
  The resolved mode string for `surface`: `off`, a shader name, or `image:<n>`.
  """
  def background_mode(surface), do: option_key(background(surface))

  @doc """
  The catalog option key a resolved background corresponds to — the inverse of
  `set_background/2`, used to mark which tiles are currently in use.
  """
  def option_key(%{kind: :none}), do: "off"
  def option_key(%{kind: :shader, shader: name}), do: name
  def option_key(%{kind: :image, slot: slot}), do: "image:#{slot}"

  # Resolve the stored mode against what actually exists right now. Anything
  # stale (a removed shader file, a cleared image slot, an unparseable value)
  # falls back to the surface's default — and the default itself is verified, so
  # a home default of "smoke" can't resolve to a shader that isn't there.
  defp resolve_mode(surface) do
    stored = present(Settings.get(config(surface).mode_key))

    case classify(stored) do
      :unknown -> classify_default(surface)
      resolved -> resolved
    end
  end

  defp classify_default(surface) do
    case classify(config(surface).default) do
      :unknown -> :off
      resolved -> resolved
    end
  end

  defp classify(nil), do: :unknown
  defp classify("off"), do: :off
  defp classify(mode) when mode in @builtin_shaders, do: {:shader, mode}

  defp classify("image:" <> slot) do
    case Integer.parse(slot) do
      {n, ""} -> if image_present?(n), do: {:image, n}, else: :unknown
      _ -> :unknown
    end
  end

  defp classify(mode) when is_binary(mode) do
    # A workspace shader. Shaderfaces are refused here, not just in the picker —
    # a face stored as a mode (set before faces were fenced off) degrades.
    if not Shaders.face?(mode) and Shaders.exists?(mode), do: {:shader, mode}, else: :unknown
  end

  defp classify(_mode), do: :unknown

  # --- writing a surface ---------------------------------------------------

  @doc """
  Point `surface` at an option `key`: `"off"`, a shader name, or `"image:<slot>"`
  (the slot must be filled). Returns `{:ok, key}`, `{:error, :empty_slot}`, or
  `{:error, :invalid_mode}`.
  """
  def set_background(surface, key) when is_map_key(@surfaces, surface) and is_binary(key) do
    case classify(key) do
      :unknown -> {:error, invalid_reason(key)}
      _resolved -> put_mode(surface, key)
    end
  end

  def set_background(_surface, _key), do: {:error, :invalid_mode}

  # An "image:<n>" that didn't classify failed because the slot is empty, which
  # is worth telling the user apart from a name we don't recognize at all.
  defp invalid_reason("image:" <> _), do: :empty_slot
  defp invalid_reason(_key), do: :invalid_mode

  defp put_mode(surface, key) do
    Settings.put(config(surface).mode_key, key)
    broadcast(surface)
    {:ok, key}
  end

  @doc "Whether a custom palette overrides `surface`'s shader colors."
  def custom?(surface), do: Settings.get(config(surface).custom_key, "false") == "true"

  @doc "Toggle `surface`'s custom palette on/off."
  def set_custom(surface, on) when is_boolean(on) do
    Settings.put(config(surface).custom_key, to_string(on))
    broadcast(surface)
    :ok
  end

  @doc "`surface`'s 3 custom palette colors as `[hex, hex, hex]` (defaults if unset)."
  def colors(surface) do
    with s when is_binary(s) <- Settings.get(config(surface).colors_key),
         [_, _, _] = cs <- String.split(s, ",", trim: true) do
      cs
    else
      _ -> @default_colors
    end
  end

  @doc "Set `surface`'s 3 custom palette colors (each `#rrggbb`). Bad values fall to black."
  def set_colors(surface, colors) when is_list(colors) do
    cleaned = colors |> Enum.map(&sanitize_hex/1) |> Enum.take(3)

    if length(cleaned) == 3 do
      Settings.put(config(surface).colors_key, Enum.join(cleaned, ","))
      broadcast(surface)
      {:ok, cleaned}
    else
      {:error, :invalid}
    end
  end

  # --- the image pool ------------------------------------------------------

  @doc """
  Save an uploaded image into the lowest empty slot. `src_path` is a readable
  file (e.g. a LiveView upload temp path); `client_name` supplies the extension.
  Returns `{:ok, slot}`, `{:error, :unsupported_type}`, or `{:error, :pool_full}`.

  Adding an image never changes what either surface is showing — the user drags
  it onto a target to use it.
  """
  def put_image(src_path, client_name) do
    ext = client_name |> Path.extname() |> String.downcase()

    cond do
      not Map.has_key?(@content_types, ext) ->
        {:error, :unsupported_type}

      slot = next_empty_slot() ->
        File.mkdir_p!(dir())
        # Drop any prior file in this slot (possibly a different extension).
        clear_image_files(slot)
        dest = Path.join(dir(), image_basename(slot) <> ext)
        File.cp!(src_path, dest)

        Settings.put(path_key(slot), Path.relative_to(dest, Artifact.workspace_root()))
        Settings.put(stamp_key(slot), stamp())
        {:ok, slot}

      true ->
        {:error, :pool_full}
    end
  end

  @doc """
  Remove `slot`'s image from the pool. Any surface pointing at it degrades to
  that surface's default (rather than silently jumping to some other image the
  user didn't choose), and re-broadcasts.
  """
  def clear_image(slot) when slot in 1..@max_images do
    users = Enum.filter(surfaces(), &(background(&1).slot == slot))

    clear_image_files(slot)
    Settings.delete(path_key(slot))
    Settings.delete(stamp_key(slot))

    # Rewrite each affected surface to its default explicitly. `resolve_mode/1`
    # would already degrade a dangling "image:<n>" on read, but leaving the stale
    # value stored means a slot later refilled would silently light up again on a
    # surface the user had long since stopped pointing there.
    Enum.each(users, fn surface ->
      Settings.put(config(surface).mode_key, config(surface).default)
      broadcast(surface)
    end)

    :ok
  end

  def clear_image(_slot), do: :ok

  # --- migration -----------------------------------------------------------

  @doc """
  Fold the pre-pool layout (five terminal slots + one separate homepage image)
  into the shared pool. Idempotent, best-effort, and file-preserving: only
  `Settings` keys are rewritten, so an image keeps its old name on disk and
  simply answers to a pool slot now.
  """
  def ensure do
    if Settings.get(@migrated_key) in [nil, ""] do
      migrate_terminal_slots()
      migrate_home_image()
      Settings.put(@migrated_key, "1")
    end

    :ok
  rescue
    error ->
      Logger.warning("Appearance.ensure failed: #{Exception.message(error)}")
      :error
  end

  # Terminal slots 1..5 keep their numbers in the pool — the mode becomes an
  # explicit "image:<n>" pointing at whichever slot was active.
  defp migrate_terminal_slots do
    Enum.each(1..5, fn n ->
      case present(Settings.get("terminal_background_#{n}_path")) do
        nil ->
          :ok

        path ->
          Settings.put(path_key(n), path)
          Settings.put(stamp_key(n), Settings.get("terminal_background_#{n}_updated_at", stamp()))
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

  # The homepage image had no slot of its own; it lands in the first free one.
  defp migrate_home_image do
    case present(Settings.get("home_background_image_path")) do
      nil ->
        :ok

      path ->
        case next_empty_slot() do
          nil ->
            Logger.warning("Appearance.ensure: pool full, homepage image not migrated")

          slot ->
            Settings.put(path_key(slot), path)

            Settings.put(
              stamp_key(slot),
              Settings.get("home_background_image_updated_at", stamp())
            )

            if present(Settings.get("home_background_mode")) == "image",
              do: Settings.put("home_background_mode", "image:#{slot}")
        end
    end

    Settings.delete("home_background_image_path")
    Settings.delete("home_background_image_updated_at")
  end

  # --- internals -----------------------------------------------------------

  defp config(surface) when is_map_key(@surfaces, surface), do: Map.fetch!(@surfaces, surface)

  defp image_basename(n), do: "#{@image_basename}-#{n}"
  defp path_key(n), do: "background_image_#{n}_path"
  defp stamp_key(n), do: "background_image_#{n}_updated_at"

  defp image_rel(n), do: present(Settings.get(path_key(n)))

  defp image_present?(n) when n in 1..@max_images, do: not is_nil(image_abs_path(n))
  defp image_present?(_n), do: false

  # File-checked absolute path — used only when actually serving the bytes, so a
  # stored path whose file has gone missing 404s instead of being served. The
  # `within_dir?/1` guard stops a tampered Settings `rel` (with `..` or an
  # absolute path) from escaping the appearance dir.
  defp image_abs_path(n) do
    with rel when is_binary(rel) <- image_rel(n),
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

  # Delete the file this slot actually points at (a migrated slot may still carry
  # its pre-pool name), then sweep the canonical names for every accepted
  # extension. Both are fenced to the appearance dir.
  defp clear_image_files(slot) do
    if abs = image_abs_path(slot), do: File.rm(abs)

    Enum.each(accepted_extensions(), fn ext ->
      File.rm(Path.join(dir(), image_basename(slot) <> ext))
    end)
  end

  defp broadcast(surface) do
    cfg = config(surface)

    Phoenix.PubSub.broadcast(
      BusterClaw.PubSub,
      cfg.topic,
      {cfg.message, background(surface)}
    )
  end

  defp sanitize_hex(hex) do
    h = hex |> to_string() |> String.trim()
    if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, h), do: String.downcase(h), else: "#000000"
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
