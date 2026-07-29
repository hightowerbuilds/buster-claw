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

  describe "safe_name/1" do
    test "keeps the Artist - Title convention intact" do
      # The interaction that matters: Sound's sanitizer replaces every non-word
      # character INCLUDING spaces, which would turn this into
      # "Miles-Davis---So-What.mp3" and make track_info/1 find no separator.
      assert Music.safe_name("Miles Davis - So What.mp3") == "Miles Davis - So What.mp3"

      assert Music.track_info(Music.safe_name("Miles Davis - So What.mp3")).artist ==
               "Miles Davis"
    end

    test "keeps punctuation music filenames actually use" do
      assert Music.safe_name("Sigur Rós - Hoppípolla (Live) [Remaster].mp3") ==
               "Sigur Rós - Hoppípolla (Live) [Remaster].mp3"

      assert Music.safe_name("Guns N' Roses - Sweet Child O' Mine.mp3") ==
               "Guns N' Roses - Sweet Child O' Mine.mp3"
    end

    test "reduces a path to its last segment" do
      assert Music.safe_name("../../etc/passwd.mp3") == "passwd.mp3"
      assert Music.safe_name("/etc/shadow.mp3") == "shadow.mp3"
      assert Music.safe_name("a/b/c/song.mp3") == "song.mp3"
    end

    test "replaces characters that are not filename material" do
      assert Music.safe_name("AC/DC: T*N*T?.mp3") == "DC- T-N-T-.mp3"
      assert Music.safe_name("null\0byte.mp3") == "null-byte.mp3"
    end

    test "never produces a dotfile" do
      assert Music.safe_name(".hidden.mp3") == "hidden.mp3"
      assert Music.safe_name("...mp3") == "track.mp3"
    end

    test "falls back to a name when nothing survives" do
      assert Music.safe_name("   .mp3") == "track.mp3"
      assert Music.safe_name("....mp3") == "track.mp3"
      assert Music.safe_name(" . . .mp3") == "track.mp3"
    end

    test "a bare dotfile has no extension, and store/2 agrees" do
      # Path.extname(".mp3") is "" — it is a dotfile named .mp3, not an
      # extension with an empty stem. What matters is that safe_name/1 and
      # store/2 read the extension from the same place, so an upload can never
      # pass the accept check and then land under a name list/0 ignores.
      assert Path.extname(".mp3") == ""
      assert Music.store("/tmp/whatever", ".mp3") == {:error, :unsupported_format}
    end

    test "collapses runs of whitespace" do
      assert Music.safe_name("too    many     spaces.mp3") == "too many spaces.mp3"
    end

    test "downcases the extension but not the name" do
      assert Music.safe_name("SHOUT.MP3") == "SHOUT.mp3"
    end

    test "truncates a long name without splitting a character" do
      long = String.duplicate("é", 400) <> ".mp3"
      name = Music.safe_name(long)

      assert byte_size(name) <= 200
      assert String.valid?(name)
      assert String.ends_with?(name, ".mp3")
    end
  end

  describe "store/2" do
    setup %{root: root} do
      source = Path.join(root, "upload.tmp")
      File.write!(source, "ID3fake-mp3-payload")
      {:ok, source: source}
    end

    test "stores an upload under a sanitized name", %{source: source} do
      assert {:ok, "So What.mp3"} = Music.store(source, "So What.mp3")
      assert Music.list() == ["So What.mp3"]
      assert File.read!(Music.path_for("So What.mp3")) == "ID3fake-mp3-payload"
    end

    test "a hostile name lands as a basename inside the library", %{source: source, root: root} do
      assert {:ok, name} = Music.store(source, "../../etc/passwd.mp3")

      assert name == "passwd.mp3"
      assert Path.dirname(Music.path_for(name)) == Path.join(root, "music")
      # Nothing was written outside the library.
      refute File.exists?(Path.join(Path.dirname(root), "passwd.mp3"))
    end

    test "two uploads of the same name coexist", %{source: source} do
      assert {:ok, "song.mp3"} = Music.store(source, "song.mp3")
      assert {:ok, "song-2.mp3"} = Music.store(source, "song.mp3")
      assert {:ok, "song-3.mp3"} = Music.store(source, "song.mp3")

      assert Music.list() == ["song-2.mp3", "song-3.mp3", "song.mp3"]
    end

    test "an existing track is never overwritten", %{source: source, root: root} do
      File.write!(Path.join([root, "music", "song.mp3"]), "the original")

      assert {:ok, "song-2.mp3"} = Music.store(source, "song.mp3")
      assert File.read!(Path.join([root, "music", "song.mp3"])) == "the original"
    end

    test "rejects an extension the library does not accept", %{source: source} do
      assert Music.store(source, "document.pdf") == {:error, :unsupported_format}
      assert Music.store(source, "script.sh") == {:error, :unsupported_format}
      assert Music.store(source, "noextension") == {:error, :unsupported_format}
      assert Music.list() == []
    end

    test "rejects a non-audio file wearing an audio extension", %{root: root} do
      # The picker's accept list is a client-side convenience; this is the check
      # that actually holds.
      pdf = Path.join(root, "doc.tmp")
      File.write!(pdf, "%PDF-1.7\nnot music at all")

      assert Music.store(pdf, "totally-a-song.mp3") == {:error, :not_audio}
      assert Music.list() == []
    end

    test "rejects an HTML document renamed to .mp3 — the stored-XSS shape", %{root: root} do
      html = Path.join(root, "evil.tmp")
      File.write!(html, "<html><script>alert(1)</script></html>")

      assert Music.store(html, "song.mp3") == {:error, :not_audio}
    end

    test "accepts every container the library claims to support", %{root: root} do
      for {magic, name} <- [
            {"ID3\x03payload", "tagged.mp3"},
            {<<0xFF, 0xFB, 0x90, 0x00>>, "bare.mp3"},
            {"RIFF....WAVE", "sound.wav"},
            {"fLaC\x00\x00\x00", "lossless.flac"},
            {"OggS\x00\x02\x00", "vorbis.ogg"},
            {<<0, 0, 0, 32>> <> "ftypM4A ", "apple.m4a"},
            {<<0xFF, 0xF1, 0x50, 0x80>>, "adts.aac"}
          ] do
        source = Path.join(root, "src.tmp")
        File.write!(source, magic)

        assert {:ok, ^name} = Music.store(source, name), "expected #{name} to be accepted"
      end
    end

    test "an unrecognized header is accepted, not refused", %{root: root} do
      # The deliberate default. Rejecting music the user owns is worse than
      # storing something that turns out not to play.
      source = Path.join(root, "odd.tmp")
      File.write!(source, "\x01\x02\x03\x04 who knows")

      assert {:ok, "odd.mp3"} = Music.store(source, "odd.mp3")
    end

    test "reports a missing source rather than raising", %{root: root} do
      assert Music.store(Path.join(root, "gone.tmp"), "song.mp3") == {:error, :enoent}
    end

    test "refuses a directory as a source", %{root: root} do
      dir = Path.join(root, "adir")
      File.mkdir_p!(dir)

      assert Music.store(dir, "song.mp3") == {:error, :enoent}
    end

    test "refuses non-binary arguments" do
      assert Music.store(nil, "song.mp3") == {:error, :unsupported_format}
      assert Music.store("/tmp/x", nil) == {:error, :unsupported_format}
    end

    test "creates the library folder if it is missing", %{source: source, root: root} do
      File.rm_rf!(Path.join(root, "music"))

      assert {:ok, "song.mp3"} = Music.store(source, "song.mp3")
      assert Music.list() == ["song.mp3"]
    end

    test "anything store/2 accepts is visible in the library — no silent vanishing",
         %{source: source} do
      # The invariant that a mismatch between the accept check and the naming
      # broke once: store/2 reported {:ok, name} for "   .mp3" while writing a
      # file called "track", which has no audio extension and so never appeared
      # in list/0. A success message for a track that is not there is the worst
      # of both outcomes, so the rule is pinned rather than left to the two
      # functions happening to agree.
      hostile = [
        "   .mp3",
        "...mp3",
        ".hidden.mp3",
        "../../etc/passwd.mp3",
        "AC/DC: T*N*T?.mp3",
        "SHOUT.MP3",
        "....mp3",
        String.duplicate("é", 400) <> ".mp3",
        "Sigur Rós - Hoppípolla (Live).flac"
      ]

      for name <- hostile do
        assert {:ok, stored} = Music.store(source, name), "expected #{inspect(name)} to store"

        assert stored in Music.list(),
               "#{inspect(name)} stored as #{inspect(stored)}, which list/0 does not show"

        assert Music.path_for(stored) != nil
      end
    end

    test "a stored upload is immediately reachable through the allowlist", %{source: source} do
      {:ok, name} = Music.store(source, "Artist - Title.mp3")

      # The whole loop: uploaded bytes are servable by path_for/1 the moment
      # they land, with no separate registration step.
      assert Music.path_for(name) != nil
      assert Music.track_info(name).artist == "Artist"
      assert Music.total_bytes() > 0
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
