defmodule BusterClaw.Notifications.CaptureTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Notifications.Capture
  alias BusterClaw.Notifications.SoundStudio

  # Every recording test drives an injected runner: the microphone cannot be
  # relied on in a test, because missing consent is the entire problem this
  # module exists to catch. Only the two binary-presence assertions look at the
  # machine, and they define themselves out rather than failing on it.
  @recorder_available Capture.recorder_available?()

  # The workspace is redirected per-test so a capture lands in a temp folder and
  # never in the operator's real `sounds/studio/`. Same shape as
  # StudioMixTest/SoundTest, and `async: false` for the same reason: this
  # mutates application env.
  setup do
    root = Path.join(System.tmp_dir!(), "bc_capture_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  # A WAV in the studio's internal format, from a list of int16 samples. Written
  # with `SoundStudio.render/1` so the test exercises the same encoder the app
  # ships — no second WAV writer here either.
  defp wav(samples) do
    %SoundStudio{data: for(s <- samples, into: <<>>, do: <<s::little-signed-16>>)}
    |> SoundStudio.render()
  end

  defp silent_wav(n), do: wav(List.duplicate(0, n))

  # A 220 Hz-ish tone at about -6 dBFS. "Real signal" for these purposes only
  # needs to be well clear of the silence floor.
  defp tone_wav(n) do
    wav(for i <- 0..(n - 1), do: round(16_000 * :math.sin(i * 0.0627)))
  end

  # A stand-in for `System.cmd/3`: writes `binary` to the output path (the last
  # arg, exactly where `record/1` puts it) and reports `status`.
  defp fake_ffmpeg(binary, status \\ 0) do
    fn _exe, args ->
      File.write!(List.last(args), binary)
      {"", status}
    end
  end

  describe "the silence check — the reason this module exists" do
    test "a capture of digital silence is REFUSED, and the error names the TCC fix" do
      assert {:error, {:silent_capture, message}} =
               Capture.record(seconds: 1, runner: fake_ffmpeg(silent_wav(22_050)))

      # The failure mode is a zero exit status and a well-formed file, so the
      # only thing standing between the operator and a folder of nothing is
      # this check.
      assert message =~ "Privacy & Security"
      assert message =~ "Microphone"
      assert message =~ "no audio"

      # And nothing was stored: a silent take must not leave a file behind.
      assert SoundStudio.list() == []
    end

    test "a capture with real signal is accepted and stored" do
      assert {:ok, result} = Capture.record(seconds: 1, runner: fake_ffmpeg(tone_wav(22_050)))

      assert result.peak > Capture.silence_floor()
      assert File.regular?(result.path)
      assert result.name in SoundStudio.list()
    end

    test "silent?/1 is a NEAR-zero test, not an exact-zero test" do
      # True digital silence — the measured TCC failure.
      assert Capture.silent?(clip([0, 0, 0]))

      # A device that is open but delivering nothing can dither out a few
      # least-significant bits. That is not audio either.
      assert Capture.silent?(clip([1, -1, 2]))

      # Ten int16 steps is the line; a real capture clears it by orders of
      # magnitude.
      refute Capture.silent?(clip([0, 0, 4000]))
      assert Capture.silence_floor() > 0.0
      assert Capture.silence_floor() < 0.001
    end

    test "a barely-above-floor capture passes, so the floor is not a loudness gate" do
      # ~-66 dBFS: quiet enough that no one wants it, loud enough that it is
      # unambiguously the microphone rather than a dead device.
      assert {:ok, result} = Capture.record(seconds: 1, runner: fake_ffmpeg(wav([20, -20, 15])))
      assert result.peak < 0.001
    end
  end

  describe "the file it lands, and the header it verifies" do
    test "the result describes the real header, read back off disk" do
      assert {:ok, result} = Capture.record(seconds: 2, runner: fake_ffmpeg(tone_wav(44_100)))

      assert {result.sample_rate, result.channels, result.bits} ==
               SoundStudio.internal_format()

      # 44_100 samples at 22_050 Hz is two seconds.
      assert result.duration_ms == 2000
      assert is_integer(result.duration_ms)
      refute result.clipped
    end

    test "a header that is not the internal format is refused, not silently accepted" do
      wrong =
        SoundStudio.render(%SoundStudio{sample_rate: 48_000, data: <<1000::little-signed-16>>})

      assert {:error, {:unexpected_format, {48_000, 1, 16}}} =
               Capture.record(seconds: 1, runner: fake_ffmpeg(wrong))
    end

    test "it lands in the Studio's sources — sounds/studio/, never sounds/" do
      assert {:ok, result} = Capture.record(seconds: 1, runner: fake_ffmpeg(tone_wav(2205)))

      assert Path.dirname(result.path) == SoundStudio.dir()
      assert Path.basename(Path.dirname(result.path)) == "studio"
      # Recording never routes a chime: nothing appears in the effects library.
      refute File.exists?(Path.join(BusterClaw.Notifications.Sound.dir(), result.name))
    end

    test "the default name is a timestamped .wav" do
      assert {:ok, result} = Capture.record(seconds: 1, runner: fake_ffmpeg(tone_wav(2205)))
      assert result.name =~ ~r/^recording-\d{8}-\d{6}\.wav$/
    end

    test "a name collision DE-DUPLICATES — a recording is unrepeatable, never clobbered" do
      runner = fake_ffmpeg(tone_wav(2205))

      assert {:ok, first} = Capture.record(seconds: 1, name: "room-tone", runner: runner)
      assert first.name == "room-tone.wav"
      before = File.read!(first.path)

      assert {:ok, second} = Capture.record(seconds: 1, name: "room-tone", runner: runner)
      assert second.name == "room-tone-2.wav"

      assert File.read!(first.path) == before, "the first take was overwritten"
      assert Enum.sort(SoundStudio.list()) == ["room-tone-2.wav", "room-tone.wav"]
    end
  end

  describe "refusals that never reach a subprocess" do
    test ":seconds is required and bounded — an unbounded record hangs the BEAM" do
      exploding = fn _exe, _args -> flunk("ffmpeg must not run for an invalid duration") end

      assert {:error, :duration_required} = Capture.record(runner: exploding)
      assert {:error, :invalid_duration} = Capture.record(seconds: 0, runner: exploding)
      assert {:error, :invalid_duration} = Capture.record(seconds: -5, runner: exploding)
      assert {:error, :invalid_duration} = Capture.record(seconds: :infinity, runner: exploding)
      assert {:error, :invalid_duration} = Capture.record(seconds: "30", runner: exploding)

      assert {:error, :duration_too_long} =
               Capture.record(seconds: Capture.max_seconds() + 1, runner: exploding)

      assert Capture.max_seconds() == 300
    end

    test "a bad device is refused before ffmpeg is spawned" do
      exploding = fn _exe, _args -> flunk("ffmpeg must not run for an invalid device") end

      assert {:error, :invalid_device} = Capture.record(seconds: 1, device: "", runner: exploding)
      assert {:error, :invalid_device} = Capture.record(seconds: 1, device: -1, runner: exploding)

      assert {:error, :invalid_device} =
               Capture.record(seconds: 1, device: %{}, runner: exploding)
    end

    test "record/1 with something that is not options returns an error, never raises" do
      assert {:error, :invalid_options} = Capture.record(:now)
    end
  end

  describe "the subprocess going wrong" do
    test "a binary that is not there is an error, not a raise" do
      # `System.cmd/2` raises `ErlangError` (:enoent) for a path that does not
      # exist — the case where ffmpeg is uninstalled between the check and the
      # call. The module has to answer with `{:error, _}` regardless.
      missing = fn _exe, _args -> System.cmd("/nonexistent/bin/ffmpeg", []) end

      assert {:error, :no_recorder} = Capture.record(seconds: 1, runner: missing)
    end

    unless @recorder_available do
      test "with no ffmpeg installed at all, record/1 says so" do
        assert {:error, :no_recorder} = Capture.record(seconds: 1)
      end
    end

    test "a non-zero exit carries the status and stores nothing" do
      failing = fn _exe, _args -> {"Error opening input file :9.", 251} end

      assert {:error, {:capture_failed, 251}} = Capture.record(seconds: 1, runner: failing)
      assert SoundStudio.list() == []
    end

    test "exit 0 with nothing parseable on disk is :unreadable_capture" do
      liar = fn _exe, _args -> {"", 0} end
      assert {:error, :unreadable_capture} = Capture.record(seconds: 1, runner: liar)

      prose = fake_ffmpeg("this is not a wav")
      assert {:error, :unreadable_capture} = Capture.record(seconds: 1, runner: prose)
    end

    test "a wedged recorder times out instead of hanging the caller" do
      # A device that never delivers a first frame never reaches ffmpeg's own
      # `-t`, so the BEAM-side deadline is the only thing that ends the wait.
      wedged = fn _exe, _args ->
        Process.sleep(2000)
        {"", 0}
      end

      assert {:error, :timeout} =
               Capture.record(seconds: 0.05, grace_ms: 0, runner: wedged)

      assert SoundStudio.list() == []
    end

    test "a runner that is not a 2-arity function is refused" do
      assert {:error, :invalid_runner} = Capture.record(seconds: 1, runner: :nope)
    end

    test "the temp file is cleaned up even when the capture is rejected" do
      before = tmp_captures()

      assert {:error, {:silent_capture, _}} =
               Capture.record(seconds: 1, runner: fake_ffmpeg(silent_wav(2205)))

      assert tmp_captures() == before
    end
  end

  describe "the recorder binary" do
    test "recorder_available?/0 agrees with recorder_path/0" do
      assert Capture.recorder_available?() == is_binary(Capture.recorder_path())
    end

    test "the path, when present, is an executable file" do
      case Capture.recorder_path() do
        nil -> assert true
        path -> assert File.regular?(path)
      end
    end
  end

  defp clip(samples) do
    %SoundStudio{data: for(s <- samples, into: <<>>, do: <<s::little-signed-16>>)}
  end

  defp tmp_captures do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "bccapture-"))
    |> Enum.sort()
  end
end
