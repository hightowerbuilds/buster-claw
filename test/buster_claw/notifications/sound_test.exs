defmodule BusterClaw.Notifications.SoundTest do
  use BusterClaw.DataCase, async: false

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

  describe "library" do
    test "list returns sorted audio basenames only", %{root: root} do
      File.write!(sound(root, "bongos.wav"), "x")
      File.write!(sound(root, "wilhelm.wav"), "x")
      File.write!(sound(root, "README.md"), "x")

      assert Sound.list() == ["bongos.wav", "wilhelm.wav"]
    end

    test "path_for resolves only real library entries", %{root: root} do
      File.write!(sound(root, "bongos.wav"), "x")

      assert Sound.path_for("bongos.wav") == sound(root, "bongos.wav")
      assert Sound.path_for("nope.wav") == nil
      assert Sound.path_for("../../etc/passwd") == nil
      assert Sound.path_for(nil) == nil
    end

    test "delete removes the file and any routings to it", %{root: root} do
      File.write!(sound(root, "bongos.wav"), "x")
      File.write!(sound(root, "wilhelm.wav"), "x")
      assert Sound.assign("voicemail", "wilhelm.wav") == :ok

      assert Sound.delete("wilhelm.wav") == :ok
      refute File.exists?(sound(root, "wilhelm.wav"))
      assert Sound.sound_map() == %{}
      assert Sound.delete("wilhelm.wav") == {:error, :not_found}
    end
  end

  describe "per-event routing" do
    setup %{root: root} do
      File.write!(sound(root, "bongos.wav"), "x")
      File.write!(sound(root, "notify.wav"), "x")
      File.write!(sound(root, "wilhelm.wav"), "x")
      :ok
    end

    defp fired(kind, source), do: %{kind: kind, source: source}

    test "assign validates key and sound" do
      assert Sound.assign("voicemail", "wilhelm.wav") == :ok
      assert Sound.assign("voicemail", "missing.wav") == {:error, :unknown_sound}
      assert Sound.assign("not-a-key", "wilhelm.wav") == {:error, :unknown_key}
      assert Sound.sound_map() == %{"voicemail" => "wilhelm.wav"}
    end

    test "assigning nil or empty clears the entry" do
      assert Sound.assign("alarm", "bongos.wav") == :ok
      assert Sound.assign("alarm", "") == :ok
      assert Sound.sound_map() == %{}
    end

    test "for_notification walks source, then kind, then default, then fallback" do
      # Nothing routed: the legacy notify.<ext> resolution is the floor.
      assert Sound.for_notification(fired("timer", "chat")) == "notify.wav"

      assert Sound.assign("default", "bongos.wav") == :ok
      assert Sound.for_notification(fired("timer", "chat")) == "bongos.wav"

      assert Sound.assign("timer", "notify.wav") == :ok
      assert Sound.for_notification(fired("timer", "chat")) == "notify.wav"

      # Source outranks kind.
      assert Sound.assign("chat", "wilhelm.wav") == :ok
      assert Sound.for_notification(fired("timer", "chat")) == "wilhelm.wav"
    end

    test "routings to a vanished file are ignored on read", %{root: root} do
      assert Sound.assign("voicemail", "wilhelm.wav") == :ok
      File.rm!(sound(root, "wilhelm.wav"))

      assert Sound.sound_map() == %{}
      assert Sound.for_notification(fired("reminder", "voicemail")) == "notify.wav"
    end
  end
end
