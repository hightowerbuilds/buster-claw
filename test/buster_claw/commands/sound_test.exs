defmodule BusterClaw.Commands.SoundTest do
  # async: false — points the global :workspace_root at a tmp dir, which is how
  # both the sound library and the studio folder resolve.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Commands
  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Notifications.SoundGen
  alias BusterClaw.Telephony

  # afconvert is a macOS system binary, but the suite should not fail on a
  # machine without it — the decode-dependent cases are skipped instead, the
  # same way `sound_studio_test.exs` handles them.
  @decoder_available File.regular?("/usr/bin/afconvert")

  setup do
    root = Path.join(System.tmp_dir!(), "bc_cmd_sound_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([root, "sounds", "studio"]))
    # The Library root is where a telephony recording_path resolves from, which
    # is what decides whether a transcript hit is cuttable.
    File.mkdir_p!(Path.join(root, "library"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    prev_library = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      Application.put_env(:buster_claw, :library_root, prev_library)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  # A real WAV, in the studio's internal format — the same bytes the app ships
  # as a chime, so probe has something honest to read.
  defp wav, do: SoundGen.render("boot")

  defp library(root, name, contents \\ nil),
    do: File.write!(Path.join([root, "sounds", name]), contents || wav())

  defp source(root, name, contents \\ nil),
    do: File.write!(Path.join([root, "sounds", "studio", name]), contents || wav())

  defp entry(%{sounds: sounds}, name), do: Enum.find(sounds, &(&1.name == name))
  defp route(%{routes: routes}, key), do: Enum.find(routes, &(&1.key == key))

  # A voicemail row. `recording_path` is relative to the Library root; pass
  # `on_disk: false` for the row whose audio is missing, which is the shape a dev
  # workspace is full of.
  defp voicemail(root, transcript, opts \\ []) do
    n = System.unique_integer([:positive])
    name = "voicemail-#{n}.wav"

    if Keyword.get(opts, :on_disk, true) do
      File.write!(Path.join([root, "library", name]), wav())
    end

    {:ok, event} =
      Telephony.record_event(
        %{
          direction: "inbound",
          kind: "voicemail",
          from_number: "+15035551234",
          to_number: "+18446878016",
          twilio_sid: "RE#{n}",
          duration_seconds: 10,
          transcript: transcript,
          recording_path: name,
          occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        observe: false
      )

    event
  end

  # A file under the Library root, at a path relative to it — the shape
  # `recording_path` has, and the only shape `sound_import` accepts.
  defp recording(root, relative, contents \\ nil) do
    path = Path.join([root, "library", relative])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents || wav())
    relative
  end

  # The same, encoded as AAC — a real non-WAV whose peak cannot be read without
  # decoding it, which is the whole point of `decode: true`.
  defp compressed(root, relative) do
    source = Path.join(root, "encode-src.wav")
    File.write!(source, wav())
    target = Path.join([root, "library", relative])
    File.mkdir_p!(Path.dirname(target))

    {_out, 0} =
      System.cmd("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", source, target],
        stderr_to_stdout: true
      )

    relative
  end

  defp studio_entries(root), do: root |> Path.join("sounds/studio") |> File.ls!() |> Enum.sort()

  # A word list of the shape a recognizer (or a hand-authored fixture) supplies,
  # with wire-style string keys.
  defp words(specs) do
    Enum.map(specs, fn {text, from, to} ->
      %{"text" => text, "start_ms" => from, "end_ms" => to, "confidence" => 0.9}
    end)
  end

  # Two spans inside the fixture chime, in the order they should be spoken.
  defp cuts do
    [
      %{"source" => "voicemail-03.wav", "start_ms" => 100, "end_ms" => 200},
      %{"source" => "voicemail-03.wav", "start_ms" => 400, "end_ms" => 560}
    ]
  end

  describe "sound_list" do
    test "reports both layers, and which one wins", %{root: root} do
      library(root, "bongos.wav")

      assert {:ok, listing} = Commands.Sound.sound_list()

      # A workspace-only file is the workspace layer and shadows nothing.
      assert %{layer: "workspace", in_workspace: true, in_bundled: false, shadowing: false} =
               entry(listing, "bongos.wav")

      # A bundled default with no workspace copy resolves from the bundle.
      bundled = entry(listing, "boot.wav")

      assert %{layer: "bundled", in_workspace: false, in_bundled: true, shadowing: false} =
               bundled

      assert bundled.path == Path.join(Sound.bundled_dir(), "boot.wav")

      refute "bongos.wav" in listing.shadowed
      assert listing.counts.workspace == 1
      assert listing.counts.bundled > 0
      assert listing.workspace_dir == Sound.dir()
      assert is_boolean(listing.enabled)
    end

    test "a workspace file with a bundled name is marked as shadowing it", %{root: root} do
      # The exact case behind "I replaced the chime and nothing changed": the
      # workspace copy wins by basename, silently, with no routing entry.
      library(root, "confirm.wav")

      assert {:ok, listing} = Commands.Sound.sound_list()

      assert %{
               layer: "workspace",
               in_workspace: true,
               in_bundled: true,
               shadowing: true
             } = entry(listing, "confirm.wav")

      # Named once, not twice — and the shadow is called out at the top level.
      assert Enum.count(listing.sounds, &(&1.name == "confirm.wav")) == 1
      assert "confirm.wav" in listing.shadowed
      assert entry(listing, "confirm.wav").path == Path.join(Sound.dir(), "confirm.wav")
    end
  end

  describe "sound_routes" do
    test "every routing key appears, labelled, with what plays" do
      assert {:ok, table} = Commands.Sound.sound_routes()

      keys = Enum.map(table.routes, & &1.key)
      assert Enum.sort(keys) == Enum.sort(Sound.route_keys())
      assert table.counts.keys == length(Sound.route_keys())

      # Display order leads with the catch-all, as Settings does.
      assert hd(keys) == "default"
      assert route(table, "voicemail").label == "Voicemail"

      # Nothing assigned: the bundled default is the floor, and the answer is
      # marked as a fallback rather than an operator choice.
      timer = route(table, "timer")
      assert timer.assigned == nil
      assert timer.plays == "timer.wav"
      assert timer.plays_layer == "bundled"
      assert timer.origin == "fallback"
    end

    test "explicit, inherited, and silent routes are distinguished" do
      assert :ok = Sound.assign("voicemail", "boot.wav")
      assert :ok = Sound.assign("chat", Sound.silent())
      assert :ok = Sound.assign("default", "alarm.wav")

      assert {:ok, table} = Commands.Sound.sound_routes()

      assert %{
               assigned: "boot.wav",
               plays: "boot.wav",
               plays_layer: "bundled",
               origin: "explicit"
             } =
               route(table, "voicemail")

      # Silent is a definitive answer, not an inherit — it plays nothing.
      assert %{assigned: "silent", plays: nil, origin: "silent"} = route(table, "chat")

      # A key with no entry of its own rides "default".
      assert %{assigned: nil, plays: "alarm.wav", origin: "inherited"} = route(table, "manual")

      assert table.silent_value == Sound.silent()
      assert table.counts.silent >= 1
    end
  end

  describe "sound_sources" do
    test "lists the studio's imported clips and the decoder's availability", %{root: root} do
      source(root, "voicemail-03.wav")

      assert {:ok, listing} = Commands.Sound.sound_sources()

      assert [%{name: "voicemail-03.wav", bytes: bytes, path: path}] = listing.sources
      assert bytes > 0
      assert path == Path.join([root, "sounds", "studio", "voicemail-03.wav"])
      assert listing.count == 1
      assert is_boolean(listing.decoder_available)
      assert listing.internal_format == %{sample_rate: 22_050, channels: 1, bits: 16}
    end

    test "the routed library is not the studio", %{root: root} do
      library(root, "bongos.wav")

      assert {:ok, %{sources: [], count: 0}} = Commands.Sound.sound_sources()
    end
  end

  describe "sound_probe" do
    test "describes a real WAV: format, duration, peak, internal", %{root: root} do
      library(root, "chime.wav")

      assert {:ok, probe} = Commands.Sound.sound_probe(%{"name" => "chime.wav"})

      assert probe.layer == "workspace"
      assert probe.path == Path.join(Sound.dir(), "chime.wav")
      assert probe.sample_rate == 22_050
      assert probe.channels == 1
      assert probe.bits == 16
      assert probe.internal
      assert probe.duration_ms > 0
      assert probe.peak > 0.0
      assert probe.bytes == byte_size(wav())
      assert probe.internal_format == %{sample_rate: 22_050, channels: 1, bits: 16}
      assert is_boolean(probe.decoder_available)
      assert is_list(probe.notes)
    end

    test "resolves the bundled layer, and a studio source", %{root: root} do
      source(root, "clip.wav")

      assert {:ok, %{layer: "bundled", internal: true}} =
               Commands.Sound.sound_probe(%{"name" => "boot.wav"})

      assert {:ok, %{layer: "studio", internal: true}} =
               Commands.Sound.sound_probe(%{"name" => "clip.wav"})
    end

    test "a workspace file outranks the bundled default of the same name", %{root: root} do
      library(root, "confirm.wav")

      assert {:ok, probe} = Commands.Sound.sound_probe(%{"name" => "confirm.wav"})
      assert probe.layer == "workspace"
      assert probe.path == Path.join(Sound.dir(), "confirm.wav")
    end

    test "something that is not a WAV reports no peak and says why", %{root: root} do
      library(root, "prose.wav", "this is not audio")

      assert {:ok, probe} = Commands.Sound.sound_probe(%{"name" => "prose.wav"})

      refute probe.internal
      assert probe.peak == nil
      assert probe.bits == nil
      assert Enum.any?(probe.notes, &(&1 =~ "Not readable as a WAV"))
    end

    test "a name that isn't there is a named error, not a raise" do
      assert {:error, :not_found} = Commands.Sound.sound_probe(%{"name" => "nope.wav"})
      assert {:error, :missing_name} = Commands.Sound.sound_probe(%{})
    end

    test "paths and traversal are refused before anything looks at the disk" do
      for attempt <- [
            "../../etc/passwd",
            "..",
            "/etc/passwd",
            "sounds/boot.wav",
            "studio\\boot.wav",
            "   "
          ] do
        assert {:error, :invalid_name} = Commands.Sound.sound_probe(%{"name" => attempt}),
               "expected #{inspect(attempt)} to be refused as an invalid name"
      end
    end
  end

  describe "sound_probe reaching the Library" do
    test "probes the recording an event names", %{root: root} do
      event = voicemail(root, "meet me at the harbor")

      assert {:ok, probe} = Commands.Sound.sound_probe(%{"event_id" => event.id})

      assert probe.layer == "library"
      assert probe.event_id == event.id
      assert probe.library_path == event.recording_path
      assert probe.name == Path.basename(event.recording_path)
      assert probe.path == Path.join([root, "library", event.recording_path])
      # This fixture is already a WAV in the internal format, so the cheap path
      # answers everything and no decode is needed.
      assert probe.internal
      assert probe.peak > 0.0
      refute probe.decoded
    end

    test "probes a Library-relative path", %{root: root} do
      recording(root, "calls/take-1.wav")

      assert {:ok, probe} = Commands.Sound.sound_probe(%{"path" => "calls/take-1.wav"})

      assert probe.layer == "library"
      assert probe.library_path == "calls/take-1.wav"
      assert probe.event_id == nil
      assert probe.internal
    end

    test "absolute paths and traversal are refused here too" do
      for {attempt, reason} <- [
            {"/etc/passwd", :absolute_path},
            {"~/.ssh/id_rsa", :absolute_path},
            {"../../etc/passwd", :traversal},
            {"calls/../../../etc/passwd", :traversal}
          ] do
        assert {:error, ^reason} = Commands.Sound.sound_probe(%{"path" => attempt}),
               "expected #{inspect(attempt)} to be refused as #{reason}"
      end
    end

    test "a bare name still resolves the three sound stores, and no input is named", %{
      root: root
    } do
      library(root, "chime.wav")

      assert {:ok, %{layer: "workspace", event_id: nil, library_path: nil}} =
               Commands.Sound.sound_probe(%{"name" => "chime.wav"})

      assert {:error, :missing_name} = Commands.Sound.sound_probe(%{"decode" => true})
    end

    if @decoder_available do
      test "decode: true measures a peak the default path cannot", %{root: root} do
        compressed(root, "vm-take.m4a")

        assert {:ok, blind} = Commands.Sound.sound_probe(%{"path" => "vm-take.m4a"})

        # The Phase 0 gap, reproduced: an m4a cannot be parsed as a WAV, so
        # peak — the level fact that decides whether a cut is intelligible — is
        # simply absent, and the note says how to get it.
        assert blind.peak == nil
        refute blind.decoded
        refute blind.internal
        assert blind.duration_ms > 0
        assert Enum.any?(blind.notes, &(&1 =~ "decode: true"))

        assert {:ok, heard} =
                 Commands.Sound.sound_probe(%{"path" => "vm-take.m4a", "decode" => true})

        assert heard.decoded
        assert heard.peak > 0.0
        assert heard.duration_ms > 0
        # The file's own format is still reported from the header, never
        # overwritten by what the decoder converted it to.
        refute heard.internal
        assert Enum.any?(heard.notes, &(&1 =~ "measured by decoding"))
      end

      test "decode: true on a file that already parsed costs nothing", %{root: root} do
        library(root, "chime.wav")

        assert {:ok, probe} =
                 Commands.Sound.sound_probe(%{"name" => "chime.wav", "decode" => true})

        # Nothing to learn from a decode here, so none is run.
        refute probe.decoded
        assert probe.peak > 0.0
      end
    end
  end

  describe "sound_import" do
    test "brings the recording an event names into the studio", %{root: root} do
      event = voicemail(root, "meet me at the harbor")

      assert {:ok, result} = Commands.Sound.sound_import(%{"event_id" => event.id})

      assert result.event_id == event.id
      assert result.library_path == event.recording_path
      assert result.name == Path.basename(event.recording_path)
      assert result.path == Path.join([root, "sounds", "studio", result.name])
      assert File.regular?(result.path)
      refute result.replaced

      # It is stored in the internal format, which is what makes it cuttable.
      assert result.internal
      assert result.sample_rate == 22_050
      assert result.channels == 1
      assert result.bits == 16
      assert result.peak > 0.0
      assert result.duration_ms > 0
      assert result.bytes > 0
      # A WAV already in the internal format never reaches the decoder.
      refute result.decoded

      # And the whole point: it is now a source the rest of the surface can see.
      assert {:ok, %{sources: sources}} = Commands.Sound.sound_sources()
      assert Enum.any?(sources, &(&1.name == result.name))

      assert {:ok, %{layer: "studio", internal: true}} =
               Commands.Sound.sound_probe(%{"name" => result.name})

      # A source, not a chime: nothing entered the routed library.
      assert {:ok, %{sounds: sounds}} = Commands.Sound.sound_list()
      refute Enum.any?(sounds, &(&1.name == result.name))
      assert Enum.any?(result.notes, &(&1 =~ "SOURCE"))
    end

    test "brings in a Library-relative path, under a name of your choosing", %{root: root} do
      recording(root, "calls/take-1.wav")

      assert {:ok, named} =
               Commands.Sound.sound_import(%{"path" => "calls/take-1.wav", "name" => "harbor"})

      assert named.name == "harbor.wav"
      assert named.library_path == "calls/take-1.wav"
      assert named.event_id == nil
      assert File.regular?(Path.join([root, "sounds", "studio", "harbor.wav"]))

      # With no name, one is derived from the source's basename.
      assert {:ok, derived} = Commands.Sound.sound_import(%{"path" => "calls/take-1.wav"})
      assert derived.name == "take-1.wav"
    end

    test "the stored name is always a .wav basename", %{root: root} do
      recording(root, "take.wav")

      # An extension that lies about the container is corrected, and a name
      # carrying directories never reaches the disk at all.
      assert {:ok, %{name: "harbor.wav"}} =
               Commands.Sound.sound_import(%{"path" => "take.wav", "name" => "harbor.mp3"})

      assert {:error, :invalid_name} =
               Commands.Sound.sound_import(%{"path" => "take.wav", "name" => "../escape.wav"})

      assert {:error, :invalid_name} =
               Commands.Sound.sound_import(%{"path" => "take.wav", "name" => "/tmp/escape.wav"})
    end

    test "absolute paths and traversal are refused before the disk is touched", %{root: root} do
      before = studio_entries(root)
      File.write!(Path.join(root, "outside.wav"), wav())

      for {attempt, reason} <- [
            {"/etc/passwd", :absolute_path},
            {"/", :absolute_path},
            {"~/.ssh/id_rsa", :absolute_path},
            {"..", :traversal},
            {"../outside.wav", :traversal},
            {"../../etc/passwd", :traversal},
            {"calls/../../outside.wav", :traversal},
            {"calls/../../../etc/passwd", :traversal},
            {"a/../b.wav", :traversal},
            {"", :invalid_path},
            {"   ", :invalid_path},
            {"calls//take.wav", :invalid_path},
            {"take.wav\0.txt", :invalid_path}
          ] do
        assert {:error, ^reason} = Commands.Sound.sound_import(%{"path" => attempt}),
               "expected #{inspect(attempt)} to be refused as #{reason}"
      end

      # Not one of them wrote anything.
      assert studio_entries(root) == before
    end

    test "a missing event, a missing recording, and a missing file are each named", %{
      root: root
    } do
      assert {:error, :event_not_found} = Commands.Sound.sound_import(%{"event_id" => 987_654})
      assert {:error, :invalid_event_id} = Commands.Sound.sound_import(%{"event_id" => "soon"})
      assert {:error, :invalid_event_id} = Commands.Sound.sound_import(%{"event_id" => -1})

      # A row whose audio was pruned, moved, or never fetched.
      gone = voicemail(root, "nothing on disk", on_disk: false)
      assert {:error, :not_found} = Commands.Sound.sound_import(%{"event_id" => gone.id})

      # An SMS names no recording at all.
      {:ok, sms} =
        Telephony.record_event(
          %{
            direction: "inbound",
            kind: "sms",
            from_number: "+15035551234",
            to_number: "+18446878016",
            twilio_sid: "SM#{System.unique_integer([:positive])}",
            body: "no audio here",
            occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          observe: false
        )

      assert {:error, :no_recording} = Commands.Sound.sound_import(%{"event_id" => sms.id})

      assert {:error, :not_found} = Commands.Sound.sound_import(%{"path" => "nope.wav"})
      assert {:error, :missing_source} = Commands.Sound.sound_import(%{})
    end

    test "it never clobbers an existing source silently", %{root: root} do
      recording(root, "take.wav")

      assert {:ok, %{replaced: false}} =
               Commands.Sound.sound_import(%{"path" => "take.wav", "name" => "clip"})

      assert {:error, :name_taken} =
               Commands.Sound.sound_import(%{"path" => "take.wav", "name" => "clip"})

      assert {:ok, %{replaced: true, name: "clip.wav"}} =
               Commands.Sound.sound_import(%{
                 "path" => "take.wav",
                 "name" => "clip",
                 "overwrite" => true
               })

      # Overwriting replaced the file rather than adding a second one.
      assert Enum.count(studio_entries(root), &(&1 == "clip.wav")) == 1
    end

    test "an unreadable file is refused rather than stored as noise", %{root: root} do
      recording(root, "prose.wav", "I am prose wearing a .wav extension")
      before = studio_entries(root)

      assert {:error, reason} = Commands.Sound.sound_import(%{"path" => "prose.wav"})
      assert reason in [:unsupported_source, :no_decoder]
      assert studio_entries(root) == before
    end

    if @decoder_available do
      test "a compressed recording is decoded on the way in, and says so", %{root: root} do
        compressed(root, "vm-take.m4a")

        assert {:ok, result} = Commands.Sound.sound_import(%{"path" => "vm-take.m4a"})

        # Stored as a WAV whatever it arrived as, and converted to the one
        # internal format every edit assumes.
        assert result.name == "vm-take.wav"
        assert result.decoded
        assert result.internal
        assert result.peak > 0.0
        assert result.duration_ms > 0
        assert Enum.any?(result.notes, &(&1 =~ "decoder ran"))

        assert {:ok, %{layer: "studio", internal: true, peak: peak}} =
                 Commands.Sound.sound_probe(%{"name" => "vm-take.wav"})

        assert peak > 0.0
      end
    end
  end

  describe "sound_transcript_search" do
    test "finds which recording says a word, with an excerpt and no timings", %{root: root} do
      event = voicemail(root, "Hey it's me, meet me down at the harbor tomorrow.")
      voicemail(root, "Nothing relevant in this one.")

      assert {:ok, result} = Commands.Sound.sound_transcript_search(%{"query" => "harbor"})

      assert result.count == 1
      assert [hit] = result.hits
      assert hit.event_id == event.id
      assert hit.excerpt =~ "harbor"
      assert hit.match_count == 1
      # Discovery, not cutting: a transcript hit carries no offsets at all.
      refute Map.has_key?(hit, :start_ms)
      assert Enum.any?(result.notes, &(&1 =~ "no timings"))
    end

    test "a transcript whose audio is missing is invisible by default, and says why", %{
      root: root
    } do
      voicemail(root, "Meet me at the harbor.", on_disk: false)

      assert {:ok, %{count: 0, notes: notes}} =
               Commands.Sound.sound_transcript_search(%{"query" => "harbor"})

      # The dev-workspace trap, named rather than left as silence.
      assert Enum.any?(notes, &(&1 =~ "sound_corpus"))
      assert Enum.any?(notes, &(&1 =~ "weak evidence"))

      assert {:ok, %{count: 1}} =
               Commands.Sound.sound_transcript_search(%{
                 "query" => "harbor",
                 "with_recording" => false
               })
    end

    test "a query with no words finds nothing rather than everything", %{root: root} do
      voicemail(root, "Meet me at the harbor.")

      assert {:ok, %{count: 0}} = Commands.Sound.sound_transcript_search(%{"query" => "???"})
      assert {:error, :missing_query} = Commands.Sound.sound_transcript_search(%{})
    end

    test "a malformed since is refused by name", %{root: _root} do
      assert {:error, :invalid_since} =
               Commands.Sound.sound_transcript_search(%{
                 "query" => "harbor",
                 "since" => "last tuesday"
               })
    end
  end

  describe "sound_transcript_words" do
    test "counts takes across the corpus and calls them a floor", %{root: root} do
      voicemail(root, "harbor harbor lighthouse")
      voicemail(root, "harbor")

      assert {:ok, result} = Commands.Sound.sound_transcript_words(%{})

      assert %{word: "harbor", count: 3} = Enum.find(result.words, &(&1.word == "harbor"))
      assert %{count: 1} = Enum.find(result.words, &(&1.word == "lighthouse"))
      assert Enum.any?(result.notes, &(&1 =~ "FLOOR"))

      assert {:ok, %{words: [%{word: "harbor"}]}} =
               Commands.Sound.sound_transcript_words(%{"min_count" => 2})
    end
  end

  describe "sound_corpus" do
    test "reports missing audio as a number, not as an empty search", %{root: root} do
      voicemail(root, "on disk")
      voicemail(root, "not on disk", on_disk: false)

      assert {:ok, corpus} = Commands.Sound.sound_corpus(%{})

      assert corpus.events == 2
      assert corpus.with_transcript == 2
      assert corpus.with_recording_path == 2
      assert corpus.recordings_on_disk == 1
      assert corpus.missing_audio == 1
      assert corpus.usable == 1
      assert Enum.any?(corpus.notes, &(&1 =~ "not on disk"))
    end

    test "an empty corpus explains itself" do
      assert {:ok, corpus} = Commands.Sound.sound_corpus(%{})

      assert corpus.events == 0
      assert corpus.usable == 0
      assert Enum.any?(corpus.notes, &(&1 =~ "No events of this kind"))
    end
  end

  describe "the word index" do
    setup %{root: root} do
      source(root, "voicemail-03.wav")
      :ok
    end

    test "import, list, vocabulary, search, delete — the round trip" do
      assert {:ok, imported} =
               Commands.Sound.sound_index_import(%{
                 "source" => "voicemail-03.wav",
                 "words" => words([{"meet", 100, 200}, {"me", 220, 300}, {"harbor", 400, 560}])
               })

      assert imported.words == 3
      assert imported.dropped == 0
      assert imported.origin == :imported
      assert imported.audio_present
      refute imported.replaced

      assert {:ok, listing} = Commands.Sound.sound_index_list()
      assert [%{source: "voicemail-03.wav", words: 3, audio_present: true}] = listing.indexes

      assert {:ok, vocabulary} = Commands.Sound.sound_index_words(%{})
      assert %{word: "harbor", takes: 1} = Enum.find(vocabulary.words, &(&1.word == "harbor"))
      assert vocabulary.distinct_words == 3
      assert vocabulary.indexed_sources == 1

      assert {:ok, %{word: "harbor", takes: 1}} =
               Commands.Sound.sound_index_words(%{"word" => "harbor"})

      assert {:ok, found} = Commands.Sound.sound_index_search(%{"query" => "harbor"})

      # A hit IS a cut — this is the shape sound_assemble consumes.
      assert [%{source: "voicemail-03.wav", start_ms: 400.0, end_ms: 560.0} = hit] = found.hits
      assert hit.confidence == 0.9
      assert hit.text == "harbor"

      assert {:ok, %{deleted: true}} =
               Commands.Sound.sound_index_delete(%{"source" => "voicemail-03.wav"})

      assert {:ok, %{count: 0}} = Commands.Sound.sound_index_list()
      assert {:error, :not_found} = Commands.Sound.sound_index_delete(%{"source" => "gone.wav"})
    end

    test "unusable entries are dropped and counted, not fatal" do
      assert {:ok, %{words: 1, dropped: 2}} =
               Commands.Sound.sound_index_import(%{
                 "source" => "voicemail-03.wav",
                 "words" =>
                   words([{"harbor", 100, 200}]) ++
                     [
                       # normalizes to nothing
                       %{"text" => "!!!", "start_ms" => 300, "end_ms" => 400},
                       # a zero-length cut is silence
                       %{"text" => "me", "start_ms" => 500, "end_ms" => 500}
                     ]
               })
    end

    test "an existing index is not replaced silently" do
      one = words([{"harbor", 100, 200}])

      assert {:ok, _first} =
               Commands.Sound.sound_index_import(%{
                 "source" => "voicemail-03.wav",
                 "words" => one
               })

      assert {:error, :index_exists} =
               Commands.Sound.sound_index_import(%{
                 "source" => "voicemail-03.wav",
                 "words" => one
               })

      assert {:ok, %{replaced: true, words: 2}} =
               Commands.Sound.sound_index_import(%{
                 "source" => "voicemail-03.wav",
                 "words" => words([{"harbor", 100, 200}, {"me", 300, 400}]),
                 "overwrite" => true
               })
    end

    test "a source that is not a basename never reaches the disk" do
      assert {:error, :invalid_source} =
               Commands.Sound.sound_index_import(%{
                 "source" => "../../etc/passwd",
                 "words" => words([{"harbor", 100, 200}])
               })

      assert {:error, :invalid_source} =
               Commands.Sound.sound_index_delete(%{"source" => "../../etc/passwd"})

      assert {:error, :missing_source} = Commands.Sound.sound_index_import(%{})
      assert {:error, :invalid_words} = Commands.Sound.sound_index_import(%{"source" => "a.wav"})
    end

    test "nothing indexed says so rather than returning a bare empty list" do
      assert {:ok, %{words: [], notes: notes}} = Commands.Sound.sound_index_words(%{})
      assert Enum.any?(notes, &(&1 =~ "Nothing is indexed"))
    end
  end

  describe "sound_assemble" do
    setup %{root: root} do
      source(root, "voicemail-03.wav")
      :ok
    end

    test "splices cuts into a new studio source", %{root: root} do
      assert {:ok, result} =
               Commands.Sound.sound_assemble(%{"name" => "sentence", "cuts" => cuts()})

      assert result.name == "sentence.wav"
      assert result.cuts == 2
      refute result.replaced
      assert File.regular?(Path.join([root, "sounds", "studio", "sentence.wav"]))

      # Two cuts padded 30 ms each side (100→160, 160→220), joined by one 60 ms
      # gap: the length is the sum of the pieces, exactly, because concat/1 is
      # byte concatenation rather than a placement mixdown.
      assert_in_delta result.duration_ms, 440.0, 2.0
      assert result.peak > 0.0

      # It landed as a SOURCE — raw material — and not in the routed library.
      assert {:ok, %{sources: sources}} = Commands.Sound.sound_sources()
      assert Enum.any?(sources, &(&1.name == "sentence.wav"))
      assert {:ok, %{sounds: sounds}} = Commands.Sound.sound_list()
      refute Enum.any?(sounds, &(&1.name == "sentence.wav"))

      # And it is probeable, in the internal format, like any other source.
      assert {:ok, %{layer: "studio", internal: true}} =
               Commands.Sound.sound_probe(%{"name" => "sentence.wav"})
    end

    test "options are passed through to the assembler", %{root: _root} do
      assert {:ok, tight} =
               Commands.Sound.sound_assemble(%{
                 "name" => "tight",
                 "cuts" => cuts(),
                 "pad_ms" => 0,
                 "gap_ms" => 0,
                 "normalize" => false
               })

      assert tight.options == %{pad_ms: 0, gap_ms: 0, normalize: false}
      assert_in_delta tight.duration_ms, 260.0, 2.0
    end

    test "it never clobbers an existing source silently" do
      assert {:ok, _first} =
               Commands.Sound.sound_assemble(%{"name" => "sentence", "cuts" => cuts()})

      assert {:error, :name_taken} =
               Commands.Sound.sound_assemble(%{"name" => "sentence", "cuts" => cuts()})

      # Not even the source it was cut from.
      assert {:error, :name_taken} =
               Commands.Sound.sound_assemble(%{"name" => "voicemail-03", "cuts" => cuts()})

      assert {:ok, %{replaced: true}} =
               Commands.Sound.sound_assemble(%{
                 "name" => "sentence",
                 "cuts" => cuts(),
                 "overwrite" => true
               })
    end

    test "bad input is named, and writes nothing", %{root: root} do
      studio = Path.join([root, "sounds", "studio"])
      before = File.ls!(studio)

      assert {:error, :empty_selection} =
               Commands.Sound.sound_assemble(%{"name" => "empty", "cuts" => []})

      assert {:error, {:source_not_found, "nope.wav"}} =
               Commands.Sound.sound_assemble(%{
                 "name" => "missing",
                 "cuts" => [%{"source" => "nope.wav", "start_ms" => 0, "end_ms" => 100}]
               })

      assert {:error, {:invalid_cut, _cut}} =
               Commands.Sound.sound_assemble(%{
                 "name" => "bad",
                 "cuts" => [%{"source" => "voicemail-03.wav", "start_ms" => "soon"}]
               })

      assert {:error, {:invalid_span, _cut}} =
               Commands.Sound.sound_assemble(%{
                 "name" => "backwards",
                 "cuts" => [%{"source" => "voicemail-03.wav", "start_ms" => 400, "end_ms" => 100}]
               })

      assert {:error, {:span_outside_clip, _cut}} =
               Commands.Sound.sound_assemble(%{
                 "name" => "past-the-end",
                 "cuts" => [
                   %{"source" => "voicemail-03.wav", "start_ms" => 90_000, "end_ms" => 91_000}
                 ]
               })

      assert {:error, :missing_name} = Commands.Sound.sound_assemble(%{"cuts" => cuts()})
      assert {:error, :empty_selection} = Commands.Sound.sound_assemble(%{})

      assert File.ls!(studio) == before
    end

    test "a path-shaped name is refused before anything is written" do
      assert {:error, :invalid_name} =
               Commands.Sound.sound_assemble(%{"name" => "../escape", "cuts" => cuts()})

      assert {:error, :invalid_name} =
               Commands.Sound.sound_assemble(%{"name" => "/tmp/escape", "cuts" => cuts()})
    end
  end

  describe "dispatch by name" do
    # The wiring is the phase: a handler nothing can reach through call/3 is not
    # a command surface. Catalog entry, registration, delegate and handler all
    # have to line up for these to answer.
    test "the library verbs are reachable through Commands.call/3", %{root: root} do
      library(root, "chime.wav")
      source(root, "clip.wav")

      assert {:ok, %{sounds: sounds}} = Commands.call("sound_list", %{})
      assert Enum.any?(sounds, &(&1.name == "chime.wav"))

      assert {:ok, %{routes: routes}} = Commands.call("sound_routes", %{})
      assert length(routes) == length(Sound.route_keys())

      assert {:ok, %{sources: [%{name: "clip.wav"}]}} = Commands.call("sound_sources", %{})

      assert {:ok, %{name: "chime.wav", internal: true}} =
               Commands.call("sound_probe", %{"name" => "chime.wav"})
    end

    test "the import verbs are reachable through Commands.call/3", %{root: root} do
      event = voicemail(root, "meet me at the harbor")
      recording(root, "calls/take-1.wav")

      assert {:ok, %{layer: "library", event_id: id}} =
               Commands.call("sound_probe", %{"event_id" => event.id})

      assert id == event.id

      assert {:ok, %{layer: "library"}} =
               Commands.call("sound_probe", %{"path" => "calls/take-1.wav"})

      assert {:ok, %{name: name, replaced: false}} =
               Commands.call("sound_import", %{"event_id" => event.id})

      assert name == Path.basename(event.recording_path)

      assert {:ok, %{name: "harbor.wav"}} =
               Commands.call("sound_import", %{
                 "path" => "calls/take-1.wav",
                 "name" => "harbor"
               })

      assert {:error, :traversal} =
               Commands.call("sound_import", %{"path" => "../../etc/passwd"})

      assert {:error, :absolute_path} = Commands.call("sound_probe", %{"path" => "/etc/passwd"})
    end

    test "the cut-up verbs are reachable through Commands.call/3", %{root: root} do
      source(root, "voicemail-03.wav")
      voicemail(root, "meet me at the harbor")

      assert {:ok, %{count: 1}} =
               Commands.call("sound_transcript_search", %{"query" => "harbor"})

      assert {:ok, %{words: [_ | _]}} = Commands.call("sound_transcript_words", %{})
      assert {:ok, %{usable: 1}} = Commands.call("sound_corpus", %{})

      assert {:ok, %{words: 2}} =
               Commands.call("sound_index_import", %{
                 "source" => "voicemail-03.wav",
                 "words" => words([{"meet", 100, 200}, {"harbor", 400, 560}])
               })

      assert {:ok, %{count: 1}} = Commands.call("sound_index_list", %{})
      assert {:ok, %{takes: 1}} = Commands.call("sound_index_words", %{"word" => "harbor"})

      assert {:ok, %{hits: [%{start_ms: 400.0}]}} =
               Commands.call("sound_index_search", %{"query" => "harbor"})

      assert {:ok, %{name: "sentence.wav"}} =
               Commands.call("sound_assemble", %{"name" => "sentence", "cuts" => cuts()})

      assert {:ok, %{deleted: true}} =
               Commands.call("sound_index_delete", %{"source" => "voicemail-03.wav"})
    end

    test "errors survive dispatch unchanged", %{root: root} do
      source(root, "voicemail-03.wav")

      assert {:error, :not_found} = Commands.call("sound_probe", %{"name" => "nope.wav"})
      assert {:error, :invalid_name} = Commands.call("sound_probe", %{"name" => "../secrets.wav"})

      assert {:error, {:invalid_span, _cut}} =
               Commands.call("sound_assemble", %{
                 "name" => "backwards",
                 "cuts" => [%{"source" => "voicemail-03.wav", "start_ms" => 400, "end_ms" => 100}]
               })
    end

    test "the catalog advertises reads as safe and writers as restricted" do
      catalog = Map.new(Commands.list_commands(), &{&1.name, &1})

      reads = ~w(
        sound_list sound_routes sound_sources sound_probe
        sound_transcript_search sound_transcript_words sound_corpus
        sound_index_list sound_index_words sound_index_search
      )

      for name <- reads do
        entry = Map.fetch!(catalog, name)
        assert entry.type == :read, "#{name} should be a read"
        assert entry.tier == :safe, "#{name} should be safe"
        refute Map.get(entry, :gated, false), "#{name} should not be gated"
      end

      # The four that write. Restricted, and deliberately NOT gated: they write
      # a new source or a text index, and none of them routes anything.
      for name <- ~w(sound_import sound_index_import sound_index_delete sound_assemble) do
        entry = Map.fetch!(catalog, name)
        assert entry.type == :mutate, "#{name} should be a mutate"
        assert entry.tier == :restricted, "#{name} should be restricted"
        refute Map.get(entry, :gated, false), "#{name} should not be gated"
      end

      # sound_probe takes one of three inputs, so none of them is required on
      # its own — the handler names the missing one instead.
      probe = Map.fetch!(catalog, "sound_probe")
      refute probe.args["name"].required
      assert Map.has_key?(probe.args, "event_id")
      assert Map.has_key?(probe.args, "path")
      refute probe.args["decode"].default

      # Same for the import verb, whose two inputs are alternatives.
      import_args = Map.fetch!(catalog, "sound_import").args
      refute import_args["event_id"].required
      refute import_args["path"].required
      refute import_args["overwrite"].default

      assert Map.fetch!(catalog, "sound_assemble").args["cuts"].required
      assert Map.fetch!(catalog, "sound_assemble").args["name"].required
    end
  end
end
