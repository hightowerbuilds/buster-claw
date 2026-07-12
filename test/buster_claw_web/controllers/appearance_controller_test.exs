defmodule BusterClawWeb.AppearanceControllerTest do
  # async: false — points the global :workspace_root at a tmp dir.
  use BusterClawWeb.ConnCase, async: false

  alias BusterClaw.Appearance

  setup do
    root = Path.join(System.tmp_dir!(), "bc_appearance_c_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    src = Path.join(System.tmp_dir!(), "bc_src_#{System.unique_integer([:positive])}.jpg")
    File.write!(src, "jpeg-bytes")
    {:ok, _url} = Appearance.put_home_background_image(src, "sky.jpg")

    {:ok, root: root}
  end

  test "serves the image with an ETag and revalidation caching, never immutable", %{conn: conn} do
    conn = get(conn, "/appearance/home-background")

    assert response(conn, 200) == "jpeg-bytes"
    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ ~r/^".+"$/
    assert get_resp_header(conn, "cache-control") == ["private, no-cache"]
  end

  test "revalidation: matching if-none-match gets a 304; a changed file does not", %{
    conn: conn,
    root: root
  } do
    [etag] = get_resp_header(get(conn, "/appearance/home-background"), "etag")

    conn2 = build_conn() |> put_req_header("if-none-match", etag)
    assert response(get(conn2, "/appearance/home-background"), 304) == ""

    # Another writer replaces the file: the old ETag must stop matching, so the
    # webview refetches instead of pinning the stale bytes.
    abs = Path.join([root, "appearance", "home-background.jpg"])
    File.write!(abs, "replaced by another instance")
    File.touch!(abs, System.os_time(:second) + 100)

    conn3 = build_conn() |> put_req_header("if-none-match", etag)

    assert response(get(conn3, "/appearance/home-background"), 200) ==
             "replaced by another instance"
  end

  test "404 for an empty slot", %{conn: conn} do
    assert response(get(conn, "/appearance/terminal-background/3"), 404) == ""
  end
end
