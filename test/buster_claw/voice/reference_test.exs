defmodule BusterClaw.Voice.ReferenceTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Voice.{Config, Reference}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_ref_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:buster_claw, :workspace_root, previous),
        else: Application.delete_env(:buster_claw, :workspace_root)

      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "a take becomes a WAV in the workspace AND the reference clip, in one save", %{root: root} do
    assert {:ok, saved} = Reference.save(tone(3_000), 44_100)

    assert saved.path =~ Path.join(root, "sounds/voice/reference")
    assert File.regular?(saved.path)
    assert_in_delta saved.duration_ms, 3_000, 5
    assert saved.sample_rate == 44_100
    refute saved.clipped?

    # This is the "learning": there is no training step, the file IS the model's
    # instruction. From here every render is a clone.
    assert Config.get().reference_audio == saved.path
    assert Config.cloning?()

    # And the app's own reader accepts what was written, at the device's rate.
    assert {:ok, clip} = BusterClaw.Notifications.SoundStudio.read(saved.path)
    assert clip.sample_rate == 44_100
  end

  test "a take that is too short to clone from is refused, and nothing changes" do
    assert {:error, :too_short} = Reference.save(tone(800), 44_100)
    refute Config.cloning?()
    assert Reference.list() == []
  end

  test "silence is refused — a muted input must not become the voice" do
    zeros = :binary.copy(<<0::float-little-32>>, 44_100 * 3)
    assert {:error, :silent_take} = Reference.save(Base.encode64(zeros), 44_100)
    refute Config.cloning?()
  end

  test "recordings list newest first, mark the one in use, and can be switched" do
    {:ok, first} = Reference.save(tone(2_500), 44_100)
    Process.sleep(1_100)
    {:ok, second} = Reference.save(tone(2_500), 44_100)

    [newest, older] = Reference.list()
    assert newest.name == second.name and newest.current?
    assert older.name == first.name and not older.current?

    assert :ok = Reference.use(first.name)
    assert Config.get().reference_audio == first.path
    assert [%{current?: false}, %{current?: true}] = Reference.list()
  end

  test "deleting the clip in use clears it, so renders fall back rather than clone a missing file" do
    {:ok, saved} = Reference.save(tone(2_500), 44_100)
    assert Config.cloning?()

    assert :ok = Reference.delete(saved.name)

    refute File.exists?(saved.path)
    refute Config.cloning?()
  end

  test "resolve is an allowlist over the directory, never a path join" do
    {:ok, saved} = Reference.save(tone(2_500), 44_100)

    assert Reference.resolve(saved.name) == saved.path
    assert Reference.resolve("../../etc/passwd") == nil
    assert Reference.resolve("nope.wav") == nil
    assert {:error, :not_found} = Reference.use("nope.wav")
  end

  # `ms` of a quiet 440 Hz tone as the recorder sends it: base64 Float32 LE.
  defp tone(ms, rate \\ 44_100) do
    count = div(rate * ms, 1000)

    floats =
      for i <- 0..(count - 1), into: <<>> do
        <<:math.sin(2 * :math.pi() * 440 * i / rate) * 0.3::float-little-32>>
      end

    Base.encode64(floats)
  end

  describe "duration_seconds/1 — the number every render quote is built on" do
    @tag :tmp_dir
    test "reads the length from the header, matching the file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "two-seconds.wav")
      rate = 16_000
      samples = for _ <- 1..(rate * 2), into: <<>>, do: <<0::little-signed-16>>
      File.write!(path, wav(samples, rate))

      assert_in_delta Reference.duration_seconds(path), 2.0, 0.01
    end

    test "anything unreadable is 0.0, which reads downstream as no reference" do
      assert Reference.duration_seconds(nil) == 0.0
      assert Reference.duration_seconds("/nope/missing.wav") == 0.0
    end

    @tag :tmp_dir
    test "a file that is not a WAV is 0.0 rather than a crash", %{tmp_dir: tmp} do
      path = Path.join(tmp, "not-audio.wav")
      File.write!(path, "this is not a RIFF file at all")

      assert Reference.duration_seconds(path) == 0.0
    end

    @tag :tmp_dir
    test "a truncated file reports what is really there, not what the header claims",
         %{tmp_dir: tmp} do
      path = Path.join(tmp, "truncated.wav")
      rate = 16_000
      full = for _ <- 1..(rate * 4), into: <<>>, do: <<0::little-signed-16>>
      <<head::binary-size(44), body::binary>> = wav(full, rate)
      half = binary_part(body, 0, div(byte_size(body), 2))
      File.write!(path, head <> half)

      assert_in_delta Reference.duration_seconds(path), 2.0, 0.01
    end
  end

  defp wav(pcm, rate) do
    byte_rate = rate * 2

    <<"RIFF", 36 + byte_size(pcm)::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
      1::little-16, rate::little-32, byte_rate::little-32, 2::little-16, 16::little-16, "data",
      byte_size(pcm)::little-32, pcm::binary>>
  end
end
