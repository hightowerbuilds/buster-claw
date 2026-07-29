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

  describe "bundled defaults (SOUND_ROADMAP Phase 0)" do
    defp fired2(kind, source), do: %{kind: kind, source: source}

    test "the generated set is present and lists every routed key's file" do
      # This asserts against the COMMITTED priv/static/sounds, not a fixture —
      # the whole point of bundled-ON is that these ship.
      bundled = Sound.bundled_list()

      for key <- Sound.route_keys() -- ["default"] do
        assert "#{key}.wav" in bundled, "no bundled default for routing key #{key}"
      end
    end

    test "an empty workspace library rings on bundled defaults — the day-one contract" do
      assert Sound.list() == []

      assert Sound.for_notification(fired2("timer", "chat")) == "chat.wav"
      # Source without a bundled file falls to the kind.
      assert Sound.for_notification(fired2("timer", "no-such-source")) == "timer.wav"
      assert Sound.resolved("confirm") == "confirm.wav"
      assert Sound.resolved("security") == "security.wav"
    end

    test "any workspace layer outranks bundled", %{root: root} do
      # A routed workspace sound wins…
      File.write!(sound(root, "wilhelm.wav"), "x")
      assert Sound.assign("chat", "wilhelm.wav") == :ok
      assert Sound.for_notification(fired2("timer", "chat")) == "wilhelm.wav"

      # …and so does the legacy unrouted fallback (first audio file): dropping
      # ONE file into sounds/ takes over everything, exactly as before bundling.
      assert Sound.assign("chat", nil) == :ok
      assert Sound.for_notification(fired2("timer", "chat")) == "wilhelm.wav"
    end

    test "resolve_path: workspace wins by basename, bundled is the floor", %{root: root} do
      bundled_path = Sound.resolve_path("confirm.wav")
      assert bundled_path == Path.join(Sound.bundled_dir(), "confirm.wav")
      assert File.regular?(bundled_path)

      # Same-name workspace file shadows the bundled one — the drop-a-file
      # customization story, no routing entry needed.
      File.write!(sound(root, "confirm.wav"), "custom")
      assert Sound.resolve_path("confirm.wav") == sound(root, "confirm.wav")

      # Deleting the override falls BACK to bundled rather than to silence.
      File.rm!(sound(root, "confirm.wav"))
      assert Sound.resolve_path("confirm.wav") == bundled_path
    end

    test "resolve_path refuses what neither allowlist contains" do
      assert Sound.resolve_path("nope.wav") == nil
      assert Sound.resolve_path("../confirm.wav") == nil
      assert Sound.resolve_path("../../etc/passwd") == nil
    end

    test "the new routing keys are assignable like the old ones", %{root: root} do
      File.write!(sound(root, "wilhelm.wav"), "x")

      for key <- ~w(confirm order shift blocked web sms security boot) do
        assert Sound.assign(key, "wilhelm.wav") == :ok, "#{key} not assignable"
      end
    end
  end

  describe "silent routing (Phase 2)" do
    defp fired3(kind, source), do: %{kind: kind, source: source}

    test "silent on a key resolves to nothing, past every fallback layer", %{root: root} do
      # Even with a workspace file AND a bundled default available, silent wins.
      File.write!(sound(root, "notify.wav"), "x")

      assert Sound.assign("voicemail", "silent") == :ok
      assert Sound.sound_map()["voicemail"] == "silent"
      assert Sound.for_notification(fired3("reminder", "voicemail")) == nil
    end

    test "silent on a SOURCE does not fall through to the kind's sound", %{root: root} do
      # "Mute voicemails" must not ring the timer chime — silent is a
      # definitive answer, not an inherit.
      File.write!(sound(root, "bongos.wav"), "x")
      assert Sound.assign("timer", "bongos.wav") == :ok
      assert Sound.assign("voicemail", "silent") == :ok

      assert Sound.for_notification(fired3("timer", "voicemail")) == nil
      # The kind's own routing still works for other sources.
      assert Sound.for_notification(fired3("timer", "manual")) == "bongos.wav"
    end

    test "resolved/1 reports silent as nil for the settings display" do
      assert Sound.assign("security", "silent") == :ok
      assert Sound.resolved("security") == nil
    end

    test "clearing a silent entry restores inheritance down to bundled" do
      assert Sound.assign("confirm", "silent") == :ok
      assert Sound.resolved("confirm") == nil

      assert Sound.assign("confirm", "") == :ok
      assert Sound.resolved("confirm") == "confirm.wav"
    end

    test "a bundled name is routable with no workspace copy" do
      assert Sound.assign("confirm", "boot.wav") == :ok
      assert Sound.resolved("confirm") == "boot.wav"
      # And survives the sound_map validity filter on read.
      assert Sound.sound_map()["confirm"] == "boot.wav"
    end
  end

  describe "the master switch" do
    test "defaults ON, flips OFF and back, and re-enabling deletes the setting" do
      assert Sound.enabled?()

      assert Sound.set_enabled(false) == :ok
      refute Sound.enabled?()

      assert Sound.set_enabled(true) == :ok
      assert Sound.enabled?()
      # ON is the absence of the setting — a fresh install and a re-enabled one
      # are the same state.
      assert BusterClaw.Settings.get("sound_enabled") == nil
    end
  end
end
