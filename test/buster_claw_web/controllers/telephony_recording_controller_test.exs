defmodule BusterClawWeb.TelephonyRecordingControllerTest do
  @moduledoc """
  Coverage written when this controller was migrated onto
  `BusterClawWeb.RangeResponse` (MUSIC_ROADMAP Phase 1). It had none before, and
  the migration changed its response shape — so the path guard that was the
  whole point of the route now has a test, alongside the new range behavior.
  """
  use BusterClawWeb.ConnCase, async: false

  @body "RIFFfake-wav-bytes-0123456789"
  @size byte_size(@body)

  setup do
    root = Path.join(System.tmp_dir!(), "bc_recctl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "raw"))

    prev = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, prev)
      File.rm_rf(root)
    end)

    File.write!(Path.join([root, "raw", "voicemail.wav"]), @body)

    {:ok, root: root}
  end

  describe "serving a recording" do
    test "sends the audio with a type and advertises ranges", %{conn: conn} do
      conn = get(conn, ~p"/phone/recording?path=raw/voicemail.wav")

      assert conn.status == 200
      assert conn.resp_body == @body
      assert get_resp_header(conn, "content-type") == ["audio/wav"]
      # New since the migration: without this a voicemail scrub re-downloaded
      # from byte zero.
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    end

    test "a recording really is immutable, unlike a music track", %{conn: conn} do
      # A recording path is written once and never rewritten, so the long cache
      # is correct here and deliberately different from MusicController's.
      conn = get(conn, ~p"/phone/recording?path=raw/voicemail.wav")

      assert get_resp_header(conn, "cache-control") == [
               "private, max-age=31536000, immutable"
             ]
    end

    test "honors a byte range", %{conn: conn} do
      conn =
        conn
        |> put_req_header("range", "bytes=0-3")
        |> get(~p"/phone/recording?path=raw/voicemail.wav")

      assert conn.status == 206
      assert conn.resp_body == "RIFF"
      assert get_resp_header(conn, "content-range") == ["bytes 0-3/#{@size}"]
    end

    test "an unsatisfiable range is refused, not clamped to nothing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("range", "bytes=9999-")
        |> get(~p"/phone/recording?path=raw/voicemail.wav")

      assert conn.status == 416
      assert get_resp_header(conn, "content-range") == ["bytes */#{@size}"]
    end
  end

  describe "the path guard" do
    test "refuses a path that escapes the library root", %{conn: conn, root: root} do
      outside = Path.join(Path.dirname(root), "outside.wav")
      File.write!(outside, "secret")
      on_exit(fn -> File.rm_rf(outside) end)

      conn = get(conn, ~p"/phone/recording?path=../outside.wav")

      assert conn.status == 404
      refute conn.resp_body == "secret"
    end

    test "refuses an absolute path outside the root", %{conn: conn} do
      conn = get(conn, ~p"/phone/recording?path=/etc/passwd")

      assert conn.status == 404
    end

    test "refuses a non-audio extension inside the root", %{conn: conn, root: root} do
      File.write!(Path.join([root, "raw", "notes.txt"]), "secret")

      conn = get(conn, ~p"/phone/recording?path=raw/notes.txt")

      assert conn.status == 404
      refute conn.resp_body == "secret"
    end

    test "404s a missing file and a missing param", %{conn: conn} do
      assert get(conn, ~p"/phone/recording?path=raw/ghost.wav").status == 404
      assert get(conn, ~p"/phone/recording").status == 404
    end

    test "refuses a directory that looks like a recording", %{conn: conn, root: root} do
      File.mkdir_p!(Path.join([root, "raw", "folder.wav"]))

      assert get(conn, ~p"/phone/recording?path=raw/folder.wav").status == 404
    end
  end
end
