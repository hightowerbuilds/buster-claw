defmodule BusterClawWeb.NotifySoundControllerTest do
  use BusterClawWeb.ConnCase, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "bc_sndctl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sounds"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "404 when no sound is configured", %{conn: conn} do
    conn = get(conn, ~p"/notify/sound")
    assert conn.status == 404
  end

  test "serves the workspace sound with an audio content-type", %{conn: conn, root: root} do
    File.write!(Path.join([root, "sounds", "notify.mp3"]), "ID3fake-mp3-bytes")

    conn = get(conn, ~p"/notify/sound")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["audio/mpeg"]
    assert conn.resp_body == "ID3fake-mp3-bytes"
  end
end
