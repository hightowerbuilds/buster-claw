defmodule BusterClawWeb.PocketAssetControllerTest do
  # async: false — points the global :workspace_root at a tmp dir.
  use BusterClawWeb.ConnCase, async: false

  alias BusterClaw.{Library, Pockets}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_pocket_asset_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_lib = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))
    Library.ensure_directories()

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev_ws)
      Application.put_env(:buster_claw, :library_root, prev_lib)
      File.rm_rf(root)
    end)

    dir = Pockets.pocket_dir("kit")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "POCKET.md"), """
    ---
    name: kit
    kind: icons
    ---

    Icons.
    """)

    File.write!(Path.join(dir, "claw.png"), "png-bytes")

    {:ok, root: root, dir: dir}
  end

  test "serves a pocket's file with a named content type and nosniff", %{conn: conn} do
    conn = get(conn, "/pockets/kit/claw.png")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert [etag] = get_resp_header(conn, "etag")
    assert etag != ""
  end

  test "revalidates rather than pinning bytes", %{conn: conn} do
    first = get(conn, "/pockets/kit/claw.png")
    [etag] = get_resp_header(first, "etag")

    assert get_resp_header(first, "cache-control") == ["private, no-cache"]

    second =
      build_conn()
      |> put_req_header("if-none-match", etag)
      |> get("/pockets/kit/claw.png")

    assert second.status == 304
  end

  test "an unknown extension is not guessed at", %{conn: conn, dir: dir} do
    File.write!(Path.join(dir, "thing.xyz"), "bytes")

    conn = get(conn, "/pockets/kit/thing.xyz")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
  end

  describe "containment" do
    test "a traversal in the filename is refused", %{conn: conn, root: root} do
      File.write!(Path.join(root, "secret.png"), "secret")

      # Both the raw and the encoded form: the router decodes before we see it.
      for file <- ["..%2Fsecret.png", "%2e%2e%2fsecret.png"] do
        assert get(conn, "/pockets/kit/#{file}").status in [400, 404]
      end
    end

    test "a symlink planted inside a pocket is refused, not followed", %{conn: conn, dir: dir} do
      outside = Path.join(System.tmp_dir!(), "bc_pa_out_#{System.unique_integer([:positive])}")
      File.write!(outside, "secret")
      on_exit(fn -> File.rm_rf(outside) end)

      File.ln_s!(outside, Path.join(dir, "escape.png"))

      # A mount is the only way a Pocket reaches outside itself.
      assert get(conn, "/pockets/kit/escape.png").status == 404
    end

    test "a dotfile is not addressable", %{conn: conn, dir: dir} do
      File.write!(Path.join(dir, ".env"), "SECRET=1")

      assert get(conn, "/pockets/kit/.env").status == 404
    end

    test "the manifest of a pocket that does not load makes nothing reachable", %{conn: conn} do
      broken = Pockets.pocket_dir("broken")
      File.mkdir_p!(broken)
      File.write!(Path.join(broken, "POCKET.md"), "---\nkind: sculptures\n---\n")
      File.write!(Path.join(broken, "a.png"), "bytes")

      assert get(conn, "/pockets/broken/a.png").status == 404
    end

    test "a directory with no manifest at all serves nothing", %{conn: conn} do
      bare = Pockets.pocket_dir("bare")
      File.mkdir_p!(bare)
      File.write!(Path.join(bare, "a.png"), "bytes")

      assert get(conn, "/pockets/bare/a.png").status == 404
    end

    test "a subdirectory is not a file", %{conn: conn, dir: dir} do
      File.mkdir_p!(Path.join(dir, "sub"))

      assert get(conn, "/pockets/kit/sub").status == 404
    end
  end

  describe "asset_url" do
    test "round-trips through the route it names" do
      {:ok, pocket} = Pockets.load("kit")

      url = Pockets.asset_url(pocket, "claw.png")
      assert url =~ ~r"^/pockets/kit/claw\.png\?v="

      assert build_conn() |> get(url) |> Map.get(:status) == 200
    end

    test "is nil for a file the pocket does not have" do
      {:ok, pocket} = Pockets.load("kit")

      assert Pockets.asset_url(pocket, "missing.png") == nil
      assert Pockets.asset_url(pocket, "../secret.png") == nil
    end
  end
end
