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

  test "serves a named library sound", %{conn: conn, root: root} do
    File.write!(Path.join([root, "sounds", "wilhelm.wav"]), "RIFFfake-wav-bytes")

    conn = get(conn, ~p"/notify/sound/wilhelm.wav")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["audio/wav"]
    assert conn.resp_body == "RIFFfake-wav-bytes"
  end

  test "404 for a name that is not a library entry", %{conn: conn, root: root} do
    File.write!(Path.join([root, "sounds", "wilhelm.wav"]), "x")
    # A real file in the workspace but outside sounds/ must not resolve.
    File.write!(Path.join(root, "secret.wav"), "x")

    assert get(conn, ~p"/notify/sound/missing.wav").status == 404
    assert get(conn, ~p"/notify/sound/#{URI.encode_www_form("../secret.wav")}").status == 404
  end
end
