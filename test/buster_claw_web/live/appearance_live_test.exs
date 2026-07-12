defmodule BusterClawWeb.AppearanceLiveTest do
  # async: false — points the global :workspace_root at a tmp dir.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Appearance

  setup do
    root = Path.join(System.tmp_dir!(), "bc_appearance_lv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp write_custom_shader(root, name) do
    dir = Path.join(root, "shaders")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, name <> ".wgsl"),
      "@fragment\nfn fs_main(in: VOut) -> @location(0) vec4<f32> { return vec4<f32>(1.0); }\n"
    )
  end

  test "the background picker offers custom backgrounds but never shaderfaces",
       %{conn: conn, root: root} do
    write_custom_shader(root, "aurora")
    write_custom_shader(root, "face-luke")
    write_custom_shader(root, "viking-face")

    {:ok, _view, html} = live(conn, "/appearance")

    assert html =~ "aurora"
    refute html =~ "face-luke"
    refute html =~ "viking-face"
  end

  test "a crafted set_home_bg event with a shaderface leaves the mode unchanged",
       %{conn: conn, root: root} do
    write_custom_shader(root, "face-luke")

    {:ok, view, _html} = live(conn, "/appearance")

    render_click(view, "set_home_bg", %{"mode" => "face-luke"})

    assert Appearance.home_background_state().mode == "smoke"
  end
end
