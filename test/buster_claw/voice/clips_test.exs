defmodule BusterClaw.Voice.ClipsTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Voice.{Clips, Engine, Renderer}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_clips_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_root = Application.get_env(:buster_claw, :workspace_root)
    previous_path = Application.get_env(:buster_claw, :voxcpm_path)
    previous_device = Application.get_env(:buster_claw, :voxcpm_device)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :voxcpm_device, "cpu")

    on_exit(fn ->
      restore(:workspace_root, previous_root)
      restore(:voxcpm_path, previous_path)
      restore(:voxcpm_device, previous_device)
      Engine.refresh()
      File.rm_rf(root)
    end)

    Renderer.subscribe()
    {:ok, root: root}
  end

  test "a typed line is rendered and remembered, newest first", %{root: root} do
    stub(root)

    assert {:queued, key} = Clips.make("Hello from the kitchen.")
    assert_receive {:voice_render, ^key, {:ok, path}}, 5_000
    Clips.record("Hello from the kitchen.", path)

    assert [%{text: "Hello from the kitchen.", path: ^path, name: name}] = Clips.list()
    assert name == Path.basename(path)

    # A second line goes on top; the same line again is one row, not two.
    assert {:queued, key2} = Clips.make("And again.")
    assert_receive {:voice_render, ^key2, {:ok, path2}}, 5_000
    Clips.record("And again.", path2)
    Clips.record("Hello from the kitchen.", path)

    assert ["Hello from the kitchen.", "And again."] = Enum.map(Clips.list(), & &1.text)
  end

  test "a line already in the cache is recorded immediately, no queue", %{root: root} do
    stub(root)
    assert {:queued, key} = Clips.make("Cached line.")
    assert_receive {:voice_render, ^key, {:ok, path}}, 5_000

    # Not recorded yet — the caller does that when the render lands. Second ask
    # is a cache hit, and make/2 records it itself.
    assert {:ok, ^path} = Clips.make("Cached line.")
    assert [%{text: "Cached line."}] = Clips.list()
  end

  test "a clip whose audio vanished is dropped from the listing rather than shown dead", %{
    root: root
  } do
    stub(root)
    assert {:queued, key} = Clips.make("Gone soon.")
    assert_receive {:voice_render, ^key, {:ok, path}}, 5_000
    Clips.record("Gone soon.", path)
    assert [_] = Clips.list()

    File.rm!(path)
    assert [] = Clips.list()
  end

  test "forgetting drops the row and leaves the cache file — it may be a chime's", %{root: root} do
    stub(root)
    assert {:queued, key} = Clips.make("Your timer is up.")
    assert_receive {:voice_render, ^key, {:ok, path}}, 5_000
    Clips.record("Your timer is up.", path)

    assert :ok = Clips.forget(path)
    assert [] = Clips.list()

    assert File.regular?(path),
           "the cache owns the file; forgetting a clip must not delete a chime"
  end

  test "resolve is an allowlist over the manifest", %{root: root} do
    stub(root)
    assert {:queued, key} = Clips.make("Findable.")
    assert_receive {:voice_render, ^key, {:ok, path}}, 5_000
    Clips.record("Findable.", path)

    assert Clips.resolve(Path.basename(path)) == path
    assert Clips.resolve("../etc/passwd") == nil
    assert Clips.resolve("deadbeef.wav") == nil
  end

  test "empty text and a missing engine are refused before anything is written" do
    Application.put_env(:buster_claw, :voxcpm_path, "/nonexistent/voxcpm")
    Engine.refresh()

    assert {:error, :empty_text} = Clips.make("   ")
    assert {:error, :engine_unavailable} = Clips.make("hello")
    assert Clips.list() == []
  end

  defp stub(root) do
    fixture = Path.join(root, "fixture.wav")
    File.write!(fixture, wav())
    path = Path.join(root, "voxcpm-stub")

    File.write!(
      path,
      "#!/bin/sh\nout=\"\"\nwhile [ $# -gt 0 ]; do\n  if [ \"$1\" = \"--output\" ]; then out=\"$2\"; fi\n  shift\ndone\ncp \"#{fixture}\" \"$out\"\nexit 0\n"
    )

    File.chmod!(path, 0o755)
    Application.put_env(:buster_claw, :voxcpm_path, path)
    Engine.refresh()
  end

  defp wav do
    rate = 22_050
    data = :binary.copy(<<0::little-signed-16>>, div(rate, 10))
    len = byte_size(data)

    <<"RIFF", 36 + len::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data", len::little-32>> <>
      data
  end

  defp restore(key, nil), do: Application.delete_env(:buster_claw, key)
  defp restore(key, value), do: Application.put_env(:buster_claw, key, value)

  describe "install/1 — the bridge to Settings → Notify" do
    test "a clip becomes a library sound, named from its text", %{root: root} do
      stub(root)
      {:queued, key} = Clips.make("Stand up and stretch.")
      assert_receive {:voice_render, ^key, {:ok, path}}, 5_000
      Clips.record("Stand up and stretch.", path)

      assert {:ok, "clip-stand-up-and-stretch.wav"} = Clips.install(path)

      # The whole point: Notify's routing menu is `Sound.list/0`, and a clip in
      # `sounds/voice/` is invisible to it until it is copied up. This assertion
      # is the one that says the feature works, because Notify itself was not
      # changed at all to offer these.
      assert "clip-stand-up-and-stretch.wav" in Sound.list()
    end

    test "installing twice suffixes rather than overwriting", %{root: root} do
      stub(root)
      {:queued, key} = Clips.make("Take a break.")
      assert_receive {:voice_render, ^key, {:ok, path}}, 5_000
      Clips.record("Take a break.", path)

      assert {:ok, "clip-take-a-break.wav"} = Clips.install(path)
      assert {:ok, "clip-take-a-break-1.wav"} = Clips.install(path)

      # The library holds the operator's own uploads too. Silently replacing one
      # of those is the worst available reading of "install".
      assert "clip-take-a-break.wav" in Sound.list()
      assert "clip-take-a-break-1.wav" in Sound.list()
    end

    test "installing does not route it anywhere", %{root: root} do
      stub(root)
      {:queued, key} = Clips.make("Nothing routes this.")
      assert_receive {:voice_render, ^key, {:ok, path}}, 5_000
      Clips.record("Nothing routes this.", path)

      before = Sound.sound_map()
      {:ok, name} = Clips.install(path)

      # Available is not the same as chosen. `Chimes.install/2` DOES assign,
      # because a chime is a routing key's line; a clip is a sound you might
      # route anywhere or nowhere, and that decision stays in Notify.
      assert Sound.sound_map() == before
      refute name in Map.values(Sound.sound_map())
    end

    # Asserted on `sound_map/0` — the stored ASSIGNMENTS — and not on
    # `resolved/1`, because the two answer different questions and only the first
    # one is this function's business.
    #
    # `resolved/1` falls through to `Sound.path/0` for any key with no explicit
    # assignment, and that is `named_notify() || first_audio()` — **the first
    # audio file in the library, alphabetically**. So adding ANY file can change
    # what unassigned alerts play, and `clip-` sorts ahead of most things. That
    # is pre-existing behaviour of the library, not something installing a clip
    # does, but it is real and this test says so out loud rather than asserting
    # something comfortable and false.
    test "a clip can change what UNASSIGNED keys fall back to — by sort order", %{root: root} do
      stub(root)
      {:queued, key} = Clips.make("Aaa first alphabetically.")
      assert_receive {:voice_render, ^key, {:ok, path}}, 5_000
      Clips.record("Aaa first alphabetically.", path)

      {:ok, name} = Clips.install(path)

      assert Sound.resolved("default") == name,
             "with nothing assigned, the library's first file IS the fallback"
    end

    test "a path that is not a clip is refused" do
      assert {:error, :not_found} = Clips.install("/nope/not-a-clip.wav")
    end
  end
end
