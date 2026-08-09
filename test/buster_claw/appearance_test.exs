defmodule BusterClaw.AppearanceTest do
  # async: false — points the global :workspace_root at a tmp dir and writes
  # app_settings rows through the shared Settings store.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Appearance
  alias BusterClaw.Settings

  setup do
    root = Path.join(System.tmp_dir!(), "bc_appearance_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp fake_image(ext \\ ".png") do
    path = Path.join(System.tmp_dir!(), "bc_src_#{System.unique_integer([:positive])}#{ext}")
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

  # --- the shared catalog --------------------------------------------------

  describe "options/0" do
    test "offers off, every built-in shader, and the whole image pool" do
      keys = Enum.map(Appearance.options(), & &1.key)

      assert "off" in keys
      assert Enum.all?(Appearance.builtin_shaders(), &(&1 in keys))
      assert Enum.count(keys, &String.starts_with?(&1, "image:")) == Appearance.max_images()
    end

    test "includes workspace shaders but never shaderfaces", %{root: root} do
      write_custom_shader(root, "aurora")
      write_custom_shader(root, "face-luke")
      write_custom_shader(root, "viking-face")

      keys = Enum.map(Appearance.options(), & &1.key)

      assert "aurora" in keys
      refute "face-luke" in keys
      refute "viking-face" in keys
    end

    test "a custom shader named like a built-in is shadowed by the built-in", %{root: root} do
      write_custom_shader(root, "smoke")
      refute "smoke" in Appearance.custom_shaders()
    end

    test "only images carry a url — a shader is named, never pictured" do
      {:ok, 1} = Appearance.put_image(fake_image(), "a.png")
      by_key = Map.new(Appearance.options(), &{&1.key, &1})

      assert by_key["smoke"].url == nil
      assert by_key["off"].url == nil
      assert by_key["image:1"].url =~ "/appearance/image/1"
    end

    test "filled images sort ahead of empty slots" do
      {:ok, 1} = Appearance.put_image(fake_image(), "a.png")

      filled? = Appearance.images() |> Enum.map(& &1.filled)
      assert hd(filled?)
      # No filled slot may appear after an empty one.
      refute Enum.chunk_every(filled?, 2, 1, :discard) |> Enum.any?(&match?([false, true], &1))
    end
  end

  # --- the shared image pool ----------------------------------------------

  describe "the image pool" do
    test "starts empty" do
      assert Enum.all?(Appearance.images(), &(&1.filled == false))
      assert Appearance.next_empty_slot() == 1
      refute Appearance.pool_full?()
      assert Appearance.image_url(1) == nil
    end

    test "uploads fill the lowest empty slot and serve a stamped URL" do
      assert {:ok, 1} = Appearance.put_image(fake_image(), "a.png")
      assert {:ok, 2} = Appearance.put_image(fake_image(".jpg"), "b.jpg")

      assert Appearance.image_url(1) =~ ~r"^/appearance/image/1\?v="
      assert Appearance.next_empty_slot() == 3
    end

    test "adding an image does not change what either surface shows" do
      before = Map.new(Appearance.surfaces(), &{&1, Appearance.background_mode(&1)})
      {:ok, _slot} = Appearance.put_image(fake_image(), "a.png")

      assert Map.new(Appearance.surfaces(), &{&1, Appearance.background_mode(&1)}) == before
    end

    test "rejects an unsupported type and refuses to overflow" do
      assert {:error, :unsupported_type} = Appearance.put_image(fake_image(".txt"), "a.txt")

      for _ <- 1..Appearance.max_images(), do: Appearance.put_image(fake_image(), "x.png")

      assert Appearance.pool_full?()
      assert {:error, :pool_full} = Appearance.put_image(fake_image(), "one-too-many.png")
    end

    test "image_path returns the file for a filled slot and nil otherwise" do
      {:ok, 1} = Appearance.put_image(fake_image(), "a.png")

      assert Appearance.image_path(1) |> File.regular?()
      assert Appearance.image_path(2) == nil
      assert Appearance.image_path(99) == nil
    end

    test "a tampered stored path can't escape the appearance dir", %{root: root} do
      {:ok, 1} = Appearance.put_image(fake_image(), "a.png")
      assert Appearance.image_path(1) |> File.regular?()

      # A real file outside the appearance dir, reachable only by traversing out.
      outside = Path.join(root, "outside.png")
      File.write!(outside, "img-bytes")

      # Point the slot at it via a `..` path; the containment guard must reject it.
      Settings.put("background_image_1_path", "appearance/../outside.png")
      assert Appearance.image_path(1) == nil
    end

    # The workspace is shared by other app instances/versions and by the agent;
    # a file replaced behind this instance's back must still bust the cache.
    test "an image replaced behind the app's back changes the served URL", %{root: root} do
      {:ok, 1} = Appearance.put_image(fake_image(".jpg"), "sky.jpg")
      url = Appearance.image_url(1)

      abs = Path.join([root, "pockets", "backgrounds", "background-1.jpg"])
      File.write!(abs, "entirely different bytes")
      File.touch!(abs, System.os_time(:second) + 100)

      assert Appearance.image_url(1) != url
    end
  end

  # --- assigning an option to a surface ------------------------------------

  describe "set_background/2" do
    test "off, a built-in shader, and a workspace shader all resolve", %{root: root} do
      write_custom_shader(root, "aurora")

      for surface <- Appearance.surfaces() do
        assert {:ok, "off"} = Appearance.set_background(surface, "off")
        assert %{kind: :none, shader: nil, image_url: nil} = Appearance.background(surface)

        assert {:ok, "waves"} = Appearance.set_background(surface, "waves")

        assert %{kind: :shader, shader: "waves", source_url: nil, custom_shader: false} =
                 Appearance.background(surface)

        assert {:ok, "aurora"} = Appearance.set_background(surface, "aurora")

        assert %{kind: :shader, shader: "aurora", source_url: "/shaders/aurora"} =
                 Appearance.background(surface)
      end
    end

    test "one image can back both surfaces at once" do
      {:ok, 1} = Appearance.put_image(fake_image(), "a.png")
      url = Appearance.image_url(1)

      assert {:ok, "image:1"} = Appearance.set_background(:home, "image:1")
      assert {:ok, "image:1"} = Appearance.set_background(:terminal, "image:1")

      assert %{kind: :image, image_url: ^url, slot: 1} = Appearance.background(:home)
      assert %{kind: :image, image_url: ^url, slot: 1} = Appearance.background(:terminal)
    end

    test "the surfaces are independent" do
      {:ok, 1} = Appearance.put_image(fake_image(), "a.png")

      {:ok, _} = Appearance.set_background(:home, "image:1")
      {:ok, _} = Appearance.set_background(:terminal, "mandel")

      assert Appearance.background(:home).kind == :image
      assert Appearance.background(:terminal).kind == :shader
    end

    test "an empty image slot is refused and reported as such" do
      assert {:error, :empty_slot} = Appearance.set_background(:home, "image:4")
      assert {:error, :empty_slot} = Appearance.set_background(:terminal, "image:99")
    end

    test "a non-existent name and a bad surface are refused" do
      assert {:error, :invalid_mode} = Appearance.set_background(:home, "does-not-exist")
      assert {:error, :invalid_mode} = Appearance.set_background(:nowhere, "smoke")
    end

    test "a shaderface is refused even though the file exists", %{root: root} do
      write_custom_shader(root, "face-luke")
      assert BusterClaw.Shaders.exists?("face-luke")

      for surface <- Appearance.surfaces() do
        assert {:error, :invalid_mode} = Appearance.set_background(surface, "face-luke")
      end
    end

    test "option_key/1 is the inverse — every resolved background names its tile" do
      {:ok, 1} = Appearance.put_image(fake_image(), "a.png")

      for key <- ["off", "waves", "image:1"] do
        {:ok, ^key} = Appearance.set_background(:home, key)
        assert Appearance.background(:home) |> Appearance.option_key() == key
      end
    end
  end

  # --- degradation ---------------------------------------------------------

  describe "a stale mode degrades to the surface default" do
    test "the homepage falls back to smoke, the terminal to off", %{root: root} do
      write_custom_shader(root, "aurora")
      {:ok, _} = Appearance.set_background(:home, "aurora")
      {:ok, _} = Appearance.set_background(:terminal, "aurora")

      File.rm!(Path.join([root, "shaders", "aurora.wgsl"]))

      assert Appearance.background(:home).mode == "smoke"
      assert Appearance.background(:terminal).kind == :none
    end

    test "a shaderface stored as the mode degrades", %{root: root} do
      write_custom_shader(root, "face-luke")

      # Bypass the setter, as a value written before faces were fenced off would be.
      Settings.put("home_background_mode", "face-luke")

      state = Appearance.background(:home)
      assert state.mode == "smoke"
      refute state.custom_shader
    end

    test "nothing configured at all: smoke for home, off for the terminal" do
      assert Appearance.background(:home).mode == "smoke"
      assert Appearance.background(:terminal).kind == :none
      assert Appearance.terminal_background_url() == nil
    end
  end

  describe "clear_image/1" do
    test "degrades every surface pointing at it, and only those" do
      {:ok, 1} = Appearance.put_image(fake_image(), "a.png")
      {:ok, 2} = Appearance.put_image(fake_image(), "b.png")

      {:ok, _} = Appearance.set_background(:home, "image:1")
      {:ok, _} = Appearance.set_background(:terminal, "image:2")

      assert :ok = Appearance.clear_image(1)

      assert Appearance.background(:home).mode == "smoke"
      assert Appearance.background(:terminal).slot == 2
    end

    test "clears both surfaces when both used it" do
      {:ok, 1} = Appearance.put_image(fake_image(), "a.png")
      {:ok, _} = Appearance.set_background(:home, "image:1")
      {:ok, _} = Appearance.set_background(:terminal, "image:1")

      assert :ok = Appearance.clear_image(1)

      assert Appearance.background(:home).kind != :image
      assert Appearance.background(:terminal).kind == :none
    end

    test "removes the file and frees the slot" do
      {:ok, 1} = Appearance.put_image(fake_image(), "a.png")
      path = Appearance.image_path(1)

      assert :ok = Appearance.clear_image(1)

      refute File.regular?(path)
      assert Appearance.image_url(1) == nil
      assert Appearance.next_empty_slot() == 1
    end

    test "a surface on a shader is untouched by a pool removal" do
      {:ok, 1} = Appearance.put_image(fake_image(), "a.png")
      {:ok, _} = Appearance.set_background(:terminal, "waves")

      assert :ok = Appearance.clear_image(1)
      assert Appearance.background(:terminal).shader == "waves"
    end
  end

  # --- per-surface palettes ------------------------------------------------

  describe "custom palettes" do
    test "default to off with the seed palette" do
      for surface <- Appearance.surfaces() do
        refute Appearance.custom?(surface)
        assert Appearance.colors(surface) == ["#0e0e0e", "#ff4d1c", "#f4f1ea"]
      end
    end

    test "ride along on the resolved shader background" do
      {:ok, _} = Appearance.set_background(:terminal, "waves")
      :ok = Appearance.set_custom(:terminal, true)
      {:ok, _} = Appearance.set_colors(:terminal, ["#112233", "#445566", "#778899"])

      assert %{kind: :shader, custom: true, colors: ["#112233", "#445566", "#778899"]} =
               Appearance.background(:terminal)
    end

    test "are independent per surface" do
      {:ok, _} = Appearance.set_colors(:terminal, ["#111111", "#222222", "#333333"])
      {:ok, _} = Appearance.set_colors(:home, ["#aaaaaa", "#bbbbbb", "#cccccc"])

      assert Appearance.colors(:terminal) == ["#111111", "#222222", "#333333"]
      assert Appearance.colors(:home) == ["#aaaaaa", "#bbbbbb", "#cccccc"]
    end

    test "bad hex values fall back to black; a wrong count is rejected" do
      {:ok, cleaned} = Appearance.set_colors(:terminal, ["#zzzzzz", "not-a-color", "#00ff00"])
      assert cleaned == ["#000000", "#000000", "#00ff00"]

      assert {:error, :invalid} = Appearance.set_colors(:terminal, ["#111111", "#222222"])
    end
  end

  # --- migration from the pre-pool layout ----------------------------------

  describe "ensure/0 migrates the pre-pool layout" do
    setup do
      # The app ran ensure/0 once at boot and committed its marker before the
      # sandbox opened, so every test here starts life already "migrated". Drop
      # the marker (inside this test's transaction) to get a pre-pool world back.
      Settings.delete("appearance_image_pool_migrated")
      :ok
    end

    # Seed the old world: per-surface files on disk plus the Settings rows the
    # pre-pool code wrote. Files are deliberately left under their OLD names —
    # the migration must adopt them in place, not move or lose them. They sit in
    # `pockets/backgrounds/` (where `Workspace.ensure/0`'s relocation puts them
    # before `Appearance.ensure/0` runs) while the legacy Settings rels still say
    # `appearance/…` — so these tests also prove the rename rewrite, now across
    # BOTH hops: `appearance/` → `backgrounds/` → `pockets/backgrounds/`.
    defp seed_legacy(root, opts) do
      dir = Path.join(root, "pockets/backgrounds")
      File.mkdir_p!(dir)

      Enum.each(Keyword.get(opts, :terminal_slots, []), fn n ->
        File.write!(Path.join(dir, "terminal-background-#{n}.png"), "slot-#{n}-bytes")
        Settings.put("terminal_background_#{n}_path", "appearance/terminal-background-#{n}.png")
        Settings.put("terminal_background_#{n}_updated_at", "111")
      end)

      if active = opts[:active], do: Settings.put("terminal_background_active", to_string(active))
      if mode = opts[:terminal_mode], do: Settings.put("terminal_background_mode", mode)

      if opts[:home_image] do
        File.write!(Path.join(dir, "home-background.jpg"), "home-bytes")
        Settings.put("home_background_image_path", "appearance/home-background.jpg")
        Settings.put("home_background_image_updated_at", "222")
      end

      if mode = opts[:home_mode], do: Settings.put("home_background_mode", mode)
    end

    test "terminal slots keep their numbers and the active one becomes the mode", %{root: root} do
      seed_legacy(root, terminal_slots: [1, 2], active: 2, terminal_mode: "image")

      assert :ok = Appearance.ensure()

      assert Appearance.image_path(1) |> File.read!() == "slot-1-bytes"
      assert Appearance.image_path(2) |> File.read!() == "slot-2-bytes"
      assert Appearance.background(:terminal).slot == 2
      assert Appearance.background_mode(:terminal) == "image:2"
    end

    test "an unset terminal mode with an active slot still means image", %{root: root} do
      # The pre-shader install: no mode row at all, an active slot implied image.
      seed_legacy(root, terminal_slots: [1], active: 1)

      assert :ok = Appearance.ensure()
      assert Appearance.background(:terminal).kind == :image
    end

    test "a terminal on a shader keeps its shader, and its images still migrate", %{root: root} do
      seed_legacy(root, terminal_slots: [1], active: 1, terminal_mode: "waves")

      assert :ok = Appearance.ensure()

      assert Appearance.background(:terminal).shader == "waves"
      assert Appearance.image_path(1) |> File.regular?()
    end

    test "the homepage image lands in the first free slot and keeps being used", %{root: root} do
      seed_legacy(root,
        terminal_slots: [1, 2],
        active: 1,
        terminal_mode: "image",
        home_image: true,
        home_mode: "image"
      )

      assert :ok = Appearance.ensure()

      assert Appearance.background(:home).slot == 3
      assert Appearance.image_path(3) |> File.read!() == "home-bytes"
      # And the terminal is unaffected by where the homepage image landed.
      assert Appearance.background(:terminal).slot == 1
    end

    test "an uploaded-but-unused homepage image joins the pool without being applied",
         %{root: root} do
      seed_legacy(root, home_image: true, home_mode: "smoke")

      assert :ok = Appearance.ensure()

      assert Appearance.image_path(1) |> File.regular?()
      assert Appearance.background(:home).mode == "smoke"
    end

    test "it is idempotent and leaves the legacy keys behind", %{root: root} do
      seed_legacy(root, terminal_slots: [1], active: 1, terminal_mode: "image")

      assert :ok = Appearance.ensure()
      assert :ok = Appearance.ensure()

      assert Appearance.background(:terminal).slot == 1
      assert Settings.get("terminal_background_active") == nil
      assert Settings.get("terminal_background_1_path") == nil
      assert Settings.get("home_background_image_path") == nil
    end

    test "a fresh install migrates nothing and is left at the defaults" do
      assert :ok = Appearance.ensure()

      assert Enum.all?(Appearance.images(), &(&1.filled == false))
      assert Appearance.background(:home).mode == "smoke"
      assert Appearance.background(:terminal).kind == :none
    end
  end

  # --- the shims the rest of the app still calls ---------------------------

  describe "legacy aliases" do
    test "terminal_background/0 and home_background_state/0 keep their shape" do
      {:ok, 1} = Appearance.put_image(fake_image(), "a.png")
      {:ok, _} = Appearance.set_background(:terminal, "image:1")
      {:ok, _} = Appearance.set_background(:home, "waves")

      assert %{kind: :image, image_url: url, custom: false, colors: [_, _, _]} =
               Appearance.terminal_background()

      assert url == Appearance.terminal_background_url()

      assert %{mode: "waves", custom_shader: false, source_url: nil, image_url: nil} =
               Appearance.home_background_state()
    end

    test "the two surfaces broadcast on distinct topics" do
      assert Appearance.topic(:terminal) == Appearance.topic()
      assert Appearance.topic(:home) == Appearance.home_topic()
      refute Appearance.topic(:home) == Appearance.topic(:terminal)
    end

    test "a change broadcasts the resolved background to subscribers" do
      Phoenix.PubSub.subscribe(BusterClaw.PubSub, Appearance.topic(:terminal))
      {:ok, _} = Appearance.set_background(:terminal, "waves")

      assert_receive {:terminal_background, %{kind: :shader, shader: "waves"}}
    end
  end
end
