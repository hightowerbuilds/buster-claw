defmodule BusterClaw.Commands.AppearanceTest do
  # async: false — these verbs write app_settings rows through the shared
  # Settings store, broadcast on a global PubSub topic, and point the global
  # :workspace_root at a tmp dir. An `assert_receive` that can pick up a
  # concurrent test's broadcast is a test that passes for the wrong reason.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Appearance
  alias BusterClaw.Commands
  alias BusterClaw.Commands.Catalog

  # Everything `BusterClaw.Commands.Appearance` calls inside the BusterClaw
  # namespace, exactly. `Settings` is absent, and this list is the enforcement:
  # B1's whole constraint is that a command goes THROUGH `set_background/2`
  # rather than around it, and a name-blind reach list holds that even for a
  # writer nobody has named yet. `set_background/2` is the only writer here; the
  # rest are readers.
  @reach [
    {BusterClaw.Appearance, :background, 1},
    {BusterClaw.Appearance, :image_shader_options, 0},
    {BusterClaw.Appearance, :images, 0},
    {BusterClaw.Appearance, :max_images, 0},
    {BusterClaw.Appearance, :option_key, 1},
    {BusterClaw.Appearance, :options, 0},
    {BusterClaw.Appearance, :set_background, 2},
    {BusterClaw.Appearance, :surface_label, 1},
    {BusterClaw.Appearance, :surfaces, 0}
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "bc_cmd_appearance_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    for surface <- Appearance.surfaces() do
      Phoenix.PubSub.subscribe(BusterClaw.PubSub, Appearance.topic(surface))
    end

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp fake_image(ext \\ ".png") do
    path = Path.join(System.tmp_dir!(), "bc_cmd_src_#{System.unique_integer([:positive])}#{ext}")
    File.write!(path, "img-bytes")
    path
  end

  defp write_custom_shader(root, name) do
    dir = Path.join(root, "shaders")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, name <> ".wgsl"),
      "@fragment\nfn fs_main(in: VOut) -> @location(0) vec4<f32> { return vec4<f32>(1.0); }\n"
    )
  end

  defp surface(result, name), do: Enum.find(result.surfaces, &(&1.surface == name))

  # --- background_list ----------------------------------------------------

  test "background_list reports both surfaces and the whole shared catalog" do
    assert {:ok, result} = Commands.call("background_list", %{})

    assert Enum.map(result.surfaces, & &1.surface) == ["home", "terminal"]

    # The defaults, resolved: the homepage drifts because an empty homepage
    # reads as broken, and the terminal is plain because an empty one does not.
    assert %{mode: "smoke", kind: "shader", label: "Homepage"} = surface(result, "home")
    assert %{mode: "off", kind: "none", label: "Terminal"} = surface(result, "terminal")

    keys = Enum.map(result.options, & &1.key)
    assert "off" in keys
    assert Enum.all?(Appearance.builtin_shaders(), &(&1 in keys))
    assert Enum.count(keys, &String.starts_with?(&1, "image:")) == Appearance.max_images()
    assert result.max_images == Appearance.max_images()

    # Every image slot is catalogued and every one is empty, which is exactly
    # the distinction `filled` exists to carry: a slot that is not a background
    # yet is not the same as a slot that does not exist.
    images = Enum.filter(result.options, &(&1.kind == "image"))
    assert length(images) == Appearance.max_images()
    assert Enum.all?(images, &(&1.filled == false))

    # The overlay grammar's allowed right-hand side, named rather than implied.
    assert result.image_shaders == Appearance.image_shader_options()
    assert "veil" in result.image_shaders
  end

  test "background_list reports the RESOLVED mode, not the stored one", %{root: root} do
    write_custom_shader(root, "aurora")

    assert {:ok, _set} =
             Commands.call("background_set", %{"surface" => "terminal", "mode" => "aurora"})

    assert {:ok, before} = Commands.call("background_list", %{})
    assert %{mode: "aurora", kind: "shader"} = surface(before, "terminal")

    # The operator deletes the shader file out from under the stored mode.
    File.rm!(Path.join([root, "shaders", "aurora.wgsl"]))

    assert {:ok, after_delete} = Commands.call("background_list", %{})

    assert %{mode: "off", kind: "none"} = surface(after_delete, "terminal"),
           "a stale mode must report what would actually render, not what is in the store"
  end

  # --- background_set, the happy paths ------------------------------------

  test "background_set points the terminal at a shader and every open surface hears it" do
    assert {:ok, result} =
             Commands.call("background_set", %{"surface" => "terminal", "mode" => "waves"})

    assert result.surface == "terminal"
    assert result.mode == "waves"
    assert result.kind == "shader"
    assert result.shader == "waves"
    assert result.applied

    # No announce step, unlike the palette verbs: `set_background/2` broadcasts
    # the resolved background itself, and a second push from the command would
    # be a second way to say the same thing.
    assert_receive {:terminal_background, %{kind: :shader, shader: "waves"}}

    assert Appearance.background_mode(:terminal) == "waves"
    # The other surface is untouched — one call, one surface.
    assert Appearance.background_mode(:home) == "smoke"
  end

  test "background_set turns the homepage off — the same verb, the other surface" do
    assert {:ok, result} =
             Commands.call("background_set", %{"surface" => "home", "mode" => "off"})

    assert result.surface == "home"
    assert result.kind == "none"
    assert result.mode == "off"

    assert_receive {:home_background, %{kind: :none}}
    assert Appearance.background_mode(:home) == "off"
  end

  test "background_set takes an image, and an image with a shader over it" do
    assert {:ok, 1} = Appearance.put_image(fake_image(), "a.png")

    assert {:ok, image} =
             Commands.call("background_set", %{"surface" => "terminal", "mode" => "image:1"})

    assert image.kind == "image"
    assert image.slot == 1
    assert image.image_url =~ "/appearance/image/1"

    assert {:ok, both} =
             Commands.call("background_set", %{"surface" => "terminal", "mode" => "image:1+veil"})

    # BOTH halves render, so both are reported — and the mode round-trips whole,
    # which is why the reply carries `option_key/1` and not the tile key.
    assert both.kind == "image_shader"
    assert both.shader == "veil"
    assert both.slot == 1
    assert both.mode == "image:1+veil"
    assert Appearance.background_mode(:terminal) == "image:1+veil"
  end

  # --- background_set, every refusal Appearance can return ----------------

  test "an empty slot is refused with the slots that are filled named" do
    assert {:error, message} =
             Commands.call("background_set", %{"surface" => "terminal", "mode" => "image:3"})

    assert is_binary(message)
    assert message =~ "image slot 3"
    # The fix is not something the caller can do — say where images come from.
    assert message =~ "Settings"
    assert message =~ "pool is empty"
    refute message =~ ":empty_slot"

    assert Appearance.background_mode(:terminal) == "off"
    refute_receive {:terminal_background, _background}
  end

  test "an empty slot names the slots that DO hold an image, once any do" do
    assert {:ok, 1} = Appearance.put_image(fake_image(), "a.png")

    assert {:error, message} =
             Commands.call("background_set", %{"surface" => "home", "mode" => "image:4"})

    assert message =~ "image:1"
    refute_receive {:home_background, _background}
  end

  test "a shader that would not react to the image is refused, naming ones that would" do
    assert {:ok, 1} = Appearance.put_image(fake_image(), "a.png")

    assert {:error, message} =
             Commands.call("background_set", %{"surface" => "terminal", "mode" => "image:1+waves"})

    assert message =~ "waves"
    assert message =~ "veil"
    # And the way to get most of what was asked for.
    assert message =~ "image:1"
    refute message =~ ":not_image_reactive"

    assert Appearance.background_mode(:terminal) == "off"
    refute_receive {:terminal_background, _background}
  end

  test "an unknown mode is refused with the grammar and the keys that exist" do
    assert {:error, message} =
             Commands.call("background_set", %{"surface" => "terminal", "mode" => "dracula"})

    assert message =~ ~s("dracula")
    assert message =~ "image:<slot>+<shader>"

    for key <- ~w(off smoke veil) do
      assert message =~ key, "the refusal should name #{key} as a key that exists"
    end

    refute message =~ ":invalid_mode"
    assert Appearance.background_mode(:terminal) == "off"
  end

  test "a contact shaderface is not a background, and the refusal says so", %{root: root} do
    write_custom_shader(root, "face-ada")

    assert {:error, message} =
             Commands.call("background_set", %{"surface" => "terminal", "mode" => "face-ada"})

    assert message =~ "shaderface"
    assert Appearance.background_mode(:terminal) == "off"
  end

  test "an unknown surface names the surfaces that have a background" do
    assert {:error, message} =
             Commands.call("background_set", %{"surface" => "sidebar", "mode" => "off"})

    assert message =~ ~s("sidebar")
    assert message =~ "home"
    assert message =~ "terminal"

    # Nothing was written anywhere while working out that the surface was wrong.
    assert Appearance.background_mode(:home) == "smoke"
    assert Appearance.background_mode(:terminal) == "off"
    refute_receive {:home_background, _background}
    refute_receive {:terminal_background, _background}
  end

  test "a missing or non-string argument explains what it wanted" do
    for args <- [
          %{},
          %{"surface" => "terminal"},
          %{"mode" => "off"},
          %{"surface" => "terminal", "mode" => 3}
        ] do
      assert {:error, message} = Commands.call("background_set", args)
      assert message =~ "needs a surface and a mode"
      assert message =~ "terminal"
      assert message =~ "off"
    end
  end

  # --- the surface, and the tier it sits at -------------------------------

  describe "the catalog entry" do
    test "the surface is exactly two verbs: one safe read and one restricted write" do
      entries =
        Catalog.entries()
        |> Enum.filter(&String.starts_with?(&1.name, "background_"))
        |> Enum.sort_by(& &1.name)

      assert Enum.map(entries, & &1.name) == ["background_list", "background_set"]

      assert %{type: :read, tier: :safe} = Enum.find(entries, &(&1.name == "background_list"))

      set = Enum.find(entries, &(&1.name == "background_set"))
      assert set.type == :mutate
      assert set.tier == :restricted, ":safe would let any token repaint the machine"

      for entry <- entries do
        # Not gated, deliberately: a background writes one Settings key, touches
        # no file, sends nothing outbound, is visible the instant it happens and
        # is undone by one more call. Gating that trains the operator to click
        # through the gates that matter.
        refute Map.get(entry, :gated, false), "#{entry.name}: must not be gated"
      end
    end

    test "the read runs for an untrusted caller and the write does not" do
      assert {:ok, _result} = Commands.call("background_list", %{}, caller: :mcp)

      assert {:error, :requires_confirmation} =
               Commands.call("background_set", %{"surface" => "terminal", "mode" => "waves"},
                 caller: :mcp
               )

      assert Appearance.background_mode(:terminal) == "off"
      refute_receive {:terminal_background, _background}
    end

    test "every argument the handler reads is declared in the catalog, and vice versa" do
      source = File.read!(Path.join(File.cwd!(), "lib/buster_claw/commands/appearance.ex"))

      read =
        [
          ~r/"([a-z][a-z0-9_]*)"\s*=>/,
          ~r/args\[\s*"([a-z][a-z0-9_]*)"\s*\]/,
          ~r/Map\.(?:get|fetch|fetch!|has_key\?)\(\s*args\s*,\s*"([a-z][a-z0-9_]*)"/
        ]
        |> Enum.flat_map(&(Regex.scan(&1, source) |> Enum.map(fn [_, key] -> key end)))
        |> MapSet.new()

      declared =
        Catalog.entries()
        |> Enum.filter(&String.starts_with?(&1.name, "background_"))
        |> Enum.flat_map(&Map.keys(&1.args))
        |> MapSet.new()

      assert read == declared,
             """
             The catalog and the handler disagree about arguments.
             handler reads: #{inspect(MapSet.to_list(read))}
             catalog declares: #{inspect(MapSet.to_list(declared))}
             """
    end
  end

  # --- B1: there is no second definition of a valid background ------------

  test "the command module's reach is Appearance's readers plus set_background/2" do
    assert internal_calls(BusterClaw.Commands.Appearance) == @reach,
           """
           `BusterClaw.Commands.Appearance` calls something new inside BusterClaw.

           This list is name-blind on purpose. B1's constraint: writing a
           `Settings` key directly, or re-deriving what a valid mode is, creates
           a SECOND definition of a valid background — which is the bug class
           089494e fixed. If the new call is legitimate, add it here and say in
           the commit why the background command surface needed to reach further.
           """
  end

  # --- call-graph helper --------------------------------------------------

  # Remote calls read from the module's BEAM `imports` chunk — the compiler's own
  # record of what it calls. It sees static remote calls and not `apply/3` with a
  # computed name, which is stated as a limit rather than hidden.
  defp internal_calls(module) do
    module
    |> imports()
    |> Enum.filter(fn {m, _f, _a} ->
      String.starts_with?(Atom.to_string(m), "Elixir.BusterClaw.")
    end)
    |> Enum.sort()
    |> Enum.uniq()
  end

  defp imports(module) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {_module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
      imports
    else
      _ -> []
    end
  end
end
