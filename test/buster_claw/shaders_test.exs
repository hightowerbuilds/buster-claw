defmodule BusterClaw.ShadersTest do
  # async: false — points the global :workspace_root at a tmp dir.
  use ExUnit.Case, async: false

  alias BusterClaw.Shaders

  setup do
    root = Path.join(System.tmp_dir!(), "bc_shaders_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev_ws)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp write_shader(root, name, body) do
    dir = Path.join(root, "shaders")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name <> ".wgsl"), body)
  end

  @valid "@fragment\nfn fs_main(in: VOut) -> @location(0) vec4<f32> { return vec4<f32>(1.0); }\n"

  test "reads and lists a valid shader", %{root: root} do
    write_shader(root, "aurora", @valid)

    assert {:ok, wgsl} = Shaders.read("aurora")
    assert wgsl =~ "fs_main"
    assert Shaders.exists?("aurora")
    assert Shaders.list() == ["aurora"]
  end

  test "rejects a shader with no fs_main", %{root: root} do
    write_shader(root, "empty", "// just a comment, no entry point\n")

    assert {:error, :missing_fs_main} = Shaders.read("empty")
    refute Shaders.exists?("empty")
    # ...and it's filtered out of the listing.
    assert Shaders.list() == []
  end

  test "rejects an oversized shader", %{root: root} do
    big = "fn fs_main() {}\n" <> String.duplicate("x", 70_000)
    write_shader(root, "huge", big)

    assert {:error, :too_large} = Shaders.read("huge")
  end

  test "guards the name against traversal and bad characters", %{root: _root} do
    assert {:error, :invalid_name} = Shaders.read("../secret")
    assert {:error, :invalid_name} = Shaders.read("a/b")
    assert {:error, :invalid_name} = Shaders.read("Caps")
    assert {:error, :not_found} = Shaders.read("nope")
  end

  test "face?/1 classifies by the face- naming convention" do
    assert Shaders.face?("face")
    assert Shaders.face?("face-luke")
    refute Shaders.face?("aurora")
    # No prefix without the dash: "faces" is a background named faces.
    refute Shaders.face?("faces")
    refute Shaders.face?(nil)
  end

  test "ensure seeds a README without clobbering an operator file", %{root: root} do
    assert :ok = Shaders.ensure()
    readme = Path.join([root, "shaders", "README.md"])
    assert File.exists?(readme)
    assert File.read!(readme) =~ "shader-designer"

    File.write!(readme, "mine")
    assert :ok = Shaders.ensure()
    assert File.read!(readme) == "mine"
  end
end
