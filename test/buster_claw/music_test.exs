defmodule BusterClaw.MusicTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Music

  setup do
    root = Path.join(System.tmp_dir!(), "bc_music_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "music"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp track(root, name, contents \\ "x") do
    path = Path.join([root, "music", name])
    File.write!(path, contents)
    path
  end

  describe "the empty library" do
    test "lists nothing and reports nothing playable" do
      assert Music.list() == []
      assert Music.tracks() == []
      refute Music.any?()
      assert Music.total_bytes() == 0
    end

    test "survives the folder not existing at all", %{root: root} do
      File.rm_rf!(Path.join(root, "music"))

      # File.ls/1 errors here; the library reports empty rather than raising,
      # because the user can delete this folder in Finder at any time.
      assert Music.list() == []
      refute Music.any?()
      assert Music.total_bytes() == 0
    end
  end

  describe "list/0" do
    test "returns only audio files", %{root: root} do
      track(root, "song.mp3")
      track(root, "notes.txt")
      track(root, "README.md")
      track(root, "cover.jpg")

      assert Music.list() == ["song.mp3"]
    end

    test "accepts every declared extension", %{root: root} do
      for ext <- Music.accepted_extensions(), do: track(root, "song#{ext}")

      assert length(Music.list()) == length(Music.accepted_extensions())
    end

    test "matches extensions case-insensitively", %{root: root} do
      track(root, "SHOUT.MP3")
      track(root, "quiet.FlAc")

      assert Music.list() == ["quiet.FlAc", "SHOUT.MP3"]
    end

    test "sorts case-insensitively", %{root: root} do
      track(root, "apple.mp3")
      track(root, "Banana.mp3")
      track(root, "cherry.mp3")

      # A plain Enum.sort/1 would file "Banana.mp3" first — the departure from
      # Sound.list/0 that the moduledoc explains.
      assert Music.list() == ["apple.mp3", "Banana.mp3", "cherry.mp3"]
    end

    test "ignores a directory that happens to be named like a track", %{root: root} do
      File.mkdir_p!(Path.join([root, "music", "album.mp3"]))
      track(root, "real.mp3")

      assert Music.list() == ["real.mp3"]
    end
  end

  describe "path_for/1 — the allowlist is the path guard" do
    test "resolves a real library track", %{root: root} do
      path = track(root, "song.mp3")

      assert Music.path_for("song.mp3") == path
    end

    test "refuses a name that is not in the library" do
      assert Music.path_for("nope.mp3") == nil
    end

    test "refuses traversal, because a traversal string is never a basename", %{root: root} do
      track(root, "song.mp3")
      File.write!(Path.join(root, "secret.mp3"), "x")

      for attempt <- [
            "../secret.mp3",
            "../../etc/passwd",
            "music/song.mp3",
            "./song.mp3",
            "/etc/passwd",
            "..",
            ""
          ] do
        assert Music.path_for(attempt) == nil, "expected #{inspect(attempt)} to be refused"
      end
    end

    test "refuses a non-binary name" do
      assert Music.path_for(nil) == nil
      assert Music.path_for(:song) == nil
    end

    test "refuses a non-audio file that really is in the folder", %{root: root} do
      track(root, "notes.txt")

      # Present on disk, absent from list/0 — so it is not reachable. The
      # allowlist gates the extension check too, not just traversal.
      assert File.exists?(Path.join([root, "music", "notes.txt"]))
      assert Music.path_for("notes.txt") == nil
    end
  end

  describe "track_info/1" do
    test "splits Artist - Title", %{root: root} do
      track(root, "Miles Davis - So What.mp3")

      info = Music.track_info("Miles Davis - So What.mp3")

      assert info.artist == "Miles Davis"
      assert info.title == "So What"
      assert info.extension == ".mp3"
      assert info.content_type == "audio/mpeg"
      assert info.name == "Miles Davis - So What.mp3"
    end

    test "leaves artist nil when there is no separator", %{root: root} do
      track(root, "untitled sketch.wav")

      info = Music.track_info("untitled sketch.wav")

      assert info.artist == nil
      assert info.title == "untitled sketch"
    end

    test "splits only on the first separator", %{root: root} do
      track(root, "Artist - Title - Live Version.mp3")

      info = Music.track_info("Artist - Title - Live Version.mp3")

      assert info.artist == "Artist"
      assert info.title == "Title - Live Version"
    end

    test "does not split a hyphen without spaces", %{root: root} do
      track(root, "Blink-182.mp3")

      info = Music.track_info("Blink-182.mp3")

      assert info.artist == nil
      assert info.title == "Blink-182"
    end

    test "falls back to the filename when the title side is empty", %{root: root} do
      track(root, "Artist - .mp3")

      info = Music.track_info("Artist - .mp3")

      # Never render an empty string as a title.
      assert info.title == "Artist - .mp3"
    end

    test "reports size, and nil for a track that vanished", %{root: root} do
      track(root, "song.mp3", "0123456789")

      assert Music.track_info("song.mp3").size_bytes == 10
      assert Music.track_info("ghost.mp3").size_bytes == nil
    end

    test "tracks/0 maps the whole library in list order", %{root: root} do
      track(root, "b - two.mp3")
      track(root, "A - one.mp3")

      assert Enum.map(Music.tracks(), & &1.title) == ["one", "two"]
      assert Enum.map(Music.tracks(), & &1.artist) == ["A", "b"]
    end
  end

  describe "content_type/1" do
    test "maps every accepted extension to an audio type" do
      for ext <- Music.accepted_extensions() do
        assert Music.content_type("song#{ext}") =~ ~r{^audio/}
      end
    end

    test "is case-insensitive" do
      assert Music.content_type("SONG.MP3") == "audio/mpeg"
    end

    test "does not guess audio for an unknown extension" do
      # An honest octet-stream beats a wrong audio type: the element would try
      # to decode the latter.
      assert Music.content_type("notes.txt") == "application/octet-stream"
      assert Music.content_type("noext") == "application/octet-stream"
    end
  end

  describe "delete/1" do
    test "removes a library track", %{root: root} do
      path = track(root, "song.mp3")

      assert Music.delete("song.mp3") == :ok
      refute File.exists?(path)
      assert Music.list() == []
    end

    test "refuses anything not in the library", %{root: root} do
      outside = Path.join(root, "secret.mp3")
      File.write!(outside, "x")
      track(root, "notes.txt")

      assert Music.delete("../secret.mp3") == {:error, :not_found}
      assert Music.delete("notes.txt") == {:error, :not_found}
      assert Music.delete("ghost.mp3") == {:error, :not_found}
      assert Music.delete(nil) == {:error, :not_found}

      assert File.exists?(outside)
    end
  end

  describe "total_bytes/0 and any?/0" do
    test "sum only counts library files", %{root: root} do
      track(root, "a.mp3", String.duplicate("x", 100))
      track(root, "b.flac", String.duplicate("x", 50))
      track(root, "notes.txt", String.duplicate("x", 999))

      assert Music.total_bytes() == 150
      assert Music.any?()
    end
  end

  describe "ensure/0" do
    test "creates the folder and a README", %{root: root} do
      File.rm_rf!(Path.join(root, "music"))

      assert Music.ensure() == :ok
      assert File.dir?(Music.dir())
      assert File.exists?(Path.join(Music.dir(), "README.md"))
    end

    test "does not overwrite an existing README", %{root: root} do
      readme = Path.join([root, "music", "README.md"])
      File.write!(readme, "mine")

      assert Music.ensure() == :ok
      assert File.read!(readme) == "mine"
    end

    test "is idempotent and leaves the library alone", %{root: root} do
      track(root, "song.mp3")

      assert Music.ensure() == :ok
      assert Music.ensure() == :ok
      assert Music.list() == ["song.mp3"]
    end

    test "the README is not itself a track", %{root: root} do
      File.rm_rf!(Path.join(root, "music"))
      Music.ensure()

      assert Music.list() == []
    end
  end
end
