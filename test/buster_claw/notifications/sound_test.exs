defmodule BusterClaw.Notifications.SoundTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Notifications.Sound

  setup do
    root = Path.join(System.tmp_dir!(), "bc_sound_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sounds"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp sound(root, name), do: Path.join([root, "sounds", name])

  test "is nil / unavailable when the folder has no audio" do
    refute Sound.available?()
    assert Sound.path() == nil
  end

  test "prefers notify.<ext> over other audio", %{root: root} do
    File.write!(sound(root, "aaa.mp3"), "x")
    File.write!(sound(root, "notify.wav"), "x")

    assert Sound.path() == sound(root, "notify.wav")
    assert Sound.available?()
    assert Sound.content_type(Sound.path()) == "audio/wav"
  end

  test "falls back to the first audio file alphabetically", %{root: root} do
    File.write!(sound(root, "bbb.ogg"), "x")
    File.write!(sound(root, "aaa.mp3"), "x")

    assert Sound.path() == sound(root, "aaa.mp3")
    assert Sound.content_type(Sound.path()) == "audio/mpeg"
  end

  test "ignores non-audio files" do
    File.write!(Path.join([Sound.dir(), "notes.txt"]), "x")
    assert Sound.path() == nil
  end

  test "ensure creates the folder and a README" do
    File.rm_rf!(Sound.dir())
    assert Sound.ensure() == :ok
    assert File.dir?(Sound.dir())
    assert File.exists?(Path.join(Sound.dir(), "README.md"))
  end
end
