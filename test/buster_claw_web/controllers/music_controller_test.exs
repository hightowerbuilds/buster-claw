defmodule BusterClawWeb.MusicControllerTest do
  use BusterClawWeb.ConnCase, async: false

  # 26 bytes, so a range assertion reads as letters rather than arithmetic.
  @body "abcdefghijklmnopqrstuvwxyz"
  @size byte_size(@body)

  setup do
    root = Path.join(System.tmp_dir!(), "bc_musicctl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([root, "sounds", "music"]))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    File.write!(Path.join([root, "sounds", "music", "song.mp3"]), @body)

    {:ok, root: root}
  end

  defp ranged(conn, range),
    do: conn |> put_req_header("range", range) |> get(~p"/music/track/song.mp3")

  describe "without a Range header" do
    test "serves the whole file and advertises range support", %{conn: conn} do
      conn = get(conn, ~p"/music/track/song.mp3")

      assert conn.status == 200
      assert conn.resp_body == @body
      assert get_resp_header(conn, "content-type") == ["audio/mpeg"]
      # The advertisement is how a client learns it may seek at all, so it
      # belongs on the 200 and not only on the 206.
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "content-range") == []
    end

    test "refuses to let the browser sniff a content type", %{conn: conn, root: root} do
      # These routes carry no pipeline, so they get neither
      # put_secure_browser_headers nor a CSP header — and what they serve is a
      # workspace file, which a user upload or an agent can write. Without
      # nosniff, a file named .mp3 whose content is HTML could be rendered and
      # its inline script run from our own origin with nothing to stop it.
      File.write!(
        Path.join([root, "sounds", "music", "sneaky.mp3"]),
        "<html><script>x</script></html>"
      )

      conn = get(conn, ~p"/music/track/sneaky.mp3")

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-type") == ["audio/mpeg"]
    end

    test "does not mark a track immutable", %{conn: conn} do
      # A library name is reusable after a delete, so the bytes behind it can
      # change. Caching it forever would serve the deleted track.
      conn = get(conn, ~p"/music/track/song.mp3")
      assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
    end
  end

  describe "satisfiable ranges" do
    test "a closed range returns 206 with the slice", %{conn: conn} do
      conn = ranged(conn, "bytes=0-4")

      assert conn.status == 206
      assert conn.resp_body == "abcde"
      assert get_resp_header(conn, "content-range") == ["bytes 0-4/#{@size}"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    end

    test "a mid-file closed range", %{conn: conn} do
      conn = ranged(conn, "bytes=10-12")

      assert conn.status == 206
      assert conn.resp_body == "klm"
      assert get_resp_header(conn, "content-range") == ["bytes 10-12/#{@size}"]
    end

    test "an open-ended range runs to EOF — this is what WKWebView opens with",
         %{conn: conn} do
      conn = ranged(conn, "bytes=0-")

      assert conn.status == 206
      assert conn.resp_body == @body
      assert get_resp_header(conn, "content-range") == ["bytes 0-25/#{@size}"]
    end

    test "an open-ended range from the middle", %{conn: conn} do
      conn = ranged(conn, "bytes=23-")

      assert conn.status == 206
      assert conn.resp_body == "xyz"
      assert get_resp_header(conn, "content-range") == ["bytes 23-25/#{@size}"]
    end

    test "a suffix range returns the LAST n bytes", %{conn: conn} do
      conn = ranged(conn, "bytes=-3")

      assert conn.status == 206
      assert conn.resp_body == "xyz"
      assert get_resp_header(conn, "content-range") == ["bytes 23-25/#{@size}"]
    end

    test "a suffix longer than the file is the whole file", %{conn: conn} do
      conn = ranged(conn, "bytes=-9999")

      assert conn.status == 206
      assert conn.resp_body == @body
      assert get_resp_header(conn, "content-range") == ["bytes 0-25/#{@size}"]
    end

    test "an end past EOF is clamped, not refused", %{conn: conn} do
      conn = ranged(conn, "bytes=20-9999")

      assert conn.status == 206
      assert conn.resp_body == "uvwxyz"
      assert get_resp_header(conn, "content-range") == ["bytes 20-25/#{@size}"]
    end

    test "the final single byte — the off-by-one that range code gets wrong",
         %{conn: conn} do
      conn = ranged(conn, "bytes=25-25")

      assert conn.status == 206
      assert conn.resp_body == "z"
      assert get_resp_header(conn, "content-range") == ["bytes 25-25/#{@size}"]
    end

    test "the first single byte", %{conn: conn} do
      conn = ranged(conn, "bytes=0-0")

      assert conn.status == 206
      assert conn.resp_body == "a"
      assert get_resp_header(conn, "content-range") == ["bytes 0-0/#{@size}"]
    end
  end

  describe "unsatisfiable ranges" do
    test "a first byte past EOF is 416 with the size", %{conn: conn} do
      conn = ranged(conn, "bytes=100-200")

      assert conn.status == 416
      assert get_resp_header(conn, "content-range") == ["bytes */#{@size}"]
    end

    test "a first byte exactly at EOF is past the last byte", %{conn: conn} do
      # Byte @size does not exist; the last one is @size - 1.
      conn = ranged(conn, "bytes=#{@size}-")

      assert conn.status == 416
    end

    test "a zero-length suffix asks for nothing", %{conn: conn} do
      conn = ranged(conn, "bytes=-0")

      assert conn.status == 416
      assert get_resp_header(conn, "content-range") == ["bytes */#{@size}"]
    end
  end

  describe "malformed ranges fall through to the whole file" do
    test "ignoring a header we can't parse is safer than refusing it", %{conn: conn} do
      for bad <- [
            "bytes=abc-def",
            "bytes=-",
            "bytes=",
            "bytes=1-2-3",
            "bytes=500-100",
            "items=0-5",
            "0-5",
            "garbage",
            "bytes=1.5-2",
            "bytes= -5"
          ] do
        conn = ranged(recycle(conn), bad)

        assert conn.status == 200, "expected #{inspect(bad)} to fall through to 200"
        assert conn.resp_body == @body
        assert get_resp_header(conn, "content-range") == []
      end
    end

    test "a multi-range request gets the whole file, not a wrong slice", %{conn: conn} do
      # A correct answer needs multipart/byteranges. Nothing in this app sends
      # one, and RFC 7233 permits ignoring the header entirely.
      conn = ranged(conn, "bytes=0-4,10-14")

      assert conn.status == 200
      assert conn.resp_body == @body
    end

    test "two Range headers is malformed, not two ranges", %{conn: conn} do
      # put_req_header/3 REPLACES, so the duplicate has to be built by hand —
      # otherwise this test would silently assert on a single header and pass
      # for the wrong reason.
      conn = %{conn | req_headers: [{"range", "bytes=0-4"}, {"range", "bytes=5-9"}]}

      conn = get(conn, ~p"/music/track/song.mp3")

      assert conn.status == 200
      assert conn.resp_body == @body
      assert get_resp_header(conn, "content-range") == []
    end
  end

  describe "HEAD" do
    test "reports size and range support without a body", %{conn: conn} do
      conn = head(conn, ~p"/music/track/song.mp3")

      assert conn.status == 200
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "content-type") == ["audio/mpeg"]
      assert conn.resp_body == ""
    end
  end

  describe "edge cases" do
    test "a zero-byte file serves empty, and every range is unsatisfiable", %{
      conn: conn,
      root: root
    } do
      File.write!(Path.join([root, "sounds", "music", "empty.mp3"]), "")

      plain = get(conn, ~p"/music/track/empty.mp3")
      assert plain.status == 200
      assert plain.resp_body == ""

      for range <- ["bytes=0-", "bytes=0-0", "bytes=-1"] do
        ranged =
          recycle(conn) |> put_req_header("range", range) |> get(~p"/music/track/empty.mp3")

        assert ranged.status == 416, "expected #{range} on an empty file to be unsatisfiable"
        assert get_resp_header(ranged, "content-range") == ["bytes */0"]
      end
    end

    test "a name with spaces and punctuation round-trips", %{conn: conn, root: root} do
      name = "Miles Davis - So What (Take 1).mp3"
      File.write!(Path.join([root, "sounds", "music", name]), @body)

      conn = get(conn, ~p"/music/track/#{name}")

      assert conn.status == 200
      assert conn.resp_body == @body
    end

    test "content-type follows the extension", %{conn: conn, root: root} do
      File.write!(Path.join([root, "sounds", "music", "track.flac"]), @body)

      conn = get(conn, ~p"/music/track/track.flac")

      assert get_resp_header(conn, "content-type") == ["audio/flac"]
    end
  end

  describe "404s — the allowlist is the guard" do
    test "an unknown name", %{conn: conn} do
      assert get(conn, ~p"/music/track/nope.mp3").status == 404
    end

    test "a non-audio file that really is in the folder", %{conn: conn, root: root} do
      File.write!(Path.join([root, "sounds", "music", "notes.txt"]), "secret")

      assert get(conn, ~p"/music/track/notes.txt").status == 404
    end

    test "traversal, however it is spelled", %{conn: conn, root: root} do
      File.write!(Path.join(root, "secret.mp3"), "secret")

      for attempt <- ["../secret.mp3", "..%2Fsecret.mp3", "%2e%2e%2fsecret.mp3", "..", "."] do
        conn = get(recycle(conn), "/music/track/#{attempt}")
        assert conn.status == 404, "expected #{inspect(attempt)} to 404"
        refute conn.resp_body == "secret"
      end
    end
  end
end
