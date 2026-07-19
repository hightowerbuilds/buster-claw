defmodule BusterClaw.AppearanceTest do
  # async: false — points the global :workspace_root at a tmp dir and writes
  # app_settings rows through the shared Settings store.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Appearance

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

  test "starts with max_slots empty slots and no active background" do
    slots = Appearance.slots()
    assert length(slots) == Appearance.max_slots()
    assert Enum.all?(slots, &(&1.filled == false))
    assert Appearance.active_slot() == nil
    assert Appearance.terminal_background_url() == nil
    assert Appearance.next_empty_slot() == 1
  end

  test "the first saved image becomes active; later ones do not" do
    assert {:ok, url1} = Appearance.put_terminal_background(1, fake_image(), "a.png")
    assert Appearance.active_slot() == 1
    assert Appearance.terminal_background_url() == url1
    assert url1 =~ "/appearance/terminal-background/1?v="

    assert {:ok, _url2} = Appearance.put_terminal_background(2, fake_image(), "b.jpg")
    assert Appearance.active_slot() == 1
    assert Appearance.next_empty_slot() == 3

    [s1, s2 | _] = Appearance.slots()
    assert s1.filled and s1.active
    assert s2.filled and not s2.active
  end

  test "set_active_slot switches the active background; empty slot errors" do
    Appearance.put_terminal_background(1, fake_image(), "a.png")
    Appearance.put_terminal_background(2, fake_image(), "b.png")

    assert {:ok, url2} = Appearance.set_active_slot(2)
    assert Appearance.active_slot() == 2
    assert Appearance.terminal_background_url() == url2

    assert {:error, :empty_slot} = Appearance.set_active_slot(4)
  end

  test "clearing the active slot promotes the next filled slot, then clears" do
    Appearance.put_terminal_background(1, fake_image(), "a.png")
    Appearance.put_terminal_background(2, fake_image(), "b.png")
    Appearance.set_active_slot(2)

    assert :ok = Appearance.clear_slot(2)
    assert Appearance.active_slot() == 1
    assert Enum.at(Appearance.slots(), 1).filled == false

    assert :ok = Appearance.clear_slot(1)
    assert Appearance.active_slot() == nil
    assert Appearance.terminal_background_url() == nil
  end

  test "rejects unsupported types and out-of-range slots" do
    assert {:error, :unsupported_type} =
             Appearance.put_terminal_background(1, fake_image(".txt"), "a.txt")

    assert {:error, :invalid_slot} =
             Appearance.put_terminal_background(9, fake_image(), "a.png")
  end

  test "slot_image returns the path for a filled slot and nil otherwise" do
    Appearance.put_terminal_background(3, fake_image(), "a.png")
    assert Appearance.slot_image(3) |> File.regular?()
    assert Appearance.slot_image(1) == nil
    assert Appearance.slot_image(99) == nil
  end

  test "a tampered stored path can't escape the appearance dir" do
    {:ok, _} = Appearance.put_terminal_background(1, fake_image(), "a.png")
    assert Appearance.slot_image(1) |> File.regular?()

    # A real file outside the appearance dir, reachable only by traversing out.
    root = Application.get_env(:buster_claw, :workspace_root)
    outside = Path.join(root, "outside.png")
    File.write!(outside, "img-bytes")

    # Point the slot at it via a `..` path; the containment guard must reject it.
    BusterClaw.Settings.put("terminal_background_1_path", "appearance/../outside.png")
    assert Appearance.slot_image(1) == nil
  end

  # --- background images: the URL must track the FILE, not our settings ---
  # The workspace is shared by other app instances/versions and by the agent;
  # a file replaced behind this instance's back must still bust the cache.

  test "a home image replaced behind the app's back changes the served URL", %{root: root} do
    assert {:ok, url} = Appearance.put_home_background_image(fake_image(".jpg"), "sky.jpg")
    assert url == Appearance.home_background_image_url()

    # Another instance (own settings DB, same files) rewrites the image: no
    # Settings change here, only the file.
    abs = Path.join([root, "appearance", "home-background.jpg"])
    File.write!(abs, "entirely different bytes")
    File.touch!(abs, System.os_time(:second) + 100)

    assert Appearance.home_background_image_url() != url
  end

  test "a slot image replaced behind the app's back changes the served URL", %{root: root} do
    assert {:ok, url} = Appearance.put_terminal_background(1, fake_image(".png"), "wall.png")

    abs = Path.join([root, "appearance", "terminal-background-1.png"])
    File.write!(abs, "new bytes, other writer")
    File.touch!(abs, System.os_time(:second) + 100)

    assert Appearance.slot_url(1) != url
  end

  # --- custom (runtime-loaded) homepage shaders --------------------------

  defp write_custom_shader(root, name) do
    dir = Path.join(root, "shaders")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, name <> ".wgsl"),
      "@fragment\nfn fs_main(in: VOut) -> @location(0) vec4<f32> { return vec4<f32>(1.0); }\n"
    )
  end

  test "a custom workspace shader is selectable and reflected in the state", %{root: root} do
    write_custom_shader(root, "aurora")

    assert "aurora" in Appearance.custom_shaders()
    assert {:ok, "aurora"} = Appearance.set_home_background_mode("aurora")

    state = Appearance.home_background_state()
    assert state.mode == "aurora"
    assert state.custom_shader
    assert state.source_url == "/shaders/aurora"
  end

  test "a built-in shader carries no custom_shader/source_url", %{root: _root} do
    assert {:ok, "waves"} = Appearance.set_home_background_mode("waves")
    state = Appearance.home_background_state()
    assert state.mode == "waves"
    refute state.custom_shader
    assert state.source_url == nil
  end

  test "a deleted custom shader mode falls back to the default", %{root: root} do
    write_custom_shader(root, "aurora")
    assert {:ok, "aurora"} = Appearance.set_home_background_mode("aurora")

    File.rm!(Path.join([root, "shaders", "aurora.wgsl"]))
    assert Appearance.home_background_state().mode == "smoke"
  end

  test "set_home_background_mode refuses a non-existent shader name", %{root: _root} do
    assert {:error, :invalid_mode} = Appearance.set_home_background_mode("does-not-exist")
  end

  test "off is a first-class mode: no shader, no image", %{root: _root} do
    assert {:ok, "off"} = Appearance.set_home_background_mode("off")
    assert Appearance.home_background_state().mode == "off"

    assert {:ok, "waves"} = Appearance.set_home_background_mode("waves")
    assert Appearance.home_background_state().mode == "waves"
  end

  # Faces flow one way: a background may be picked as a contact face, but a
  # contact's face is never offered — or honored — as the homepage background.

  test "a contact shaderface is not offered as a background", %{root: root} do
    write_custom_shader(root, "face-luke")
    write_custom_shader(root, "aurora")

    assert "aurora" in Appearance.custom_shaders()
    refute "face-luke" in Appearance.custom_shaders()
  end

  test "set_home_background_mode refuses a shaderface even though the file exists",
       %{root: root} do
    write_custom_shader(root, "face-luke")

    assert BusterClaw.Shaders.exists?("face-luke")
    assert {:error, :invalid_mode} = Appearance.set_home_background_mode("face-luke")
  end

  test "a shaderface already stored as the mode degrades to the default", %{root: root} do
    write_custom_shader(root, "face-luke")

    # Bypass the setter, as a value written before faces were fenced off would be.
    BusterClaw.Settings.put("home_background_mode", "face-luke")

    state = Appearance.home_background_state()
    assert state.mode == "smoke"
    refute state.custom_shader
  end

  test "a custom shader named like a built-in is shadowed by the built-in", %{root: root} do
    write_custom_shader(root, "smoke")
    refute "smoke" in Appearance.custom_shaders()
  end

  # --- terminal background: one active choice (off / shader / image) ---

  describe "terminal_background/0" do
    test "defaults to :none with nothing configured" do
      assert %{kind: :none, shader: nil, source_url: nil, image_url: nil} =
               Appearance.terminal_background()

      assert Appearance.terminal_background_mode() == "off"
    end

    test "back-compat: an active image slot with no saved mode reads as :image" do
      {:ok, url} = Appearance.put_terminal_background(1, fake_image(), "a.png")

      # put_terminal_background sets mode "image" for the first image; simulate a
      # pre-mode install by deleting the mode row and relying on inference.
      BusterClaw.Settings.delete("terminal_background_mode")

      assert Appearance.terminal_background_mode() == "image"
      assert %{kind: :image, image_url: ^url} = Appearance.terminal_background()
    end

    test "a built-in shader wins over an active image slot" do
      Appearance.put_terminal_background(1, fake_image(), "a.png")
      assert {:ok, "waves"} = Appearance.set_terminal_background_mode("waves")

      assert %{kind: :shader, shader: "waves", source_url: nil, image_url: nil} =
               Appearance.terminal_background()
    end

    test "a custom workspace shader carries its source_url", %{root: root} do
      write_custom_shader(root, "aurora")
      assert {:ok, "aurora"} = Appearance.set_terminal_background_mode("aurora")

      assert %{kind: :shader, shader: "aurora", source_url: "/shaders/aurora"} =
               Appearance.terminal_background()
    end

    test "choosing an image slot switches the mode away from a shader" do
      Appearance.put_terminal_background(1, fake_image(), "a.png")
      Appearance.put_terminal_background(2, fake_image(), "b.png")
      {:ok, "waves"} = Appearance.set_terminal_background_mode("waves")

      assert {:ok, url2} = Appearance.set_active_slot(2)
      assert %{kind: :image, image_url: ^url2} = Appearance.terminal_background()
      assert Appearance.terminal_background_mode() == "image"
    end

    test "'off' hides an active image without clearing the slot" do
      Appearance.put_terminal_background(1, fake_image(), "a.png")
      assert {:ok, "off"} = Appearance.set_terminal_background_mode("off")

      assert %{kind: :none} = Appearance.terminal_background()
      # The image library is untouched — the slot is still filled and active.
      assert Appearance.active_slot() == 1
    end

    test "removing the last image while in image mode falls back to off" do
      Appearance.put_terminal_background(1, fake_image(), "a.png")
      assert Appearance.terminal_background_mode() == "image"

      Appearance.clear_slot(1)
      assert Appearance.terminal_background_mode() == "off"
      assert %{kind: :none} = Appearance.terminal_background()
    end
  end

  describe "terminal shader custom palette" do
    test "defaults to off with the seed palette" do
      refute Appearance.terminal_background_custom?()
      assert Appearance.terminal_background_colors() == ["#0e0e0e", "#ff4d1c", "#f4f1ea"]
    end

    test "the palette rides along on the resolved shader background" do
      {:ok, "waves"} = Appearance.set_terminal_background_mode("waves")
      Appearance.set_terminal_background_custom(true)
      {:ok, _} = Appearance.set_terminal_background_colors(["#112233", "#445566", "#778899"])

      assert %{kind: :shader, custom: true, colors: ["#112233", "#445566", "#778899"]} =
               Appearance.terminal_background()
    end

    test "it is independent of the homepage palette" do
      {:ok, _} = Appearance.set_terminal_background_colors(["#111111", "#222222", "#333333"])
      {:ok, _} = Appearance.set_home_background_colors(["#aaaaaa", "#bbbbbb", "#cccccc"])

      assert Appearance.terminal_background_colors() == ["#111111", "#222222", "#333333"]
      assert Appearance.home_background_colors() == ["#aaaaaa", "#bbbbbb", "#cccccc"]
    end

    test "bad hex values fall back to black; a wrong count is rejected" do
      {:ok, cleaned} =
        Appearance.set_terminal_background_colors(["#zzzzzz", "not-a-color", "#00ff00"])

      assert cleaned == ["#000000", "#000000", "#00ff00"]

      assert {:error, :invalid} =
               Appearance.set_terminal_background_colors(["#111111", "#222222"])
    end
  end

  describe "set_terminal_background_mode/1" do
    test "'image' with no active slot is refused" do
      assert {:error, :no_image} = Appearance.set_terminal_background_mode("image")
    end

    test "a non-existent shader name is refused" do
      assert {:error, :invalid_mode} = Appearance.set_terminal_background_mode("does-not-exist")
    end

    test "a shaderface is refused even though the file exists", %{root: root} do
      write_custom_shader(root, "face-luke")
      assert BusterClaw.Shaders.exists?("face-luke")
      assert {:error, :invalid_mode} = Appearance.set_terminal_background_mode("face-luke")
    end

    test "a deleted custom shader mode degrades to off", %{root: root} do
      write_custom_shader(root, "aurora")
      assert {:ok, "aurora"} = Appearance.set_terminal_background_mode("aurora")

      File.rm!(Path.join([root, "shaders", "aurora.wgsl"]))
      assert Appearance.terminal_background_mode() == "off"
      assert %{kind: :none} = Appearance.terminal_background()
    end
  end
end
