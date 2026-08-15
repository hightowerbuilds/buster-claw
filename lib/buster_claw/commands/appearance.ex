defmodule BusterClaw.Commands.Appearance do
  @moduledoc """
  The `background_*` command surface — the model changes what is *behind* the
  terminal it is speaking from, and behind the homepage (DMG review B1, the
  sibling of the `terminal_theme_*` palette work).

  Two verbs and no more: read what exists and what each surface is showing, then
  point one surface at one option. `BusterClaw.Appearance` owns the catalog, the
  image pool, the mode grammar and every refusal; this module turns those answers
  into wire-shaped maps and turns the refusals into sentences.

  ## One verb, not a family, because the surfaces are a table

  `Appearance` is written against a `@surfaces` table rather than per-surface, so
  `home` and `terminal` differ only by configuration. A `terminal_background_set`
  plus a `home_background_set` would re-introduce per-surface code at the one
  layer that had none, and a third surface would need a third verb. `surface` is
  an argument, and `Appearance.surfaces/0` is what it is checked against — so a
  surface added there is reachable here the same day, with no edit.

  ## Everything goes through `set_background/2`

  The mode grammar is `off` / a shader name / `image:<slot>` /
  `image:<slot>+<shader>`, and the interesting half of it is what it *refuses*:
  an empty slot, a shader that would not react to the image it was laid over, a
  contact shaderface, an unknown name. None of that is re-derived here. Writing
  the `Settings` key directly, or deciding locally what a valid mode looks like,
  creates a **second definition of a valid background** — and there is a live
  example of what that costs: the tile-badge bug fixed in `089494e` came from a
  mode string that matched no catalog tile.

  So this module reads `Appearance` and calls `Appearance.set_background/2`, and
  nothing else. `test/buster_claw/commands/appearance_test.exs` holds that with a
  name-blind reach list read from the compiler's own record of what this module
  calls: a `Settings.put` appearing here fails it, whatever it is named.

  ## No announce step, unlike the palette verbs

  `terminal_theme_*` has to announce every write, because the selected palette
  lives in the operator's browser and the server never knows it. A background
  does not work that way: it is stored server-side, and `set_background/2`
  broadcasts on the surface's topic itself, so open terminals and the homepage
  re-render live off the write. A second push from here would be a second way to
  say the same thing, and the two could disagree.

  ## What this surface cannot do

  It cannot add an image and it cannot write a shader. `background_set` selects
  from `Appearance.options/0` — the pool the operator filled in Settings and the
  `shaders/*.wgsl` they wrote — and there is no verb at any tier that uploads to
  the pool or authors a shader file. That is the containment behind the
  `:restricted` tier: the worst an unattended run can do is show the operator
  something the operator already put on their own machine, visibly, reversibly,
  and without touching a file.

  ## Refusals are sentences

  Every atom `set_background/2` can return is spelled out with the fix in it —
  an empty slot names the slots that *are* filled and says images arrive from
  Settings, a non-reactive overlay names the shaders that would react, an unknown
  mode restates the grammar and lists the keys that exist right now. A caller
  that cannot read a refusal cannot correct it, and an unattended run has nobody
  to interpret `inspect/1` output for it.
  """

  alias BusterClaw.Appearance

  # ---------------------------------------------------------------------------
  # What exists, and what is on screen
  # ---------------------------------------------------------------------------

  @doc """
  Every option both surfaces can be set to, plus what each surface is showing.

  Unlike `terminal_theme_list`, the current state *is* reported and can be: a
  background is stored server-side rather than in the operator's browser. The
  reported mode is the **resolved** one — a stored mode whose shader file was
  deleted or whose image slot was cleared degrades to the surface's default on
  read, and this reports what would actually render, not what is in the store.
  """
  def background_list(_args \\ %{}) do
    {:ok,
     %{
       surfaces: Enum.map(Appearance.surfaces(), &surface_entry/1),
       options: Enum.map(Appearance.options(), &option_entry/1),
       image_shaders: Appearance.image_shader_options(),
       max_images: Appearance.max_images()
     }}
  end

  # ---------------------------------------------------------------------------
  # Pointing a surface at an option
  # ---------------------------------------------------------------------------

  @doc """
  Point one surface at one option, live.

  Both arguments are checked by the thing that owns them: `surface` against
  `Appearance.surfaces/0`, and `mode` by `Appearance.set_background/2`, which is
  the only place in the app that decides what a valid background is. The reply
  carries the **resolved** background rather than an echo of the mode, so a
  caller sees the shape it actually got — an `image:<slot>+<shader>` comes back
  as an `image_shader`, which is two things rendering, not one.
  """
  def background_set(%{"surface" => surface, "mode" => mode})
      when is_binary(surface) and is_binary(mode) do
    with {:ok, resolved} <- fetch_surface(surface),
         {:ok, _key} <- set(resolved, mode) do
      {:ok, Map.put(surface_entry(resolved), :applied, true)}
    end
  end

  def background_set(_args), do: {:error, missing_args()}

  defp set(surface, mode) do
    case Appearance.set_background(surface, mode) do
      {:ok, key} -> {:ok, key}
      {:error, reason} -> {:error, refusal(reason, mode)}
    end
  end

  # A string is matched against the surfaces that exist rather than converted to
  # an atom: `String.to_atom/1` on wire input leaks the atom table, and
  # `to_existing_atom/1` would happily accept any atom the app has ever compiled
  # (`:sound`, `:pockets`) and hand it to a function whose guard would then
  # FunctionClauseError. The list is the allowlist.
  defp fetch_surface(name) do
    case Enum.find(Appearance.surfaces(), &(Atom.to_string(&1) == name)) do
      nil -> {:error, unknown_surface(name)}
      surface -> {:ok, surface}
    end
  end

  # ---------------------------------------------------------------------------
  # Shaping
  # ---------------------------------------------------------------------------

  defp surface_entry(surface) do
    background = Appearance.background(surface)

    %{
      surface: Atom.to_string(surface),
      label: Appearance.surface_label(surface),
      # `option_key/1` and not `catalog_key/1`: this is what round-trips back
      # through `background_set`, so it carries the whole mode including any
      # overlay. `catalog_key/1` answers a different question (which tile is in
      # use) and is the picker's, not the wire's.
      mode: Appearance.option_key(background),
      kind: Atom.to_string(background.kind),
      shader: background.shader,
      slot: background.slot,
      image_url: background.image_url
    }
  end

  # `filled` is reported for every option, including the empty image slots, so a
  # model can tell "slot 4 is not a background yet" from "there is no slot 4" —
  # the empty ones are catalogued (the picker shows them as placeholders) and are
  # never valid targets.
  defp option_entry(option) do
    %{
      key: option.key,
      kind: Atom.to_string(option.kind),
      label: option.label,
      filled: option.filled
    }
  end

  # ---------------------------------------------------------------------------
  # Refusals, as sentences
  # ---------------------------------------------------------------------------

  defp refusal(:empty_slot, mode) do
    "There is nothing in #{slot_phrase(mode)}, so no surface can be pointed at it. " <>
      "Images are uploaded by the operator in Settings → Appearance; no command adds one. " <>
      filled_slots_sentence()
  end

  defp refusal(:not_image_reactive, mode) do
    "#{overlay_phrase(mode)} does not sample the background image, so laying it over one " <>
      "would draw a plain pattern with the image nowhere — the pairing is refused rather " <>
      "than half-applied. " <>
      image_shaders_sentence() <>
      " Or use the image on its own: " <>
      "drop the +shader and set #{image_only(mode)}."
  end

  defp refusal(:invalid_mode, mode) do
    "\"#{mode}\" is not a background this app can show. A mode is one of: off; a shader " <>
      "name; image:<slot>; or image:<slot>+<shader> for an image with an image-reactive " <>
      "shader over it. A contact shaderface (face, face-*) is never a background, and a " <>
      "shader file that has been deleted stops being one. " <> available_keys_sentence()
  end

  defp refusal(reason, _mode) when is_atom(reason) do
    "That background was refused: #{String.replace(Atom.to_string(reason), "_", " ")}. " <>
      "Call background_list for the options that exist right now."
  end

  defp refusal(reason, _mode) when is_binary(reason), do: reason

  defp refusal(_reason, _mode) do
    "That background was refused, and the reason did not survive being reported. " <>
      "Call background_list and set one of the keys it reports as filled."
  end

  defp unknown_surface(name) do
    "There is no surface called \"#{name}\". The surfaces that carry a background are: " <>
      Enum.map_join(Appearance.surfaces(), ", ", &"#{&1} (#{Appearance.surface_label(&1)})") <>
      "."
  end

  defp missing_args do
    "background_set needs a surface and a mode, both strings — e.g. surface: terminal, " <>
      "mode: veil. Surfaces: " <>
      Enum.map_join(Appearance.surfaces(), ", ", &Atom.to_string/1) <>
      ". " <> available_keys_sentence()
  end

  # --- the parts of a sentence that have to be looked up ---------------------

  defp available_keys_sentence do
    case Enum.filter(Appearance.options(), & &1.filled) do
      [] ->
        "background_list reports the options that exist."

      options ->
        "The keys that exist right now: " <> Enum.map_join(options, ", ", & &1.key) <> "."
    end
  end

  defp filled_slots_sentence do
    case Enum.filter(Appearance.images(), & &1.filled) do
      [] -> "The image pool is empty right now, so no image: mode will be accepted."
      images -> "Slots holding an image: " <> Enum.map_join(images, ", ", & &1.key) <> "."
    end
  end

  defp image_shaders_sentence do
    case Appearance.image_shader_options() do
      [] -> "No shader available right now reacts to an image."
      shaders -> "Shaders that DO react to an image: " <> Enum.join(shaders, ", ") <> "."
    end
  end

  # `mode` reached these only by being refused, so every one of them degrades to
  # a vague-but-true phrase rather than assuming its own shape parsed.
  defp slot_phrase(mode) do
    case slot_of(mode) do
      nil -> "that image slot"
      slot -> "image slot #{slot}"
    end
  end

  defp image_only(mode), do: "image:#{slot_of(mode) || "<slot>"}"

  defp overlay_phrase(mode) do
    case overlay_of(mode) do
      nil -> "That shader"
      shader -> "The shader \"#{shader}\""
    end
  end

  defp slot_of("image:" <> rest), do: rest |> String.split("+", parts: 2) |> hd()
  defp slot_of(_mode), do: nil

  defp overlay_of("image:" <> rest) do
    case String.split(rest, "+", parts: 2) do
      [_slot, shader] -> shader
      _ -> nil
    end
  end

  defp overlay_of(_mode), do: nil
end
