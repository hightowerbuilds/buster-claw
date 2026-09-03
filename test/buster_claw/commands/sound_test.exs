defmodule BusterClaw.Commands.SoundTest do
  # async: false — points the global :workspace_root at a tmp dir, which is how
  # both the sound library and the studio folder resolve.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Commands
  alias BusterClaw.Notifications.Cutup.Features
  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Notifications.SoundGen
  alias BusterClaw.Notifications.SoundStudio
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

  # A recording with structure the detector can actually find: `bursts` tone
  # bursts of 300 ms separated by 300 ms of digital silence, with silence at each
  # end so there is a noise floor to measure. Three bursts is three spans at the
  # default gates, which is what gives an alignment somewhere to put words.
  defp speech(bursts \\ 3) do
    silence = pcm(300, 0.0)
    body = Enum.map_join(1..bursts, silence, fn _burst -> pcm(300, 440.0) end)

    SoundStudio.render(%SoundStudio{data: silence <> body <> silence})
  end

  defp pcm(ms, hz) do
    count = trunc(22_050 * ms / 1000)

    for i <- 0..(count - 1), into: <<>> do
      sample =
        if hz == 0.0,
          do: 0,
          else: round(0.5 * 32_767 * :math.sin(2 * :math.pi() * hz * i / 22_050))

      <<sample::little-signed-16>>
    end
  end

  # 200 ms of DC at a constant level: every sample is the same non-zero number,
  # so a ramp that lands on true zero is visible in the bytes. A sine or a chime
  # starts at zero anyway, which would make the fade assertions vacuous.
  defp flat(ms \\ 200), do: SoundStudio.render(%SoundStudio{data: dc(ms)})

  defp dc(ms), do: :binary.copy(<<8000::little-signed-16>>, trunc(22_050 * ms / 1000))

  defp first_sample(path) do
    {:ok, clip} = SoundStudio.read(path)
    <<sample::little-signed-16, _rest::binary>> = clip.data
    sample
  end

  defp last_sample(path) do
    {:ok, clip} = SoundStudio.read(path)
    <<sample::little-signed-16>> = binary_part(clip.data, byte_size(clip.data) - 2, 2)
    sample
  end

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
      File.write!(Path.join([root, "library", name]), Keyword.get(opts, :audio) || wav())
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

  # A voicemail whose audio has structure, already through the studio door — the
  # state every alignment starts from, and the one `sound_align` refuses to
  # create for you.
  defp aligned_voicemail(root, transcript \\ "meet me at the harbor") do
    event = voicemail(root, transcript, audio: speech())
    {:ok, imported} = Commands.Sound.sound_import(%{"event_id" => event.id})
    {event, imported.name}
  end

  # A word list of the shape a recognizer (or a hand-authored fixture) supplies,
  # with wire-style string keys.
  defp words(specs) do
    Enum.map(specs, fn {text, from, to} ->
      %{"text" => text, "start_ms" => from, "end_ms" => to, "confidence" => 0.9}
    end)
  end

  # A source with one "word" planted twice: silence, A, silence, B, silence, A,
  # silence — 1.7 s in total, which is the whole cost story. `Cutup.Features`
  # measures 108.8 s on a 300 s source and ~155 ms on a warm one; this fixture
  # analyses in a fraction of a second. A fixture that approached a minute would
  # be a fixture that was too big.
  #
  # A is at 200–500 ms and again at 1200–1500 ms, and B (a different tone) sits
  # between them so the matcher has something it must NOT return.
  defp planted do
    gap = pcm(200, 0.0)
    a = pcm(300, 440.0)
    b = pcm(300, 900.0)

    SoundStudio.render(%SoundStudio{data: gap <> a <> gap <> b <> gap <> a <> gap})
  end

  # The confirmed take `sound_find` starts from: the FIRST A, which is what an
  # operator would have picked out of sound_index_search and listened to.
  defp template(args \\ %{}) do
    Map.merge(
      %{"word" => "harbor", "source" => "planted.wav", "start_ms" => 200, "end_ms" => 500},
      args
    )
  end

  defp indexed(source, specs, origin \\ "aligned") do
    {:ok, result} =
      Commands.Sound.sound_index_import(%{
        "source" => source,
        "words" => words(specs),
        "origin" => origin
      })

    result
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

  describe "sound_align" do
    test "an event's transcript becomes an index that is on disk", %{root: root} do
      {event, source} = aligned_voicemail(root)

      assert {:ok, result} = Commands.Sound.sound_align(%{"event_id" => event.id})

      # Bound to the source it will be cut from, named the same way sound_import
      # named it — otherwise Assemble could never resolve the cuts.
      assert result.source == source
      assert result.event_id == event.id
      assert result.library_path == event.recording_path
      assert result.audio_present
      refute result.replaced

      # Three bursts, five words, all of them placed.
      assert result.spans == 3
      assert result.words == 5
      assert result.transcript_words == 5
      assert result.origin == :aligned
      assert result.speech_ms > 0
      assert result.duration_ms > result.speech_ms

      # It PERSISTED. sound_index_search reads from disk, so an in-memory index
      # would have been worth nothing.
      assert File.regular?(result.path)
      assert {:ok, index} = Index.load(source)
      assert length(index.words) == 5
      assert index.origin == :aligned
      assert Enum.map(index.words, & &1.word) == ~w(meet me at the harbor)

      # Every word landed inside a detected span, in order, never in silence.
      assert Enum.all?(index.words, &(&1.end_ms > &1.start_ms))
      starts = Enum.map(index.words, & &1.start_ms)
      assert starts == Enum.sort(starts)

      # And the whole point: the cut-up surface can now use this source.
      assert {:ok, %{indexes: [%{source: ^source, words: 5, audio_present: true}]}} =
               Commands.Sound.sound_index_list()

      assert {:ok, %{hits: [hit]}} = Commands.Sound.sound_index_search(%{"query" => "harbor"})
      assert hit.source == source
      assert hit.end_ms > hit.start_ms

      assert Enum.any?(result.notes, &(&1 =~ "APPROXIMATE"))
      assert Enum.any?(result.notes, &(&1 =~ "sound_assemble"))
    end

    test "the confidence spread is reported, and never claims to be hand-marked", %{root: root} do
      {event, _source} = aligned_voicemail(root)

      # Both post-listen corrections OFF on purpose. This test pins the
      # flat-spread and nothing-clamped properties, and those hold precisely
      # when no word has been moved or reduced. Snapping and function-word
      # reduction both legitimately clamp a word at a span join, which is the
      # documented exception to a flat spread — covered by its own tests.
      assert {:ok, result} =
               Commands.Sound.sound_align(%{
                 "event_id" => event.id,
                 "snap_to_energy" => false,
                 "reduce_function_words" => false
               })

      assert %{min: min, median: median, max: max} = result.confidence
      assert min <= median and median <= max
      assert min > 0.0

      # 1.0 belongs to hand-marked timings, so `min_confidence: 0.95` can still
      # ask for those alone after an alignment has run.
      assert max <= 0.9
      assert Enum.any?(result.notes, &(&1 =~ "0.9"))

      # The spread is a whole-recording plausibility figure, NOT a per-word
      # verdict: every word is scored against the same absolute expectation, so
      # under the default weighting these are one number three times. The notes
      # have to say so, or the flatness reads as the alignment being uniformly
      # good.
      assert min == max
      assert Enum.any?(result.notes, &(&1 =~ "RECORDING"))

      # The exact per-alignment figure the spread cannot give: with this fixture
      # every word tiles the detected speech, so nothing was clamped away.
      assert result.placed_ms > 0.0
      assert_in_delta result.placed_ms, result.speech_ms, 0.001
      assert result.unplaced_ms == 0.0

      # A transcript far longer than the audio can hold collapses the whole
      # batch's confidence rather than failing — which is the signal a caller
      # gets instead of an error.
      other = voicemail(root, "unused", audio: speech())
      {:ok, %{name: crowded}} = Commands.Sound.sound_import(%{"event_id" => other.id})

      assert {:ok, hurried} =
               Commands.Sound.sound_align(%{
                 "source" => crowded,
                 "transcript" => String.duplicate("harbor ", 120)
               })

      assert hurried.confidence.max < result.confidence.min
    end

    test "a word that straddles a span boundary shows up as unplaced audio", %{root: root} do
      source(root, "found.wav", speech())

      # Eight syllables across three equal spans does not divide, so a word
      # crosses a boundary, is clamped to the span it mostly occupies, and gives
      # up the rest. That surrendered audio is the one exact per-word quality
      # signal available — the confidence spread cannot report it.
      assert {:ok, result} =
               Commands.Sound.sound_align(%{
                 "source" => "found.wav",
                 "transcript" => "meet me at the harbor now please"
               })

      assert result.words == 7
      assert result.unplaced_ms > 0.0
      assert result.placed_ms < result.speech_ms
      assert_in_delta result.placed_ms + result.unplaced_ms, result.speech_ms, 0.001

      # And clamping is the only thing that moves confidence within one call.
      assert result.confidence.min < result.confidence.max
      assert Enum.any?(result.notes, &(&1 =~ "covered by no word"))
    end

    test "a source plus an explicit transcript needs no event at all", %{root: root} do
      source(root, "found.wav", speech())

      assert {:ok, result} =
               Commands.Sound.sound_align(%{
                 "source" => "found.wav",
                 "transcript" => "meet me at the harbor",
                 "language" => "en-US"
               })

      assert result.source == "found.wav"
      assert result.event_id == nil
      assert result.library_path == nil
      assert result.words == 5
      assert result.language == "en-US"
      assert {:ok, %{language: "en-US"}} = Index.load("found.wav")
    end

    test "an explicit transcript overrides the one the event carries", %{root: root} do
      # The transcriber renders "Buster Claw" as "bus o'clock"; correcting it is
      # the cheapest improvement available to this whole feature.
      {event, source} = aligned_voicemail(root, "bus o'clock is calling")

      assert {:ok, result} =
               Commands.Sound.sound_align(%{
                 "event_id" => event.id,
                 "transcript" => "buster claw is calling"
               })

      assert result.words == 4
      assert {:ok, index} = Index.load(source)
      assert Enum.map(index.words, & &1.word) == ~w(buster claw is calling)
    end

    test "an existing index is refused, then permitted", %{root: root} do
      {event, source} = aligned_voicemail(root)

      assert {:ok, %{replaced: false}} = Commands.Sound.sound_align(%{"event_id" => event.id})

      assert {:error, :index_exists} = Commands.Sound.sound_align(%{"event_id" => event.id})

      # The first index survived the refusal untouched.
      assert {:ok, %{words: [_ | _] = words}} = Index.load(source)
      assert length(words) == 5

      assert {:ok, replaced} =
               Commands.Sound.sound_align(%{
                 "event_id" => event.id,
                 "transcript" => "harbor",
                 "overwrite" => true
               })

      assert replaced.replaced
      assert replaced.words == 1
      assert Enum.any?(replaced.notes, &(&1 =~ "replaced"))
      assert {:ok, %{words: [%{word: "harbor"}]}} = Index.load(source)
    end

    test "audio that was never imported is refused, naming what to import", %{root: root} do
      event = voicemail(root, "meet me at the harbor", audio: speech())
      expected = Path.basename(event.recording_path)

      # This verb never imports. The refusal carries the basename sound_import
      # would store, so the fix is one call away.
      assert {:error, {:not_imported, ^expected}} =
               Commands.Sound.sound_align(%{"event_id" => event.id})

      assert {:error, {:not_imported, "nope.wav"}} =
               Commands.Sound.sound_align(%{"source" => "nope.wav", "transcript" => "harbor"})

      # Nothing was written on the way to either refusal.
      assert {:ok, %{count: 0}} = Commands.Sound.sound_index_list()

      assert {:ok, _imported} = Commands.Sound.sound_import(%{"event_id" => event.id})
      assert {:ok, %{words: 5}} = Commands.Sound.sound_align(%{"event_id" => event.id})
    end

    test "a missing transcript, a missing recording and a bad id are each named", %{root: root} do
      assert {:error, :event_not_found} = Commands.Sound.sound_align(%{"event_id" => 987_654})
      assert {:error, :invalid_event_id} = Commands.Sound.sound_align(%{"event_id" => "soon"})
      assert {:error, :missing_source} = Commands.Sound.sound_align(%{})

      # A voicemail Twilio never transcribed. The audio is fine; there is simply
      # nothing to lay across it.
      silent = voicemail(root, nil, audio: speech())
      assert {:ok, _imported} = Commands.Sound.sound_import(%{"event_id" => silent.id})
      assert {:error, :no_transcript} = Commands.Sound.sound_align(%{"event_id" => silent.id})

      # A row whose audio was pruned, and an SMS that names no recording at all.
      gone = voicemail(root, "meet me at the harbor", on_disk: false)
      assert {:error, :not_found} = Commands.Sound.sound_align(%{"event_id" => gone.id})

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

      assert {:error, :no_recording} = Commands.Sound.sound_align(%{"event_id" => sms.id})

      # A bare source with nothing to align is a different miss from an event
      # that carries no text, and says so.
      source(root, "found.wav", speech())

      assert {:error, :missing_transcript} =
               Commands.Sound.sound_align(%{"source" => "found.wav"})

      assert {:error, :invalid_name} =
               Commands.Sound.sound_align(%{"source" => "../escape.wav", "transcript" => "hi"})

      assert {:ok, %{count: 0}} = Commands.Sound.sound_index_list()
    end

    test "silence produces no index rather than an empty one", %{root: root} do
      source(root, "quiet.wav", SoundStudio.render(%SoundStudio{data: pcm(1000, 0.0)}))

      assert {:error, :no_alignment} =
               Commands.Sound.sound_align(%{
                 "source" => "quiet.wav",
                 "transcript" => "meet me at the harbor"
               })

      # No tombstone: the retry that tunes the detector does not need overwrite.
      assert {:ok, %{count: 0}} = Commands.Sound.sound_index_list()
    end

    test "detector and fit options are passed through", %{root: root} do
      source(root, "found.wav", speech())

      # 400 ms rejects every 335 ms span the fixture has, so there is nowhere
      # left to put a word — which is the detector doing exactly as told.
      assert {:error, :no_alignment} =
               Commands.Sound.sound_align(%{
                 "source" => "found.wav",
                 "transcript" => "meet me at the harbor",
                 "min_span_ms" => 400
               })

      # 400 ms of silence between the bursts is no longer a gap, so the three
      # spans merge into one.
      assert {:ok, merged} =
               Commands.Sound.sound_align(%{
                 "source" => "found.wav",
                 "transcript" => "meet me at the harbor",
                 "min_silence_ms" => 400,
                 "weight" => "characters",
                 "syllable_ms" => 150
               })

      assert merged.spans == 1
      assert merged.words == 5

      assert merged.options == %{
               min_silence_ms: 400,
               weight: :characters,
               syllable_ms: 150
             }

      # Character weighting gives words of different lengths different shares,
      # so confidence stops being one number for the whole batch.
      assert merged.confidence.min < merged.confidence.max
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

  describe "sound_trim" do
    setup %{root: root} do
      source(root, "voicemail-03.wav", speech())
      :ok
    end

    test "cuts a span into a new source, named after its input", %{root: root} do
      assert {:ok, result} =
               Commands.Sound.sound_trim(%{
                 "source" => "voicemail-03.wav",
                 "start_ms" => 300,
                 "end_ms" => 600
               })

      # Derived, not required: harbor.wav trimmed is harbor-trim.wav.
      assert result.name == "voicemail-03-trim.wav"
      assert result.source == "voicemail-03.wav"
      assert result.start_ms == 300
      assert result.end_ms == 600
      refute result.replaced
      assert File.regular?(Path.join([root, "sounds", "studio", "voicemail-03-trim.wav"]))

      # Both sides of the edit, which is the whole of how an agent that cannot
      # hear checks that a trim removed what it meant to remove.
      assert_in_delta result.duration_ms, 300.0, 1.0
      assert result.source_duration_ms > result.duration_ms
      assert result.peak > 0.0
      assert result.source_peak > 0.0

      # The input is untouched — an edit renders, it does not mutate.
      assert {:ok, %{duration_ms: original}} =
               Commands.Sound.sound_probe(%{"name" => "voicemail-03.wav"})

      assert original == result.source_duration_ms
    end

    test "each end has a default, so trimming one is one argument" do
      # No end_ms: everything from 300 ms to the end of the clip.
      assert {:ok, tail} =
               Commands.Sound.sound_trim(%{
                 "source" => "voicemail-03.wav",
                 "start_ms" => 300,
                 "name" => "tail"
               })

      assert_in_delta tail.duration_ms, tail.source_duration_ms - 300.0, 1.0

      # No start_ms: the head.
      assert {:ok, head} =
               Commands.Sound.sound_trim(%{
                 "source" => "voicemail-03.wav",
                 "end_ms" => 300,
                 "name" => "head"
               })

      assert head.start_ms == 0
      assert_in_delta head.duration_ms, 300.0, 1.0
    end

    test "a span that selects nothing is refused, and writes nothing", %{root: root} do
      before = studio_entries(root)

      # Backwards, and entirely past the end — which clamps to zero length.
      assert {:error, :empty_selection} =
               Commands.Sound.sound_trim(%{
                 "source" => "voicemail-03.wav",
                 "start_ms" => 600,
                 "end_ms" => 300
               })

      assert {:error, :empty_selection} =
               Commands.Sound.sound_trim(%{
                 "source" => "voicemail-03.wav",
                 "start_ms" => 90_000,
                 "end_ms" => 91_000
               })

      assert {:error, :invalid_span} =
               Commands.Sound.sound_trim(%{"source" => "voicemail-03.wav", "start_ms" => "soon"})

      assert {:error, :invalid_span} =
               Commands.Sound.sound_trim(%{"source" => "voicemail-03.wav", "start_ms" => -10})

      assert studio_entries(root) == before
    end

    test "it never clobbers an existing source silently" do
      assert {:ok, _first} =
               Commands.Sound.sound_trim(%{"source" => "voicemail-03.wav", "end_ms" => 300})

      assert {:error, :name_taken} =
               Commands.Sound.sound_trim(%{"source" => "voicemail-03.wav", "end_ms" => 300})

      # Not even its own input.
      assert {:error, :name_taken} =
               Commands.Sound.sound_trim(%{
                 "source" => "voicemail-03.wav",
                 "end_ms" => 300,
                 "name" => "voicemail-03"
               })

      assert {:ok, %{replaced: true}} =
               Commands.Sound.sound_trim(%{
                 "source" => "voicemail-03.wav",
                 "end_ms" => 300,
                 "overwrite" => true
               })
    end

    test "a source that is not in the studio names itself" do
      assert {:error, {:not_imported, "nope.wav"}} =
               Commands.Sound.sound_trim(%{"source" => "nope.wav"})

      assert {:error, :invalid_name} = Commands.Sound.sound_trim(%{"source" => "../escape.wav"})
      assert {:error, :missing_source} = Commands.Sound.sound_trim(%{})
    end
  end

  describe "sound_fade" do
    setup %{root: root} do
      source(root, "clip.wav", flat())
      :ok
    end

    test "the ramps land on true zero, which is the click they exist to fix", %{root: root} do
      assert first_sample(Path.join([root, "sounds", "studio", "clip.wav"])) == 8000

      assert {:ok, result} =
               Commands.Sound.sound_fade(%{
                 "source" => "clip.wav",
                 "in_ms" => 20,
                 "out_ms" => 20
               })

      assert result.name == "clip-fade.wav"
      assert result.in_ms == 20
      assert result.out_ms == 20

      # A fade changes level, never length.
      assert_in_delta result.duration_ms, result.source_duration_ms, 0.001

      assert first_sample(result.path) == 0
      assert last_sample(result.path) == 0
    end

    test "one ramp is enough, and neither is refused", %{root: root} do
      assert {:ok, in_only} =
               Commands.Sound.sound_fade(%{"source" => "clip.wav", "in_ms" => 20})

      assert in_only.out_ms == 0
      assert first_sample(in_only.path) == 0
      assert last_sample(in_only.path) == 8000

      before = studio_entries(root)

      # A fade with neither ramp would write a byte-identical copy under a new
      # name, which reads as the verb having done something.
      assert {:error, :missing_fade} = Commands.Sound.sound_fade(%{"source" => "clip.wav"})

      assert {:error, :invalid_fade} =
               Commands.Sound.sound_fade(%{"source" => "clip.wav", "in_ms" => -5})

      assert {:error, :invalid_fade} =
               Commands.Sound.sound_fade(%{"source" => "clip.wav", "out_ms" => "long"})

      assert studio_entries(root) == before
    end
  end

  describe "sound_normalize" do
    test "a quiet source is lifted to the target, and reports both levels", %{root: root} do
      source(root, "quiet.wav", speech())

      assert {:ok, result} = Commands.Sound.sound_normalize(%{"source" => "quiet.wav"})

      assert result.name == "quiet-normalize.wav"
      assert result.target == nil
      assert_in_delta result.source_peak, 0.5, 0.01
      # The module's own default target, ~-1 dBFS.
      assert_in_delta result.peak, 0.891, 0.01
      assert_in_delta result.duration_ms, result.source_duration_ms, 0.001
    end

    test "an explicit target is honoured, and an impossible one is refused", %{root: root} do
      source(root, "quiet.wav", speech())

      assert {:ok, half} =
               Commands.Sound.sound_normalize(%{"source" => "quiet.wav", "target" => 0.25})

      assert half.target == 0.25
      assert_in_delta half.peak, 0.25, 0.01

      # Above full scale is not a louder sound, it is a clipped one.
      assert {:error, :invalid_target} =
               Commands.Sound.sound_normalize(%{"source" => "quiet.wav", "target" => 1.5})

      assert {:error, :invalid_target} =
               Commands.Sound.sound_normalize(%{"source" => "quiet.wav", "target" => 0})
    end

    test "digital silence is returned untouched rather than divided by zero", %{root: root} do
      source(root, "silence.wav", SoundStudio.render(%SoundStudio{data: pcm(200, 0.0)}))

      assert {:ok, result} = Commands.Sound.sound_normalize(%{"source" => "silence.wav"})

      assert result.source_peak == 0.0
      assert result.peak == 0.0
    end
  end

  describe "sound_concat" do
    setup %{root: root} do
      source(root, "one.wav", SoundStudio.render(%SoundStudio{data: dc(200)}))
      source(root, "two.wav", SoundStudio.render(%SoundStudio{data: dc(100)}))
      :ok
    end

    test "joins whole sources in the order given", %{root: root} do
      assert {:ok, result} =
               Commands.Sound.sound_concat(%{
                 "sources" => ["one.wav", "two.wav"],
                 "name" => "joined"
               })

      assert result.name == "joined.wav"
      assert Enum.map(result.sources, & &1.name) == ["one.wav", "two.wav"]
      assert_in_delta result.duration_ms, 300.0, 1.0
      assert File.regular?(Path.join([root, "sounds", "studio", "joined.wav"]))

      # The join is byte concatenation, so the total is the sum of the pieces
      # exactly — no drift, which is what makes this verb checkable at all.
      assert_in_delta result.duration_ms,
                      Enum.sum(Enum.map(result.sources, & &1.duration_ms)),
                      0.001
    end

    test "naming the same source twice joins it twice, on purpose" do
      assert {:ok, result} =
               Commands.Sound.sound_concat(%{
                 "sources" => ["two.wav", "two.wav", "two.wav"],
                 "name" => "stutter"
               })

      assert length(result.sources) == 3
      assert_in_delta result.duration_ms, 300.0, 1.0
    end

    test "a format mismatch is refused rather than resampled", %{root: root} do
      # 44.1 kHz beside 22.05 kHz: joining them would play the first at half
      # speed, which is a bug that sounds like a feature until someone listens.
      source(
        root,
        "other-rate.wav",
        SoundStudio.render(%SoundStudio{
          data: dc(100),
          sample_rate: 44_100
        })
      )

      before = studio_entries(root)

      assert {:error, :format_mismatch} =
               Commands.Sound.sound_concat(%{
                 "sources" => ["one.wav", "other-rate.wav"],
                 "name" => "mixed"
               })

      assert studio_entries(root) == before
    end

    test "bad input is named, and writes nothing", %{root: root} do
      before = studio_entries(root)

      assert {:error, :empty_selection} =
               Commands.Sound.sound_concat(%{"sources" => [], "name" => "empty"})

      assert {:error, {:not_imported, "nope.wav"}} =
               Commands.Sound.sound_concat(%{
                 "sources" => ["one.wav", "nope.wav"],
                 "name" => "missing"
               })

      assert {:error, :invalid_name} =
               Commands.Sound.sound_concat(%{"sources" => ["../escape.wav"], "name" => "bad"})

      assert {:error, :missing_name} = Commands.Sound.sound_concat(%{"sources" => ["one.wav"]})
      assert {:error, :empty_selection} = Commands.Sound.sound_concat(%{})

      assert studio_entries(root) == before
    end
  end

  describe "sound_delete" do
    test "removes a studio source and nothing else", %{root: root} do
      source(root, "scratch.wav")
      library(root, "keeper.wav")

      assert {:ok, result} = Commands.Sound.sound_delete(%{"name" => "scratch.wav"})

      assert result.deleted
      refute result.index_deleted
      assert result.bytes > 0
      refute File.exists?(Path.join([root, "sounds", "studio", "scratch.wav"]))

      # The library and the routing table are a different store.
      assert File.regular?(Path.join([root, "sounds", "keeper.wav"]))

      assert {:error, {:not_imported, "scratch.wav"}} =
               Commands.Sound.sound_trim(%{"source" => "scratch.wav"})
    end

    test "a source with a live index is refused rather than left dangling", %{root: root} do
      source(root, "indexed.wav")

      {:ok, _index} =
        Commands.Sound.sound_index_import(%{
          "source" => "indexed.wav",
          "words" => words([{"harbor", 100, 200}])
        })

      # The failure this refusal exists to prevent: an index whose every hit
      # resolves to audio that is no longer there.
      assert {:error, :source_indexed} = Commands.Sound.sound_delete(%{"name" => "indexed.wav"})
      assert File.regular?(Path.join([root, "sounds", "studio", "indexed.wav"]))
      assert {:ok, %{count: 1}} = Commands.Sound.sound_index_list()

      assert {:ok, result} =
               Commands.Sound.sound_delete(%{"name" => "indexed.wav", "delete_index" => true})

      assert result.index_deleted
      refute File.exists?(Path.join([root, "sounds", "studio", "indexed.wav"]))
      assert {:ok, %{count: 0}} = Commands.Sound.sound_index_list()
      assert {:ok, %{hits: []}} = Commands.Sound.sound_index_search(%{"query" => "harbor"})
    end

    test "an unknown or path-shaped name is refused" do
      assert {:error, {:not_imported, "nope.wav"}} =
               Commands.Sound.sound_delete(%{"name" => "nope.wav"})

      assert {:error, :invalid_name} = Commands.Sound.sound_delete(%{"name" => "../escape.wav"})
      assert {:error, :missing_name} = Commands.Sound.sound_delete(%{})
    end
  end

  describe "sound_apply" do
    setup %{root: root} do
      source(root, "sentence.wav", speech())
      :ok
    end

    test "installs into the library and routes a key to it", %{root: root} do
      assert {:ok, result} =
               Commands.Sound.sound_apply(%{
                 "source" => "sentence.wav",
                 "route" => "voicemail",
                 "name" => "ramshackle"
               })

      assert result.name == "ramshackle.wav"
      assert result.route == "voicemail"
      assert result.route_label == "Voicemail"
      assert result.duration_ms > 0
      assert result.peak > 0.0
      refute result.shadowing
      refute result.replaced

      # The file is in the library, which is the store the player reads.
      assert File.regular?(Path.join([root, "sounds", "ramshackle.wav"]))
      assert Sound.path_for("ramshackle.wav")

      # And the routing table actually resolves to it — for the key, and for a
      # notification that would fire against that key.
      assert Sound.resolved("voicemail") == "ramshackle.wav"
      assert Sound.for_notification(%{source: "voicemail", kind: "timer"}) == "ramshackle.wav"

      assert {:ok, routes} = Commands.Sound.sound_routes()

      assert %{assigned: "ramshackle.wav", plays: "ramshackle.wav", origin: "explicit"} =
               route(routes, "voicemail")

      # The studio source is untouched: the library holds a copy.
      assert File.regular?(Path.join([root, "sounds", "studio", "sentence.wav"]))
    end

    test "the way back is in the result", %{root: root} do
      library(root, "old.wav")
      assert :ok = Sound.assign("voicemail", "old.wav")

      assert {:ok, result} =
               Commands.Sound.sound_apply(%{
                 "source" => "sentence.wav",
                 "route" => "voicemail",
                 "name" => "new"
               })

      assert result.previous_sound == "old.wav"
      assert result.previously_played == "old.wav"
      assert result.plays == "new.wav"
      assert Enum.any?(result.notes, &(&1 =~ "old.wav"))
      assert Enum.any?(result.notes, &(&1 =~ "sound_restore_defaults"))
    end

    test "a typo'd route is refused BEFORE anything is written", %{root: root} do
      before = File.ls!(Path.join(root, "sounds"))

      assert {:error, :unknown_route} =
               Commands.Sound.sound_apply(%{"source" => "sentence.wav", "route" => "voicemale"})

      # Nothing installed, nothing routed — which is the entire point of
      # validating the key at the verb rather than at the assignment.
      assert File.ls!(Path.join(root, "sounds")) == before
      assert Sound.sound_map() == %{}

      assert {:error, :missing_route} = Commands.Sound.sound_apply(%{"source" => "sentence.wav"})
      assert {:error, :missing_source} = Commands.Sound.sound_apply(%{"route" => "voicemail"})

      assert {:error, {:not_imported, "nope.wav"}} =
               Commands.Sound.sound_apply(%{"source" => "nope.wav", "route" => "voicemail"})
    end

    test "an existing library name, and a bundled one, are both refused", %{root: root} do
      library(root, "taken.wav")

      assert {:error, :name_taken} =
               Commands.Sound.sound_apply(%{
                 "source" => "sentence.wav",
                 "route" => "voicemail",
                 "name" => "taken"
               })

      # The wider hazard, and the one that is invisible in the routing table:
      # the workspace overrides the bundled set BY BASENAME, so installing
      # "alarm.wav" replaces the built-in alarm for every key that falls back
      # to it, not only the key being routed.
      assert "alarm.wav" in Sound.bundled_list()

      assert {:error, :shadows_bundled} =
               Commands.Sound.sound_apply(%{
                 "source" => "sentence.wav",
                 "route" => "voicemail",
                 "name" => "alarm"
               })

      assert {:ok, shadow} =
               Commands.Sound.sound_apply(%{
                 "source" => "sentence.wav",
                 "route" => "voicemail",
                 "name" => "alarm",
                 "overwrite" => true
               })

      assert shadow.shadowing
      assert Enum.any?(shadow.notes, &(&1 =~ "shadow"))
      assert {:ok, listing} = Commands.Sound.sound_list()
      assert entry(listing, "alarm.wav").shadowing
    end

    test "it says so when the master switch is off", %{root: _root} do
      Sound.set_enabled(false)
      on_exit(fn -> Sound.set_enabled(true) end)

      assert {:ok, result} =
               Commands.Sound.sound_apply(%{"source" => "sentence.wav", "route" => "timer"})

      refute result.enabled
      assert Enum.any?(result.notes, &(&1 =~ "master sound switch is OFF"))
    end
  end

  describe "sound_restore_defaults" do
    test "copies the bundled set in without ever overwriting", %{root: root} do
      # An operator's own file under a bundled name: the restore must leave it
      # alone, because that file is their edit or their replacement.
      library(root, "alarm.wav", "not really audio")

      assert {:ok, result} = Commands.Sound.sound_restore_defaults()

      assert "alarm.wav" in result.skipped
      assert result.counts.copied > 0
      assert result.still_missing == []
      assert File.read!(Path.join([root, "sounds", "alarm.wav"])) == "not really audio"
      assert File.regular?(Path.join([root, "sounds", "boot.wav"]))

      # Files only, unless asked.
      assert result.cleared_routes == []
      assert Enum.any?(result.notes, &(&1 =~ "Routing was NOT touched"))
    end

    test "clearing the routes is the way back from a sound_apply", %{root: root} do
      source(root, "sentence.wav", speech())

      assert {:ok, _applied} =
               Commands.Sound.sound_apply(%{
                 "source" => "sentence.wav",
                 "route" => "voicemail",
                 "name" => "ramshackle"
               })

      assert Sound.resolved("voicemail") == "ramshackle.wav"

      assert {:ok, result} =
               Commands.Sound.sound_restore_defaults(%{"sounds" => false, "routes" => true})

      assert result.cleared_routes == ["voicemail"]
      assert result.counts.copied == 0

      # The key inherits again and falls back to its bundled chime. The applied
      # file is still on disk — nothing is deleted, only unrouted.
      assert Sound.sound_map() == %{}
      assert Sound.resolved("voicemail") in ["voicemail.wav", "ramshackle.wav"]
      assert File.regular?(Path.join([root, "sounds", "ramshackle.wav"]))
    end
  end

  # ---------------------------------------------------------------------------
  # The acceptance criterion, unmet since 08-02
  # ---------------------------------------------------------------------------

  describe "the acceptance walk" do
    # STUDIO_ROADMAP Part I: "a voicemail becomes a routed sound effect end to
    # end, from the CLI alone, with no UI involved."
    #
    # Every step goes through `Commands.call/3` BY NAME. That is the assertion —
    # a handler nothing can reach through the dispatcher is not a command
    # surface, and this walk fails on a missing catalog entry, a missing
    # registration and a missing delegate exactly as loudly as on a broken edit.
    test "a voicemail becomes a routed sound effect, from the CLI alone", %{root: root} do
      event = voicemail(root, "meet me at the harbor", audio: speech())

      # 1. Look before importing — the agent's only substitute for ears.
      assert {:ok, %{layer: "library", duration_ms: heard}} =
               Commands.call("sound_probe", %{"event_id" => event.id})

      assert heard > 0

      # 2. Through the studio door.
      assert {:ok, %{name: imported, internal: true}} =
               Commands.call("sound_import", %{"event_id" => event.id})

      # 3. Give it timings. No recognizer: the transcript is fitted onto the
      #    speech the detector found.
      assert {:ok, %{source: ^imported, words: 5}} =
               Commands.call("sound_align", %{"event_id" => event.id})

      # 4. Search the index for a word, and get back something that is already
      #    a cut.
      assert {:ok, %{hits: [harbor]}} =
               Commands.call("sound_index_search", %{"query" => "harbor"})

      assert {:ok, %{hits: [meet]}} = Commands.call("sound_index_search", %{"query" => "meet"})
      assert harbor.source == imported
      assert harbor.end_ms > harbor.start_ms

      # 5. Assemble the hits into a clip, in the order they should be spoken.
      cut = fn hit -> Map.take(hit, [:source, :start_ms, :end_ms]) end

      assert {:ok, %{name: sentence, duration_ms: assembled}} =
               Commands.call("sound_assemble", %{
                 "name" => "ramshackle",
                 "cuts" => [cut.(meet), cut.(harbor)]
               })

      assert assembled > 0

      # 6. Edit it: trim the tail, then level it.
      assert {:ok, %{name: trimmed, duration_ms: shorter}} =
               Commands.call("sound_trim", %{
                 "source" => sentence,
                 "end_ms" => assembled - 50
               })

      assert shorter < assembled

      assert {:ok, %{name: levelled, peak: peak}} =
               Commands.call("sound_normalize", %{"source" => trimmed})

      assert_in_delta peak, 0.891, 0.01

      # 7. Route it. The gated step, and the only one that changes what the
      #    machine does when nobody is watching.
      assert {:ok, applied} =
               Commands.call("sound_apply", %{
                 "source" => levelled,
                 "route" => "voicemail",
                 "name" => "ramshackle-chime"
               })

      # The library file exists...
      assert applied.name == "ramshackle-chime.wav"
      assert File.regular?(Path.join([root, "sounds", "ramshackle-chime.wav"]))

      # ...and the route resolves to it, both as the routing table reports it
      # and as a fired notification would resolve it.
      assert Sound.resolved("voicemail") == "ramshackle-chime.wav"

      assert Sound.for_notification(%{source: "voicemail", kind: "alarm"}) ==
               "ramshackle-chime.wav"

      assert {:ok, routes} = Commands.call("sound_routes", %{})
      assert %{plays: "ramshackle-chime.wav", origin: "explicit"} = route(routes, "voicemail")

      assert {:ok, listing} = Commands.call("sound_list", %{})
      assert %{layer: "workspace"} = entry(listing, "ramshackle-chime.wav")

      # And the way back is reachable by name too.
      assert {:ok, %{cleared_routes: ["voicemail"]}} =
               Commands.call("sound_restore_defaults", %{"sounds" => false, "routes" => true})

      assert Sound.sound_map() == %{}
      assert {:ok, cleared} = Commands.call("sound_routes", %{})
      assert route(cleared, "voicemail").assigned == nil
      refute route(cleared, "voicemail").origin == "explicit"

      # Worth knowing, and not a bug: the clip still PLAYS for voicemail here,
      # because the legacy fallback picks the first audio file in the workspace
      # library alphabetically and this workspace has exactly one. Clearing a
      # route removes the assignment, not the file — sound_list is where you see
      # that, and deleting the file is the other half of an undo.
      assert route(cleared, "voicemail").origin == "fallback"
    end

    test "the gate is real: an untrusted run cannot route a key", %{root: root} do
      source(root, "sentence.wav", speech())

      # Everything up to the routing step is reachable by an autonomous run
      # working untrusted-origin content...
      assert {:ok, _trimmed} =
               Commands.call("sound_trim", %{"source" => "sentence.wav", "end_ms" => 300},
                 caller: :agent_untrusted
               )

      # ...and the one act that changes what the machine does unattended is not.
      assert {:error, :requires_confirmation} =
               Commands.call(
                 "sound_apply",
                 %{"source" => "sentence.wav", "route" => "voicemail"},
                 caller: :agent_untrusted
               )

      assert Sound.sound_map() == %{}
      refute File.exists?(Path.join([root, "sounds", "sentence.wav"]))
    end
  end

  # A WAV this app did not write, shaped the way a foreign renderer really
  # shapes one. The awkward part is not invented: `say -o out.wav
  # --data-format=LEI16@22050` emits a **JUNK padding chunk ahead of `fmt `**, so
  # `fmt ` begins at byte 48 rather than 12 and `data` is nowhere near byte 44.
  # Measured on macOS 26.6.2 before this test was written. A parser that seeks to
  # a fixed 44-byte header reads that padding as audio — a burst of noise at the
  # head of every imported clip — which is exactly what `parse/1`'s chunk walk
  # exists to prevent, and which nothing else here exercises with a header laid
  # out by something other than us.
  defp foreign_wav(rate, ms) do
    count = trunc(rate * ms / 1000)

    pcm =
      for i <- 0..(count - 1), into: <<>> do
        <<trunc(:math.sin(2 * :math.pi() * 440 * i / rate) * 8_000)::little-signed-16>>
      end

    block_align = 2

    body =
      <<"JUNK", 28::little-32>> <>
        :binary.copy(<<0>>, 28) <>
        <<"fmt ", 16::little-32, 1::little-16, 1::little-16, rate::little-32,
          rate * block_align::little-32, block_align::little-16, 16::little-16, "data",
          byte_size(pcm)::little-32>> <> pcm

    <<"RIFF", 4 + byte_size(body)::little-32, "WAVE">> <> body
  end

  describe "the external-render bridge" do
    # The acceptance walk above proves a file becomes a routed chime — but only
    # for audio this app assembled itself. Every step it takes between import and
    # apply (align, index_search, assemble) belongs to the cut-up engine. Remove
    # that engine and the walk goes with it, taking the only end-to-end assertion
    # that anything can become a routed chime at all.
    #
    # This is that assertion rebuilt on the half that does not depend on the
    # cut-up engine: audio rendered by something ELSE — a speech engine on
    # another machine, or `say(1)` on this one — arrives as a plain file and
    # walks out a routed chime. The app cannot tell what produced it, and that
    # indifference is the actual contract.
    #
    # Every step goes through `Commands.call/3` BY NAME, for the reason the
    # acceptance walk gives: a handler nothing can reach through the dispatcher
    # is not a command surface.

    test "audio rendered elsewhere becomes a routed chime, from the CLI alone", %{root: root} do
      # 1. Something that is not this app writes into the Library.
      File.write!(Path.join([root, "library", "spoken.wav"]), foreign_wav(22_050, 400))

      # 2. Look before importing — the agent's only substitute for ears.
      assert {:ok, %{layer: "library", peak: heard}} =
               Commands.call("sound_probe", %{"path" => "spoken.wav"})

      assert heard > 0.0

      # 3. Through the studio door. Already the internal format, so the cheap
      #    path answers and the decoder is never reached — but the header still
      #    has to be walked rather than assumed.
      assert {:ok, %{name: "spoken.wav", internal: true, decoded: false}} =
               Commands.call("sound_import", %{"path" => "spoken.wav"})

      # 4. The gated step, unchanged and unaware that its input was synthesized
      #    rather than recorded.
      assert {:ok, applied} =
               Commands.call("sound_apply", %{
                 "source" => "spoken.wav",
                 "route" => "voicemail",
                 "name" => "spoken-chime"
               })

      assert applied.name == "spoken-chime.wav"
      assert applied.duration_ms > 0
      assert File.regular?(Path.join([root, "sounds", "spoken-chime.wav"]))

      # 5. And it resolves the way a fired notification would resolve it.
      assert Sound.resolved("voicemail") == "spoken-chime.wav"
      assert Sound.for_notification(%{source: "voicemail", kind: "alarm"}) == "spoken-chime.wav"
    end

    if @decoder_available do
      test "a foreign sample rate is converted on the way in", %{root: root} do
        # 48 kHz is not the internal format, so this is the decode path. Most
        # renderers emit 24 kHz or 48 kHz, and the caller must not have to know
        # that before handing a file over.
        File.write!(Path.join([root, "library", "hifi.wav"]), foreign_wav(48_000, 400))

        assert {:ok, %{name: "hifi.wav", internal: true, decoded: true}} =
                 Commands.call("sound_import", %{"path" => "hifi.wav"})

        assert {:ok, %{route: "voicemail"}} =
                 Commands.call("sound_apply", %{
                   "source" => "hifi.wav",
                   "route" => "voicemail",
                   "name" => "hifi-chime"
                 })

        assert Sound.resolved("voicemail") == "hifi-chime.wav"
      end
    end
  end

  describe "sound_find" do
    setup %{root: root} do
      source(root, "planted.wav", planted())
      # An index is what makes a source a default target, and this one is
      # `aligned` so the relabel to `recognizer` is visible in the result.
      indexed("planted.wav", [{"harbor", 200, 500}])
      :ok
    end

    test "finds the planted second take and writes it as origin recognizer" do
      assert {:ok, result} = Commands.Sound.sound_find(template())

      assert result.word == "harbor"
      assert result.threshold == 6.0
      assert result.template.frame0 == 20
      assert result.template.cold

      # The template's own span comes back at a distance near zero. That is the
      # cheapest proof the search ran, and it is not a discovery.
      assert [%{source: "planted.wav"} = found] = result.sources
      assert Enum.any?(found.matches, & &1.template)

      discovered = Enum.reject(found.matches, & &1.template)
      assert [%{start_ms: start_ms, distance: distance}] = discovered
      assert_in_delta start_ms, 1200.0, 120.0
      assert distance < 6.0

      assert result.counts.new_matches == 1
      assert result.counts.added == 1
      assert found.written
      assert found.previous_origin == :aligned
      assert found.origin == :recognizer

      # And it is on disk, merged beside the word that was already there.
      assert {:ok, index} = Index.load("planted.wav")
      assert index.origin == :recognizer
      assert length(index.words) == 2
      assert Enum.all?(index.words, &(&1.word == "harbor"))

      # A recognizer hit is a cut, exactly like any other index hit.
      assert {:ok, %{count: 2}} = Commands.Sound.sound_index_search(%{"query" => "harbor"})
    end

    test "confidence ranks the distance and never claims a hand-marked 1.0" do
      assert {:ok, result} = Commands.Sound.sound_find(template())

      for match <- Enum.flat_map(result.sources, & &1.matches) do
        assert match.confidence <= 0.9
        assert match.confidence >= 0.1
        assert is_float(match.distance)
      end

      assert result.distances.min <= result.distances.max
    end

    test "warm_only skips uncached sources and says which", %{root: root} do
      source(root, "other.wav", planted())
      indexed("other.wav", [{"harbor", 200, 500}])

      # Warm the template source alone, without touching any index.
      assert {:ok, _first} =
               Commands.Sound.sound_find(
                 template(%{"targets" => ["planted.wav"], "write" => false})
               )

      assert Features.cached?("planted.wav")
      refute Features.cached?("other.wav")

      assert {:ok, result} = Commands.Sound.sound_find(template(%{"warm_only" => true}))

      assert result.warm_only
      assert result.skipped_sources == ["other.wav"]
      assert result.counts.skipped_cold == 1
      assert result.counts.searched == 1
      assert Enum.any?(result.notes, &(&1 =~ "warm_only was set"))

      # The whole point: it did not spend a minute analysing it.
      refute Features.cached?("other.wav")
      assert {:ok, %{origin: :aligned}} = Index.load("other.wav")
    end

    test "warm_only refuses outright when the template itself is cold" do
      assert {:error, {:template_not_cached, "planted.wav"}} =
               Commands.Sound.sound_find(template(%{"warm_only" => true}))
    end

    test "write false searches and reports without touching an index" do
      assert {:ok, result} = Commands.Sound.sound_find(template(%{"write" => false}))

      refute result.wrote
      assert result.counts.new_matches == 1
      assert result.counts.added == 0
      assert [%{written: false, origin: nil}] = result.sources

      assert {:ok, %{origin: :aligned, words: [_only_one]}} = Index.load("planted.wav")
    end

    test "an existing word is not clobbered without overwrite" do
      assert {:ok, %{counts: %{added: 1}}} = Commands.Sound.sound_find(template())

      # Second run: the take it wrote a moment ago is now in the way.
      assert {:ok, again} = Commands.Sound.sound_find(template())
      assert [%{added: 0, skipped_overlapping: 1, replaced: 0}] = again.sources
      assert {:ok, %{words: two}} = Index.load("planted.wav")
      assert length(two) == 2

      assert {:ok, forced} = Commands.Sound.sound_find(template(%{"overwrite" => true}))
      assert [%{added: 1, replaced: 1}] = forced.sources
      assert {:ok, %{words: still_two}} = Index.load("planted.wav")
      assert length(still_two) == 2
    end

    test "the notes carry the measured guidance, not a bare number" do
      assert {:ok, result} = Commands.Sound.sound_find(template())

      joined = Enum.join(result.notes, " ")
      assert joined =~ "SHORTLIST GENERATOR"
      assert joined =~ "one in eight"
      assert joined =~ "speaker- and channel-dependent"
      assert joined =~ "origin on an index is a property of the WHOLE file"
    end

    test "bad inputs are named errors" do
      assert {:error, :missing_word} = Commands.Sound.sound_find(Map.delete(template(), "word"))
      assert {:error, :invalid_word} = Commands.Sound.sound_find(template(%{"word" => ",,,"}))
      assert {:error, :missing_span} = Commands.Sound.sound_find(Map.delete(template(), "end_ms"))

      assert {:error, :invalid_span} =
               Commands.Sound.sound_find(template(%{"start_ms" => 500, "end_ms" => 200}))

      assert {:error, :invalid_span} = Commands.Sound.sound_find(template(%{"start_ms" => -1}))

      assert {:error, :invalid_name} =
               Commands.Sound.sound_find(template(%{"source" => "../secrets.wav"}))

      assert {:error, :invalid_name} =
               Commands.Sound.sound_find(template(%{"targets" => ["../secrets.wav"]}))

      assert {:error, :invalid_name} =
               Commands.Sound.sound_find(template(%{"targets" => ["/etc/passwd"]}))

      assert {:error, :no_targets} = Commands.Sound.sound_find(template(%{"targets" => []}))
      assert {:error, :invalid_targets} = Commands.Sound.sound_find(template(%{"targets" => "x"}))
      assert {:error, :missing_source} = Commands.Sound.sound_find(%{"word" => "harbor"})

      # A span past the end of the recording has no frames to slice.
      assert {:error, :empty_template} =
               Commands.Sound.sound_find(template(%{"start_ms" => 90_000, "end_ms" => 91_000}))

      # A source that is not in the studio at all.
      assert {:error, :not_found} =
               Commands.Sound.sound_find(template(%{"source" => "absent.wav"}))
    end
  end

  describe "sound_sentence" do
    setup %{root: root} do
      source(root, "voicemail-03.wav", planted())

      indexed(
        "voicemail-03.wav",
        [
          {"meet", 100, 300},
          {"me", 400, 550},
          {"at", 700, 820},
          {"the", 900, 1000},
          {"harbor", 1100, 1400}
        ]
      )

      :ok
    end

    test "assembles the phrase into a real file", %{root: root} do
      assert {:ok, result} =
               Commands.Sound.sound_sentence(%{
                 "phrase" => "Meet me at the harbor.",
                 "name" => "hello"
               })

      assert result.name == "hello.wav"
      assert result.missing == []
      assert result.duration_ms > 0.0
      assert result.peak > 0.0
      refute result.replaced
      assert File.regular?(Path.join([root, "sounds", "studio", "hello.wav"]))

      # Punctuation and case are normalized away by the same function the corpus
      # is stored under, so "Meet" and "harbor." both resolve.
      assert Enum.map(result.words, & &1.word) == ~w(meet me at the harbor)
      assert Enum.map(result.words, & &1.text) == ["Meet", "me", "at", "the", "harbor."]
      assert Enum.all?(result.words, &(&1.takes == 1))
      assert result.sources == [%{source: "voicemail-03.wav", words: 5}]

      # It landed as a SOURCE, not in the routed library.
      assert {:ok, %{sources: sources}} = Commands.Sound.sound_sources()
      assert Enum.any?(sources, &(&1.name == "hello.wav"))
      assert {:ok, %{sounds: sounds}} = Commands.Sound.sound_list()
      refute Enum.any?(sounds, &(&1.name == "hello.wav"))
    end

    test "one take per word reports that the lattice chose nothing" do
      assert {:ok, result} =
               Commands.Sound.sound_sentence(%{"phrase" => "meet me", "name" => "pair"})

      assert result.selection.slots == 2
      assert result.selection.candidates == 2
      refute result.selection.chose
      assert Enum.any?(result.notes, &(&1 =~ "CHOSE NOTHING"))
      assert Enum.any?(result.notes, &(&1 =~ "more recordings" or &1 =~ "More recordings"))
    end

    test "a second take of a word gives the search something to do", %{root: root} do
      source(root, "voicemail-04.wav", planted())
      indexed("voicemail-04.wav", [{"harbor", 200, 500}])

      assert {:ok, result} =
               Commands.Sound.sound_sentence(%{"phrase" => "meet harbor", "name" => "choice"})

      assert result.selection.slots == 2
      assert result.selection.candidates == 3
      assert result.selection.chose
      assert %{word: "harbor", takes: 2} = Enum.at(result.words, 1)
      assert Enum.any?(result.notes, &(&1 =~ "candidate takes across"))
    end

    test "a word with no take is fatal, and named" do
      assert {:error, {:words_not_found, ["zebra"]}} =
               Commands.Sound.sound_sentence(%{"phrase" => "meet the zebra", "name" => "z"})

      # Nothing was written on the refusal.
      assert {:ok, %{sources: sources}} = Commands.Sound.sound_sources()
      refute Enum.any?(sources, &(&1.name == "z.wav"))

      assert {:ok, result} =
               Commands.Sound.sound_sentence(%{
                 "phrase" => "meet the zebra",
                 "name" => "z",
                 "allow_missing" => true
               })

      assert result.missing == ["zebra"]
      assert Enum.map(result.words, & &1.word) == ~w(meet the)
      assert Enum.any?(result.notes, &(&1 =~ "NOT in this sentence"))
      assert Enum.any?(result.notes, &(&1 =~ "zebra"))
    end

    test "a phrase with no takes at all is refused" do
      assert {:error, :no_takes} =
               Commands.Sound.sound_sentence(%{
                 "phrase" => "zebra platypus",
                 "name" => "nothing",
                 "allow_missing" => true
               })
    end

    test "features are imputed rather than computed, and it says so" do
      assert {:ok, result} =
               Commands.Sound.sound_sentence(%{"phrase" => "meet me", "name" => "cold"})

      refute result.features.warm
      assert result.features.with_features == []
      assert result.features.without_features == ["voicemail-03.wav"]
      assert result.selection.imputed.typicality == 2
      assert Enum.any?(result.notes, &(&1 =~ "No cached features"))

      # Nothing was analysed: the default must never spend the ~109 s a cold
      # source costs.
      refute Features.cached?("voicemail-03.wav")
    end

    test "warm true analyses the sources it needs" do
      assert {:ok, result} =
               Commands.Sound.sound_sentence(%{
                 "phrase" => "meet me",
                 "name" => "warmed",
                 "warm" => true
               })

      assert result.features.warm
      assert result.features.with_features == ["voicemail-03.wav"]
      assert result.features.without_features == []
      assert result.features.analysed == ["voicemail-03.wav"]
      assert Features.cached?("voicemail-03.wav")
    end

    test "assembly and selection options are passed through" do
      assert {:ok, loose} =
               Commands.Sound.sound_sentence(%{"phrase" => "meet me", "name" => "loose"})

      assert {:ok, tight} =
               Commands.Sound.sound_sentence(%{
                 "phrase" => "meet me",
                 "name" => "tight",
                 "pad_ms" => 0,
                 "gap_ms" => 0,
                 "fade_ms" => 0,
                 "normalize" => false,
                 "weights" => %{"confidence" => 2.0, "spectral" => 0}
               })

      assert tight.duration_ms < loose.duration_ms
      assert tight.options == %{pad_ms: 0.0, gap_ms: 0.0, fade_ms: 0.0, normalize: false}
      assert tight.selection.weights.confidence == 2.0
      assert tight.selection.weights.spectral == 0.0
    end

    test "it refuses to overwrite, and the refusal costs nothing" do
      assert {:ok, _first} =
               Commands.Sound.sound_sentence(%{"phrase" => "meet me", "name" => "sentence"})

      assert {:error, :name_taken} =
               Commands.Sound.sound_sentence(%{"phrase" => "meet me", "name" => "sentence"})

      # Refused before the phrase is even looked up: a missing word does not
      # win a race against a taken name.
      assert {:error, :name_taken} =
               Commands.Sound.sound_sentence(%{"phrase" => "zebra", "name" => "sentence"})

      assert {:ok, %{replaced: true}} =
               Commands.Sound.sound_sentence(%{
                 "phrase" => "meet me",
                 "name" => "sentence",
                 "overwrite" => true
               })
    end

    test "bad inputs are named errors" do
      assert {:error, :missing_phrase} = Commands.Sound.sound_sentence(%{"name" => "x"})
      assert {:error, :missing_name} = Commands.Sound.sound_sentence(%{"phrase" => "meet"})

      assert {:error, :empty_phrase} =
               Commands.Sound.sound_sentence(%{"phrase" => ",,,", "name" => "x"})

      assert {:error, :empty_phrase} =
               Commands.Sound.sound_sentence(%{"phrase" => "  ", "name" => "x"})

      assert {:error, :invalid_name} =
               Commands.Sound.sound_sentence(%{"phrase" => "meet", "name" => "../escape"})

      assert {:error, :invalid_name} =
               Commands.Sound.sound_sentence(%{"phrase" => "meet", "name" => "/tmp/escape"})

      assert {:error, :invalid_weights} =
               Commands.Sound.sound_sentence(%{
                 "phrase" => "meet",
                 "name" => "x",
                 "weights" => %{"nonsense" => 1.0}
               })

      assert {:error, :invalid_weights} =
               Commands.Sound.sound_sentence(%{
                 "phrase" => "meet",
                 "name" => "x",
                 "weights" => %{"confidence" => -1.0}
               })
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

    test "the matcher and the sentence are reachable through Commands.call/3", %{root: root} do
      source(root, "planted.wav", planted())
      indexed("planted.wav", [{"harbor", 200, 500}])

      assert {:ok, %{word: "harbor", counts: %{added: 1}}} =
               Commands.call("sound_find", template())

      assert {:ok, %{name: "line.wav", missing: []}} =
               Commands.call("sound_sentence", %{"phrase" => "harbor", "name" => "line"})

      assert {:error, :name_taken} =
               Commands.call("sound_sentence", %{"phrase" => "harbor", "name" => "line"})

      assert {:error, {:words_not_found, ["zebra"]}} =
               Commands.call("sound_sentence", %{"phrase" => "zebra", "name" => "z"})

      assert {:error, :invalid_name} =
               Commands.call("sound_find", template(%{"source" => "../secrets.wav"}))
    end

    test "sound_align is reachable through Commands.call/3", %{root: root} do
      {event, source} = aligned_voicemail(root)

      assert {:ok, %{source: ^source, words: 5, spans: 3}} =
               Commands.call("sound_align", %{"event_id" => event.id})

      assert {:error, :index_exists} = Commands.call("sound_align", %{"event_id" => event.id})

      assert {:ok, %{hits: [%{source: ^source}]}} =
               Commands.call("sound_index_search", %{"query" => "harbor"})
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

      # The ones that write. Restricted, and deliberately NOT gated: they write
      # a new source, a text index, or the shipped defaults back, and none of
      # them routes anything.
      for name <- ~w(
            sound_import sound_align sound_find sound_sentence
            sound_index_import sound_index_delete sound_assemble
            sound_trim sound_fade sound_normalize sound_concat sound_delete
            sound_restore_defaults
          ) do
        entry = Map.fetch!(catalog, name)
        assert entry.type == :mutate, "#{name} should be a mutate"
        assert entry.tier == :restricted, "#{name} should be restricted"
        refute Map.get(entry, :gated, false), "#{name} should not be gated"
      end

      # And the one that is. Routing changes what the machine does when nobody
      # is watching, which is the whole of the difference.
      apply_entry = Map.fetch!(catalog, "sound_apply")
      assert apply_entry.type == :mutate
      assert apply_entry.tier == :restricted
      assert apply_entry.gated
      assert apply_entry.args["source"].required
      assert apply_entry.args["route"].required
      refute apply_entry.args["overwrite"].default
      assert apply_entry.description =~ "unknown_route"
      assert apply_entry.description =~ "sound_routes"

      # Every editing verb renders to a new name and refuses to clobber.
      for name <- ~w(sound_trim sound_fade sound_normalize sound_concat) do
        args = Map.fetch!(catalog, name).args
        refute args["overwrite"].default, "#{name} must not default to overwriting"
      end

      assert Map.fetch!(catalog, "sound_concat").args["sources"].required
      assert Map.fetch!(catalog, "sound_concat").args["name"].required
      refute Map.fetch!(catalog, "sound_delete").args["delete_index"].default

      # The four alignment knobs the first real listen produced. They are only
      # reachable if they are declared: the catalog is the whole of what the
      # model sees, so an option that exists in the handler and not here is an
      # option nothing will ever pass.
      align_args = Map.fetch!(catalog, "sound_align").args
      assert align_args["snap_to_energy"].default
      assert align_args["snap_window_ms"].default == 40.0
      assert align_args["reduce_function_words"].default
      assert align_args["function_word_scale"].default == 0.55

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

      # sound_align's two ways in are alternatives too, and its description has
      # to say the thing a model choosing between verbs needs: the timings are
      # approximate, and this is what makes the index verbs usable.
      align = Map.fetch!(catalog, "sound_align")
      refute align.args["event_id"].required
      refute align.args["source"].required
      refute align.args["transcript"].required
      refute align.args["overwrite"].default
      assert align.args["weight"].enum == ["syllables", "characters"]
      assert align.description =~ "APPROXIMATE"
      assert align.description =~ "sound_index_search"
      assert align.description =~ "sound_import"

      # The matcher's description has to carry the MEASURED guidance rather than
      # a bare threshold — the synthetic band does not transfer to real speech,
      # and a model that reads 0.2–0.9 anywhere will match nothing — and it has
      # to price the cold path, which is the reason warm_only exists.
      find = Map.fetch!(catalog, "sound_find")
      assert find.args["word"].required
      assert find.args["source"].required
      assert find.args["start_ms"].required
      assert find.args["end_ms"].required
      refute find.args["overwrite"].default
      refute find.args["warm_only"].default
      assert find.args["write"].default
      assert find.args["threshold"].default == 6.0
      assert find.description =~ "precision 0.88"
      assert find.description =~ "does NOT transfer to real speech"
      assert find.description =~ "SHORTLIST GENERATOR"
      assert find.description =~ "109 seconds"
      assert find.description =~ "warm_only"
      assert find.description =~ "origin recognizer"

      # And the sentence's has to lead with the two things that can be silently
      # wrong: a word it could not find, and a lattice that decided nothing.
      sentence = Map.fetch!(catalog, "sound_sentence")
      assert sentence.args["phrase"].required
      assert sentence.args["name"].required
      refute sentence.args["overwrite"].default
      refute sentence.args["allow_missing"].default
      refute sentence.args["warm"].default
      assert sentence.description =~ "missing"
      assert sentence.description =~ "candidates equal to slots"
      assert sentence.description =~ "imputed"
      assert sentence.description =~ "weights"
    end
  end
end
