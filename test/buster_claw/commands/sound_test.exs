defmodule BusterClaw.Commands.SoundTest do
  # async: false — points the global :workspace_root at a tmp dir, which is how
  # both the sound library and the studio folder resolve.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Commands
  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Notifications.SoundGen
  alias BusterClaw.Studio.Editor

  # afconvert is a macOS system binary, but the suite should not fail on a
  # machine without it — the decode-dependent cases are skipped instead, the
  # same way `sound_studio_test.exs` handles them.
  @decoder_available File.regular?("/usr/bin/afconvert")

  setup do
    root = Path.join(System.tmp_dir!(), "bc_cmd_sound_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([root, "sounds", "studio"]))
    # The Library root is where a Library-relative path resolves from.
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

    Editor.render(%Editor{data: silence <> body <> silence})
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
  defp flat(ms \\ 200), do: Editor.render(%Editor{data: dc(ms)})

  defp dc(ms), do: :binary.copy(<<8000::little-signed-16>>, trunc(22_050 * ms / 1000))

  defp first_sample(path) do
    {:ok, clip} = Editor.read(path)
    <<sample::little-signed-16, _rest::binary>> = clip.data
    sample
  end

  defp last_sample(path) do
    {:ok, clip} = Editor.read(path)
    <<sample::little-signed-16>> = binary_part(clip.data, byte_size(clip.data) - 2, 2)
    sample
  end

  defp library(root, name, contents \\ nil),
    do: File.write!(Path.join([root, "sounds", name]), contents || wav())

  defp source(root, name, contents \\ nil),
    do: File.write!(Path.join([root, "sounds", "studio", name]), contents || wav())

  defp entry(%{sounds: sounds}, name), do: Enum.find(sounds, &(&1.name == name))
  defp route(%{routes: routes}, key), do: Enum.find(routes, &(&1.key == key))

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
      assert route(table, "email").label == "Email"

      # Nothing assigned: the bundled default is the floor, and the answer is
      # marked as a fallback rather than an operator choice.
      timer = route(table, "timer")
      assert timer.assigned == nil
      assert timer.plays == "timer.wav"
      assert timer.plays_layer == "bundled"
      assert timer.origin == "fallback"
    end

    test "explicit, inherited, and silent routes are distinguished" do
      assert :ok = Sound.assign("email", "boot.wav")
      assert :ok = Sound.assign("chat", Sound.silent())
      assert :ok = Sound.assign("default", "alarm.wav")

      assert {:ok, table} = Commands.Sound.sound_routes()

      assert %{
               assigned: "boot.wav",
               plays: "boot.wav",
               plays_layer: "bundled",
               origin: "explicit"
             } =
               route(table, "email")

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
      source(root, "silence.wav", Editor.render(%Editor{data: pcm(200, 0.0)}))

      assert {:ok, result} = Commands.Sound.sound_normalize(%{"source" => "silence.wav"})

      assert result.source_peak == 0.0
      assert result.peak == 0.0
    end
  end

  describe "sound_concat" do
    setup %{root: root} do
      source(root, "one.wav", Editor.render(%Editor{data: dc(200)}))
      source(root, "two.wav", Editor.render(%Editor{data: dc(100)}))
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
        Editor.render(%Editor{
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
      assert result.bytes > 0
      refute File.exists?(Path.join([root, "sounds", "studio", "scratch.wav"]))

      # The library and the routing table are a different store.
      assert File.regular?(Path.join([root, "sounds", "keeper.wav"]))

      assert {:error, {:not_imported, "scratch.wav"}} =
               Commands.Sound.sound_trim(%{"source" => "scratch.wav"})
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
                 "route" => "email",
                 "name" => "ramshackle"
               })

      assert result.name == "ramshackle.wav"
      assert result.route == "email"
      assert result.route_label == "Email"
      assert result.duration_ms > 0
      assert result.peak > 0.0
      refute result.shadowing
      refute result.replaced

      # The file is in the library, which is the store the player reads.
      assert File.regular?(Path.join([root, "sounds", "ramshackle.wav"]))
      assert Sound.path_for("ramshackle.wav")

      # And the routing table actually resolves to it — for the key, and for a
      # notification that would fire against that key.
      assert Sound.resolved("email") == "ramshackle.wav"
      assert Sound.for_notification(%{source: "email", kind: "timer"}) == "ramshackle.wav"

      assert {:ok, routes} = Commands.Sound.sound_routes()

      assert %{assigned: "ramshackle.wav", plays: "ramshackle.wav", origin: "explicit"} =
               route(routes, "email")

      # The studio source is untouched: the library holds a copy.
      assert File.regular?(Path.join([root, "sounds", "studio", "sentence.wav"]))
    end

    test "the way back is in the result", %{root: root} do
      library(root, "old.wav")
      assert :ok = Sound.assign("email", "old.wav")

      assert {:ok, result} =
               Commands.Sound.sound_apply(%{
                 "source" => "sentence.wav",
                 "route" => "email",
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
      assert {:error, :missing_source} = Commands.Sound.sound_apply(%{"route" => "email"})

      assert {:error, {:not_imported, "nope.wav"}} =
               Commands.Sound.sound_apply(%{"source" => "nope.wav", "route" => "email"})
    end

    test "an existing library name, and a bundled one, are both refused", %{root: root} do
      library(root, "taken.wav")

      assert {:error, :name_taken} =
               Commands.Sound.sound_apply(%{
                 "source" => "sentence.wav",
                 "route" => "email",
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
                 "route" => "email",
                 "name" => "alarm"
               })

      assert {:ok, shadow} =
               Commands.Sound.sound_apply(%{
                 "source" => "sentence.wav",
                 "route" => "email",
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
                 "route" => "email",
                 "name" => "ramshackle"
               })

      assert Sound.resolved("email") == "ramshackle.wav"

      assert {:ok, result} =
               Commands.Sound.sound_restore_defaults(%{"sounds" => false, "routes" => true})

      assert result.cleared_routes == ["email"]
      assert result.counts.copied == 0

      # The key inherits again and falls back to its bundled chime. The applied
      # file is still on disk — nothing is deleted, only unrouted.
      assert Sound.sound_map() == %{}
      assert Sound.resolved("email") in ["voicemail.wav", "ramshackle.wav"]
      assert File.regular?(Path.join([root, "sounds", "ramshackle.wav"]))
    end
  end

  # ---------------------------------------------------------------------------
  # The acceptance criterion, unmet since 08-02
  # ---------------------------------------------------------------------------

  describe "the acceptance walk" do
    # STUDIO_ROADMAP Part I: "a recording becomes a routed sound effect end to
    # end, from the CLI alone, with no UI involved." (It was a voicemail until
    # the phone left on 10-15; a Library-relative recording walks the same path.)
    #
    # Every step goes through `Commands.call/3` BY NAME. That is the assertion —
    # a handler nothing can reach through the dispatcher is not a command
    # surface, and this walk fails on a missing catalog entry, a missing
    # registration and a missing delegate exactly as loudly as on a broken edit.
    test "a recording becomes a routed sound effect, from the CLI alone", %{root: root} do
      relative = recording(root, "calls/harbor.wav", speech())

      # 1. Look before importing — the agent's only substitute for ears.
      assert {:ok, %{layer: "library", duration_ms: heard}} =
               Commands.call("sound_probe", %{"path" => relative})

      assert heard > 0

      # 2. Through the studio door.
      assert {:ok, %{name: imported, internal: true}} =
               Commands.call("sound_import", %{"path" => relative})

      # 3. Edit it: trim the tail, then level it. (Until 09-19 the walk also
      #    aligned the transcript, searched the word index and assembled a
      #    sentence here; those verbs left with the cut-up engine.)
      assert {:ok, %{name: trimmed, duration_ms: shorter}} =
               Commands.call("sound_trim", %{"source" => imported, "end_ms" => heard - 50})

      assert shorter < heard

      assert {:ok, %{name: levelled, peak: peak}} =
               Commands.call("sound_normalize", %{"source" => trimmed})

      assert_in_delta peak, 0.891, 0.01

      # 4. Route it. The gated step, and the only one that changes what the
      #    machine does when nobody is watching.
      assert {:ok, applied} =
               Commands.call("sound_apply", %{
                 "source" => levelled,
                 "route" => "email",
                 "name" => "ramshackle-chime"
               })

      # The library file exists...
      assert applied.name == "ramshackle-chime.wav"
      assert File.regular?(Path.join([root, "sounds", "ramshackle-chime.wav"]))

      # ...and the route resolves to it, both as the routing table reports it
      # and as a fired notification would resolve it.
      assert Sound.resolved("email") == "ramshackle-chime.wav"

      assert Sound.for_notification(%{source: "email", kind: "alarm"}) ==
               "ramshackle-chime.wav"

      assert {:ok, routes} = Commands.call("sound_routes", %{})
      assert %{plays: "ramshackle-chime.wav", origin: "explicit"} = route(routes, "email")

      assert {:ok, listing} = Commands.call("sound_list", %{})
      assert %{layer: "workspace"} = entry(listing, "ramshackle-chime.wav")

      # And the way back is reachable by name too.
      assert {:ok, %{cleared_routes: ["email"]}} =
               Commands.call("sound_restore_defaults", %{"sounds" => false, "routes" => true})

      assert Sound.sound_map() == %{}
      assert {:ok, cleared} = Commands.call("sound_routes", %{})
      assert route(cleared, "email").assigned == nil
      refute route(cleared, "email").origin == "explicit"

      # Worth knowing, and not a bug: the clip still PLAYS for voicemail here,
      # because the legacy fallback picks the first audio file in the workspace
      # library alphabetically and this workspace has exactly one. Clearing a
      # route removes the assignment, not the file — sound_list is where you see
      # that, and deleting the file is the other half of an undo.
      assert route(cleared, "email").origin == "fallback"
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
                 %{"source" => "sentence.wav", "route" => "email"},
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
                 "route" => "email",
                 "name" => "spoken-chime"
               })

      assert applied.name == "spoken-chime.wav"
      assert applied.duration_ms > 0
      assert File.regular?(Path.join([root, "sounds", "spoken-chime.wav"]))

      # 5. And it resolves the way a fired notification would resolve it.
      assert Sound.resolved("email") == "spoken-chime.wav"
      assert Sound.for_notification(%{source: "email", kind: "alarm"}) == "spoken-chime.wav"
    end

    if @decoder_available do
      test "a foreign sample rate is converted on the way in", %{root: root} do
        # 48 kHz is not the internal format, so this is the decode path. Most
        # renderers emit 24 kHz or 48 kHz, and the caller must not have to know
        # that before handing a file over.
        File.write!(Path.join([root, "library", "hifi.wav"]), foreign_wav(48_000, 400))

        assert {:ok, %{name: "hifi.wav", internal: true, decoded: true}} =
                 Commands.call("sound_import", %{"path" => "hifi.wav"})

        assert {:ok, %{route: "email"}} =
                 Commands.call("sound_apply", %{
                   "source" => "hifi.wav",
                   "route" => "email",
                   "name" => "hifi-chime"
                 })

        assert Sound.resolved("email") == "hifi-chime.wav"
      end
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
      recording(root, "calls/take-1.wav")

      assert {:ok, %{layer: "library", event_id: nil}} =
               Commands.call("sound_probe", %{"path" => "calls/take-1.wav"})

      assert {:ok, %{name: "take-1.wav", replaced: false}} =
               Commands.call("sound_import", %{"path" => "calls/take-1.wav"})

      assert {:ok, %{name: "harbor.wav"}} =
               Commands.call("sound_import", %{
                 "path" => "calls/take-1.wav",
                 "name" => "harbor"
               })

      assert {:error, :traversal} =
               Commands.call("sound_import", %{"path" => "../../etc/passwd"})

      assert {:error, :absolute_path} = Commands.call("sound_probe", %{"path" => "/etc/passwd"})
    end

    test "errors survive dispatch unchanged", %{root: root} do
      source(root, "voicemail-03.wav")

      assert {:error, :not_found} = Commands.call("sound_probe", %{"name" => "nope.wav"})
      assert {:error, :invalid_name} = Commands.call("sound_probe", %{"name" => "../secrets.wav"})

      assert {:error, {:not_imported, "nope.wav"}} =
               Commands.call("sound_trim", %{"source" => "nope.wav", "end_ms" => 100})
    end

    test "the catalog advertises reads as safe and writers as restricted" do
      catalog = Map.new(Commands.list_commands(), &{&1.name, &1})

      reads = ~w(sound_list sound_routes sound_sources sound_probe)

      for name <- reads do
        entry = Map.fetch!(catalog, name)
        assert entry.type == :read, "#{name} should be a read"
        assert entry.tier == :safe, "#{name} should be safe"
        refute Map.get(entry, :gated, false), "#{name} should not be gated"
      end

      # The ones that write. Restricted, and deliberately NOT gated: they write
      # a new source or the shipped defaults back, and none of them routes
      # anything.
      for name <- ~w(
            sound_import
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
      # sound_probe takes one of three inputs, so none of them is required on
      # its own — the handler names the missing one instead.
      probe = Map.fetch!(catalog, "sound_probe")
      refute probe.args["name"].required
      assert Map.has_key?(probe.args, "path")
      refute Map.has_key?(probe.args, "event_id")
      refute probe.args["decode"].default

      # Same for the import verb.
      import_args = Map.fetch!(catalog, "sound_import").args
      refute import_args["path"].required
      refute import_args["overwrite"].default

      # The cut-up verbs left 09-19 with the engine. A stale entry would teach a
      # model a command that answers `unknown_command`.
      for gone <- ~w(
            sound_transcript_search sound_transcript_words sound_corpus
            sound_index_list sound_index_words sound_index_search
            sound_index_import sound_index_delete sound_align sound_find
            sound_sentence sound_assemble sound_gaps sound_record_save
            voice_bank_list voice_bank_create voice_bank_select voice_bank_delete
          ) do
        refute Map.has_key?(catalog, gone), "#{gone} was deleted and must not be catalogued"
        assert {:error, :unknown_command} = Commands.call(gone, %{})
      end
    end
  end
end
