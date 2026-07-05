defmodule BusterClawWeb.ShaderControllerTest do
  use BusterClawWeb.ConnCase, async: false

  @wgsl "@fragment\nfn fs_main(in: VOut) -> @location(0) vec4<f32> { return vec4<f32>(1.0); }\n"

  setup do
    root = Path.join(System.tmp_dir!(), "bc_shaderctl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "shaders"))
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "serves a valid custom shader's WGSL as text", %{conn: conn, root: root} do
    File.write!(Path.join([root, "shaders", "aurora.wgsl"]), @wgsl)

    conn = get(conn, ~p"/shaders/aurora")
    assert response(conn, 200) =~ "fs_main"
    assert conn |> get_resp_header("content-type") |> hd() =~ "text/plain"
  end

  test "404s an unknown shader name", %{conn: conn} do
    assert conn |> get(~p"/shaders/nope") |> response(404)
  end

  test "404s a shader that fails validation (no fs_main)", %{conn: conn, root: root} do
    File.write!(Path.join([root, "shaders", "broken.wgsl"]), "// nothing here\n")
    assert conn |> get(~p"/shaders/broken") |> response(404)
  end
end
