defmodule BusterClaw.Voice.EngineTest do
  # async: false — the probe cache is a :persistent_term, which is global, and
  # resolution is steered by application env.
  use ExUnit.Case, async: false

  alias BusterClaw.Voice.Engine

  setup do
    previous = Application.get_env(:buster_claw, :voxcpm_path)
    previous_device = Application.get_env(:buster_claw, :voxcpm_device)
    Engine.refresh()

    on_exit(fn ->
      restore(:voxcpm_path, previous)
      restore(:voxcpm_device, previous_device)
      Engine.refresh()
    end)

    {:ok, tmp: tmp_dir()}
  end

  describe "resolution and probing" do
    test "an engine nobody has installed is absent, with a reason and a way out" do
      Application.put_env(:buster_claw, :voxcpm_path, "/nonexistent/voxcpm")

      probe = Engine.refresh()

      refute probe.available?
      assert probe.reason == :not_installed
      refute Engine.available?()

      # The absence has to be actionable — this is the only string an operator
      # without an engine ever sees.
      assert Engine.install_hint() =~ "voxcpm"
      assert Engine.install_hint() =~ "~/.buster-claw/voxcpm"
    end

    test "a real executable is found and reported available", %{tmp: tmp} do
      path = stub_binary(tmp, "voxcpm", 0)
      Application.put_env(:buster_claw, :voxcpm_path, path)

      probe = Engine.refresh()

      assert probe.available?
      assert probe.path == path
      assert probe.reason == nil
    end

    test "a file that exists but cannot be run is its own answer, not 'missing'", %{tmp: tmp} do
      # Worth distinguishing: a half-finished install deserves a different
      # sentence from no install, and both are things people actually hit.
      path = Path.join(tmp, "voxcpm-noexec")
      File.write!(path, "#!/bin/sh\n")
      File.chmod!(path, 0o644)
      Application.put_env(:buster_claw, :voxcpm_path, path)

      probe = Engine.refresh()

      refute probe.available?
      assert probe.reason == :not_executable
      assert probe.path == path
    end

    test "the probe is cached, and refresh/0 is what re-reads the disk", %{tmp: tmp} do
      path = stub_binary(tmp, "voxcpm", 0)
      Application.put_env(:buster_claw, :voxcpm_path, path)
      assert Engine.refresh().available?

      # Delete it underneath. The cache must not notice — that is the point of a
      # TTL, and the reason an explicit re-check exists at all.
      File.rm!(path)
      assert Engine.probe().available?

      refute Engine.refresh().available?
    end
  end

  describe "command construction" do
    # These flags were read out of voxcpm 2.0.3's own cli.py rather than from
    # docs. If a future version moves them, these are the tests that say so.
    setup do
      Application.put_env(:buster_claw, :voxcpm_device, "cpu")
      :ok
    end

    test "design names a device and refuses the network by default" do
      args = Engine.design_args("hello", "/tmp/out.wav")

      assert args == [
               "design",
               "--text",
               "hello",
               "--output",
               "/tmp/out.wav",
               "--device",
               "cpu",
               "--local-files-only"
             ]
    end

    test "a voice description rides as --control" do
      args = Engine.design_args("hello", "/tmp/out.wav", control: "warm, low")

      assert [
               "design",
               "--text",
               "hello",
               "--output",
               "/tmp/out.wav",
               "--control",
               "warm, low" | _
             ] = args
    end

    test "clone carries the reference audio, and the prompt pair when given" do
      args =
        Engine.clone_args("hello", "/tmp/out.wav", "/tmp/ref.wav",
          prompt_audio: "/tmp/p.wav",
          prompt_text: "a transcript"
        )

      assert "clone" == hd(args)
      assert_pair(args, "--reference-audio", "/tmp/ref.wav")
      assert_pair(args, "--prompt-audio", "/tmp/p.wav")
      assert_pair(args, "--prompt-text", "a transcript")
    end

    test "batch takes a file of lines and a directory — one model load for the set" do
      args = Engine.batch_args("/tmp/lines.txt", "/tmp/outs", reference_audio: "/tmp/ref.wav")

      assert "batch" == hd(args)
      assert_pair(args, "--input", "/tmp/lines.txt")
      assert_pair(args, "--output-dir", "/tmp/outs")
      assert_pair(args, "--reference-audio", "/tmp/ref.wav")
    end

    test "store_true switches appear alone or not at all, never as --flag false" do
      # argparse would read a trailing "false" as a positional argument, so a
      # switch built the obvious way silently changes what is being asked for.
      on = Engine.design_args("x", "/tmp/o.wav", normalize: true, no_denoiser: true)
      assert "--normalize" in on
      assert "--no-denoiser" in on

      off = Engine.design_args("x", "/tmp/o.wav", normalize: false, no_denoiser: nil)
      refute "--normalize" in off
      refute "--no-denoiser" in off
      refute "false" in off
    end

    test "the network can be re-enabled explicitly, for the first weight pull" do
      args = Engine.design_args("x", "/tmp/o.wav", local_files_only: false)
      refute "--local-files-only" in args
    end

    test "a caller may override the device per command" do
      assert_pair(Engine.design_args("x", "/tmp/o.wav", device: "mps"), "--device", "mps")
    end

    test "no command ever passes --version or --seed, which voxcpm 2.0.3 does not have" do
      # The roadmap's sketch specified both. Reading the wheel's parser showed
      # neither exists: --version would make a working install look broken, and
      # --seed would be rejected outright.
      all =
        Engine.design_args("x", "/tmp/o.wav", normalize: true) ++
          Engine.clone_args("x", "/tmp/o.wav", "/tmp/r.wav") ++
          Engine.batch_args("/tmp/in.txt", "/tmp/out")

      refute "--version" in all
      refute "--seed" in all
    end
  end

  test "device is explicit, never argparse's silent auto" do
    Application.delete_env(:buster_claw, :voxcpm_device)
    assert Engine.device() in ["cpu", "mps"]

    Application.put_env(:buster_claw, :voxcpm_device, "cuda:1")
    assert Engine.device() == "cuda:1"
    assert_pair(Engine.design_args("x", "/tmp/o.wav"), "--device", "cuda:1")
  end

  defp assert_pair(args, flag, value) do
    index = Enum.find_index(args, &(&1 == flag))
    assert index, "expected #{flag} in #{inspect(args)}"
    assert Enum.at(args, index + 1) == value
  end

  defp stub_binary(dir, name, exit_code) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\nexit #{exit_code}\n")
    File.chmod!(path, 0o755)
    path
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "bc_voice_engine_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp restore(key, nil), do: Application.delete_env(:buster_claw, key)
  defp restore(key, value), do: Application.put_env(:buster_claw, key, value)
end
