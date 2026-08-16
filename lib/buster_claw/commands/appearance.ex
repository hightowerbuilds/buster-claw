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
  calls: a direct write to the settings store appearing here fails it, whatever
  it is named.

  > Written that way on purpose. The Pockets mount suite carries a D4 guard that
  > greps every file under `commands/` for a settings write or a reach into the
  > mount registry, and it greps SOURCE — it cannot tell a call from a sentence
  > describing one. Naming either function here, even to forbid it, fails that
  > guard; naming its test file does too. Do not "clarify" this back.

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

  A workspace shader narrows it further, because a shader is a file and the
  workspace is writable: a run that writes one and asks for it by name would be
  showing the operator something they never chose. `background_set` takes one
  only once the operator has approved that exact code — see `check_shader/2`.

  ## Refusals are sentences

  Every atom `set_background/2` can return is spelled out with the fix in it —
  an empty slot names the slots that *are* filled and says images arrive from
  Settings, a non-reactive overlay names the shaders that would react, an unknown
  mode restates the grammar and lists the keys that exist right now. A caller
  that cannot read a refusal cannot correct it, and an unattended run has nobody
  to interpret `inspect/1` output for it.
  """

  alias BusterClaw.Appearance

  # Read at COMPILE TIME from the one owner, because a `when` guard cannot call a
  # remote function — the same constraint `Phone.Registry` records for its tab
  # keys, and the same reason: two literals in two files drift, and this one
  # drifting would break the only undo any surface has.
  @default_mode Appearance.default_mode()

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

  Each option also carries `approved`: whether `background_set` would take it
  right now. An option can exist, be perfectly valid, and still not be applicable
  from a command — a workspace shader the operator has never looked at is that
  case — and a caller should see it here rather than by being refused.
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
    with :ok <- refuse_authored_shader(mode),
         {:ok, key} <- Appearance.set_background(surface, mode) do
      {:ok, key}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, refusal(reason, mode)}
    end
  end

  # The command surface is deliberately NARROWER than the Appearance page, and
  # this is the only place the two differ.
  #
  # `Appearance.set_background/2` accepts any option the catalog offers,
  # including a workspace `shaders/*.wgsl`. That is right for the page, because a
  # human is clicking. It is wrong for a command by default, because **authoring
  # a shader needs no command at all** — the workspace is writable, so an agent
  # can write `shaders/x.wgsl` and then ask for it by name. Left open, an
  # unattended run could put arbitrary agent-authored GPU code on the operator's
  # screen that no human had ever looked at.
  #
  # The containment argument for leaving `background_set` ungated was "no command
  # authors a shader". True, and not sufficient, because authoring is a file
  # write. Found the hour after these verbs landed, by the Shaders tutorial's own
  # claim going false (DMG-review-8-15). Images are unaffected throughout: the
  # operator put those in the pool themselves, and no command can add one.
  #
  # ## The exception, and why it does not give the property back
  #
  # A workspace shader the operator has APPROVED is accepted too: selecting a
  # pattern the operator already chose and running code written a minute ago are
  # different acts, and this is where the app draws that line. Two properties
  # keep it an exception rather than a hole:
  #
  #   * **Approval is keyed by the file's CONTENTS, not its name.**
  #     `Appearance.shader_approved?/1` re-hashes the file on every call, so
  #     overwriting `nebula.wgsl` with different code and applying it under a
  #     blessed name does not work — that is the same file-write shortcut that
  #     made "no command authors a shader" insufficient, and names are forgeable
  #     in exactly the way bytes are not. Editing an approved shader therefore
  #     re-arms the gate, as a consequence of the design and not a rule about
  #     editing.
  #   * **The record lives outside the workspace**, minted in one place: the
  #     Appearance page, when a human applies a shader. A manifest inside
  #     `shaders/` would be self-certifying — anything able to write the shader
  #     could write the file vouching for it — so nothing an agent can reach
  #     forges an approval.
  #
  # What survives is the property that was always the real one: GPU code no human
  # has looked at cannot reach the screen from a command. "A command may never
  # apply a workspace shader" was a proxy for that, and one that also refused the
  # operator's own long-standing patterns.
  #
  # Narrow on purpose, and the narrowness is the interesting part: this fires
  # ONLY for a shader that Appearance would otherwise have accepted. A
  # shaderface, a deleted file or a typo is not an authored-shader problem — it
  # is an invalid mode, and `Appearance` already has a better sentence for each.
  # Answering those here would replace a precise refusal with a vaguer one, which
  # a test caught within a minute of this check being written.
  # `default` is an instruction, not an option — it clears the surface's stored
  # choice. Skipped before the shader check because that check would otherwise
  # read it as a NAME: an operator with an unapproved `shaders/default.wgsl` in
  # their workspace would find the one undo every surface has refused, with a
  # message about approving a shader they never meant to apply. Reserving the
  # word in `Appearance` does not reserve it here; this layer has its own gate.
  defp refuse_authored_shader(@default_mode), do: :ok

  defp refuse_authored_shader(mode) do
    case shader_component(mode) do
      nil -> :ok
      name -> check_shader(name, selectable_shader?(mode, name))
    end
  end

  defp check_shader(_name, false), do: :ok

  # Built-in first, and not merely for speed: a built-in is a design that shipped
  # with the app and has no file behind it to approve, so asking about its
  # approval would be asking a question with no meaning.
  defp check_shader(name, true) do
    if name in Appearance.builtin_shaders() or Appearance.shader_approved?(name),
      do: :ok,
      else: {:error, authored_shader_refusal(name)}
  end

  # Would `Appearance` take this shader? A bare name has to be a catalog key; an
  # overlay has to be one of the designs that actually react to an image.
  defp selectable_shader?("image:" <> _rest, name),
    do: name in Appearance.image_shader_options()

  defp selectable_shader?(_mode, name),
    do: name in Enum.map(Appearance.options(), & &1.key)

  # The shader named by a mode, if any: a bare shader name, or the right-hand
  # side of `image:<slot>+<shader>`. `off` and a plain `image:<slot>` name none.
  defp shader_component("off"), do: nil

  defp shader_component("image:" <> rest) do
    case String.split(rest, "+", parts: 2) do
      [_slot] -> nil
      [_slot, shader] -> shader
    end
  end

  defp shader_component(mode), do: mode

  defp authored_shader_refusal(name) do
    "#{name} is a shader from your workspace that you have not approved, so this " <>
      "command cannot apply it yet — click it once in Settings → Appearance and " <>
      "this command works from then on. Anything with write access to the " <>
      "workspace can author a shader file, so what gets approved is the exact " <>
      "code you looked at: editing #{name} later asks for that click again. " <>
      "Built-in designs never need one: " <>
      "#{Enum.join(Appearance.builtin_shaders(), ", ")}. " <>
      "Images you uploaded are selectable too, with image:<slot>. " <>
      "background_list reports approved: true for everything applicable right now."
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
  #
  # `approved` answers a different question: not "is this a real background" but
  # "may a COMMAND put it on a surface right now". A workspace shader is
  # `filled: true` from the moment its file parses and stays unapplicable from
  # here until the operator has looked at it. Without this field a caller learns
  # that boundary only by being refused, which costs a round trip the operator
  # watches happen.
  defp option_entry(option) do
    %{
      key: option.key,
      kind: Atom.to_string(option.kind),
      label: option.label,
      filled: option.filled,
      approved: option_approved?(option)
    }
  end

  # `off` and the built-in designs are always applicable. An image is applicable
  # once something is in the slot — approval is not a question for one, since the
  # operator loaded it themselves and no command can. Only a workspace shader is
  # actually asked about.
  #
  # Asked one shader at a time, deliberately. `Appearance.approved_shaders/0`
  # answers the whole catalog in one read, but it reports the code that WAS
  # approved rather than whether the file still matches it — so a shader edited
  # since its click would come back `approved: true` here and then be refused by
  # `background_set`. That is the exact round trip this field exists to spare the
  # caller, so the cheaper read would defeat the point of reporting at all.
  # Re-hashing a couple of dozen small files beats answering wrongly.
  defp option_approved?(%{kind: :image} = option), do: option.filled

  defp option_approved?(%{kind: :shader, key: name}),
    do: name in Appearance.builtin_shaders() or Appearance.shader_approved?(name)

  defp option_approved?(_option), do: true

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
