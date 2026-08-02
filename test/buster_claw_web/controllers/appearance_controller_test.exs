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
    {:ok, slot} = Appearance.put_image(src, "sky.jpg")

    {:ok, root: root, slot: slot}
  end

  test "serves the image with an ETag and revalidation caching, never immutable", %{
    conn: conn,
    slot: slot
  } do
    conn = get(conn, "/appearance/image/#{slot}")

    assert response(conn, 200) == "jpeg-bytes"
    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ ~r/^".+"$/
    assert get_resp_header(conn, "cache-control") == ["private, no-cache"]
  end

  test "revalidation: matching if-none-match gets a 304; a changed file does not", %{
    conn: conn,
    root: root,
    slot: slot
  } do
    [etag] = get_resp_header(get(conn, "/appearance/image/#{slot}"), "etag")

    conn2 = build_conn() |> put_req_header("if-none-match", etag)
    assert response(get(conn2, "/appearance/image/#{slot}"), 304) == ""

    # Another writer replaces the file: the old ETag must stop matching, so the
    # webview refetches instead of pinning the stale bytes.
    abs = Path.join([root, "backgrounds", "background-#{slot}.jpg"])
    File.write!(abs, "replaced by another instance")
    File.touch!(abs, System.os_time(:second) + 100)

    conn3 = build_conn() |> put_req_header("if-none-match", etag)

    assert response(get(conn3, "/appearance/image/#{slot}"), 200) ==
             "replaced by another instance"
  end

  test "404 for an empty slot", %{conn: conn} do
    assert response(get(conn, "/appearance/image/3"), 404) == ""
  end

  test "404 for a non-numeric or out-of-range slot", %{conn: conn} do
    assert response(get(conn, "/appearance/image/nope"), 404) == ""
    assert response(get(conn, "/appearance/image/99"), 404) == ""
  end
end
