defmodule BusterClaw.Voice.RendererTest do
  @moduledoc """
  Driven by a stub engine rather than a mock.

  VoxCPM cannot be installed on the dev machine (torch ships no macOS x86_64
  wheel past 2.2.2), so the alternative to a stub is testing nothing. The stub
  here is a real executable that the real `System.cmd/3` really spawns: it reads
  the argv this app built, honours `--output`, and writes a real WAV. Everything
  between `render/2` and a file on disk is therefore exercised for real —
  argv construction, the queue, the spawn, the atomic promote, the cache. The
  only fiction is the audio itself.
  """
  # async: false — points the workspace root at a tmp dir and drives a named
  # GenServer that is shared process-wide.
  use ExUnit.Case, async: false

  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Voice.Engine
  alias BusterClaw.Voice.Renderer

  setup do
    root = Path.join(System.tmp_dir!(), "bc_voice_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous_root = Application.get_env(:buster_claw, :workspace_root)
    previous_path = Application.get_env(:buster_claw, :voxcpm_path)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :voxcpm_device, "cpu")

    on_exit(fn ->
      put_or_delete(:workspace_root, previous_root)
      put_or_delete(:voxcpm_path, previous_path)
      Application.delete_env(:buster_claw, :voxcpm_device)
      File.rm_rf(root)
      Engine.refresh()
    end)

    Renderer.subscribe()
    {:ok, root: root}
  end

  describe "with a working engine" do
    setup %{root: root} do
      install_stub(root, :ok)
      :ok
    end

    test "a line is rendered to a real WAV in the workspace" do
      assert {:queued, key} = Renderer.render("Your timer is up.")
      assert_receive {:voice_render, ^key, {:ok, path}}, 5_000

      assert File.regular?(path)
      assert Path.extname(path) == ".wav"
      assert path =~ "sounds/voice"

      # A real WAV, not a placeholder: the app's own parser must accept it, since
      # `sound_import` will have to.
      assert {:ok, clip} = SoundStudio.read(path)
      assert SoundStudio.duration_ms(clip) > 0
    end

    test "the same ask is a cache hit that never reaches the queue" do
      assert {:queued, key} = Renderer.render("Alarm.")
      assert_receive {:voice_render, ^key, {:ok, path}}, 5_000

      # Second time: synchronous, same file, and nothing is broadcast because
      # nothing was rendered.
      assert {:ok, ^path} = Renderer.render("Alarm.")
      refute_receive {:voice_render, _, _}, 200
    end

    test "a different voice is a different sound, and so a different file" do
      assert {:queued, a} = Renderer.render("Alarm.", control: "warm and low")
      assert_receive {:voice_render, ^a, {:ok, first}}, 5_000

      assert {:queued, b} = Renderer.render("Alarm.", control: "bright and quick")
      assert_receive {:voice_render, ^b, {:ok, second}}, 5_000

      refute a == b
      refute first == second
    end

    test "asking twice while it is being made is one render" do
      assert {:queued, key} = Renderer.render("The shift is over.")
      assert {:queued, ^key} = Renderer.render("The shift is over.")

      assert_receive {:voice_render, ^key, {:ok, _path}}, 5_000
      refute_receive {:voice_render, ^key, _}, 200
    end

    test "path_for/2 answers where a line will land without asking the server" do
      assert {:ok, predicted} = Renderer.path_for("Mail arrived.")
      refute File.exists?(predicted)

      assert {:queued, key} = Renderer.render("Mail arrived.")
      assert_receive {:voice_render, ^key, {:ok, actual}}, 5_000
      assert actual == predicted
    end

    test "empty text is refused before anything spawns" do
      assert {:error, :empty_text} = Renderer.render("   ")
    end

    test "a clone with a reference that is not there is refused, not attempted" do
      assert {:error, :reference_missing} =
               Renderer.render("hello", reference_audio: "/nonexistent/ref.wav")
    end
  end

  describe "when the engine fails" do
    test "a non-zero exit is reported and nothing is cached", %{root: root} do
      install_stub(root, :fail)

      assert {:queued, key} = Renderer.render("Something needs you.")
      assert_receive {:voice_render, ^key, {:error, {:exit, 2, _output}}}, 5_000

      assert {:ok, path} = Renderer.path_for("Something needs you.")
      refute File.exists?(path), "a failed render must not leave a cache entry"
    end

    test "a render that writes nothing is a failure, not an empty cache hit", %{root: root} do
      # The dangerous shape: exit 0 with no output file, or a truncated one. If
      # that were promoted, every later call would be a cache hit on silence and
      # a chime would fire with nothing audible.
      install_stub(root, :empty)

      assert {:queued, key} = Renderer.render("Alarm.")
      assert_receive {:voice_render, ^key, {:error, _reason}}, 5_000

      assert {:ok, path} = Renderer.path_for("Alarm.")
      refute File.exists?(path)
    end
  end

  test "with no engine at all, rendering is refused rather than queued" do
    Application.put_env(:buster_claw, :voxcpm_path, "/nonexistent/voxcpm")
    Engine.refresh()

    assert {:error, :engine_unavailable} = Renderer.render("Alarm.")
  end

  # ---------------------------------------------------------------------------

  # A stub that behaves like the real CLI's contract: read --output, write there.
  defp install_stub(root, behaviour) do
    fixture = Path.join(root, "fixture.wav")
    File.write!(fixture, wav_bytes())

    path = Path.join(root, "voxcpm-stub")

    body =
      case behaviour do
        :ok ->
          ~s|out=""\nwhile [ $# -gt 0 ]; do\n  if [ "$1" = "--output" ]; then out="$2"; fi\n  shift\ndone\ncp "#{fixture}" "$out"\nexit 0\n|

        :fail ->
          ~s|echo "voxcpm: CUDA out of memory" >&2\nexit 2\n|

        :empty ->
          ~s|exit 0\n|
      end

    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)

    Application.put_env(:buster_claw, :voxcpm_path, path)
    Engine.refresh()
    path
  end

  # 100 ms of quiet PCM16 mono at 22.05 kHz, with a real RIFF header — the format
  # the studio calls internal, so the app's own reader accepts it.
  defp wav_bytes do
    rate = 22_050
    samples = div(rate, 10)
    data = :binary.copy(<<0::little-signed-16>>, samples)
    len = byte_size(data)

    <<"RIFF", 36 + len::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data", len::little-32>> <>
      data
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:buster_claw, key)
  defp put_or_delete(key, value), do: Application.put_env(:buster_claw, key, value)
end
