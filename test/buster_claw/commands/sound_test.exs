defmodule BusterClaw.Commands.SoundTest do
  # async: false — points the global :workspace_root at a tmp dir, which is how
  # the sound library resolves.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Commands
  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Notifications.SoundGen

  # afinfo is a macOS system binary; the header-probe cases are skipped on a
  # machine without it rather than failing forever.
  @prober_available File.regular?("/usr/bin/afinfo")

  setup do
    root = Path.join(System.tmp_dir!(), "bc_cmd_sound_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sounds"))
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

  # A real WAV — the same bytes the app ships as a chime, so probe has
  # something honest to read.
  defp wav, do: SoundGen.render("boot")

  defp library(root, name, contents \\ nil),
    do: File.write!(Path.join([root, "sounds", name]), contents || wav())

  defp entry(%{sounds: sounds}, name), do: Enum.find(sounds, &(&1.name == name))
  defp route(%{routes: routes}, key), do: Enum.find(routes, &(&1.key == key))

  # A file under the Library root, at a path relative to it.
  defp recording(root, relative, contents \\ nil) do
    path = Path.join([root, "library", relative])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents || wav())
    relative
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

  describe "sound_probe" do
    if @prober_available do
      test "describes a real WAV from its header: format and duration", %{root: root} do
        library(root, "chime.wav")

        assert {:ok, probe} = Commands.Sound.sound_probe(%{"name" => "chime.wav"})

        assert probe.layer == "workspace"
        assert probe.path == Path.join(Sound.dir(), "chime.wav")
        assert probe.sample_rate == 22_050
        assert probe.channels == 1
        assert probe.duration_ms > 0
        assert probe.bytes == byte_size(wav())
        assert probe.notes == []
      end

      test "something that is not audio says so instead of guessing", %{root: root} do
        library(root, "prose.wav", "this is not audio")

        assert {:ok, probe} = Commands.Sound.sound_probe(%{"name" => "prose.wav"})

        assert probe.duration_ms == nil
        assert probe.sample_rate == nil
        assert Enum.any?(probe.notes, &(&1 =~ "header prober could not answer"))
      end
    end

    test "resolves the bundled layer, and a workspace file outranks its bundled twin",
         %{root: root} do
      assert {:ok, %{layer: "bundled"}} = Commands.Sound.sound_probe(%{"name" => "boot.wav"})

      library(root, "confirm.wav")

      assert {:ok, probe} = Commands.Sound.sound_probe(%{"name" => "confirm.wav"})
      assert probe.layer == "workspace"
      assert probe.path == Path.join(Sound.dir(), "confirm.wav")
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
      assert probe.name == "take-1.wav"
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

    test "a bare name still resolves the two sound layers, and no input is named", %{
      root: root
    } do
      library(root, "chime.wav")

      assert {:ok, %{layer: "workspace", library_path: nil}} =
               Commands.Sound.sound_probe(%{"name" => "chime.wav"})

      assert {:error, :missing_name} = Commands.Sound.sound_probe(%{"decode" => true})
    end
  end

  describe "sound_apply" do
    test "routes a key to a library sound", %{root: root} do
      library(root, "ramshackle.wav")

      assert {:ok, result} =
               Commands.Sound.sound_apply(%{"source" => "ramshackle.wav", "route" => "email"})

      assert result.name == "ramshackle.wav"
      assert result.layer == "workspace"
      assert result.route == "email"
      assert result.route_label == "Email"
      assert result.plays == "ramshackle.wav"

      # The routing table actually resolves to it — for the key, and for a
      # notification that would fire against that key.
      assert Sound.resolved("email") == "ramshackle.wav"
      assert Sound.for_notification(%{source: "email", kind: "timer"}) == "ramshackle.wav"

      assert {:ok, routes} = Commands.Sound.sound_routes()

      assert %{assigned: "ramshackle.wav", plays: "ramshackle.wav", origin: "explicit"} =
               route(routes, "email")
    end

    test "a bundled default can be routed as it is" do
      assert {:ok, result} =
               Commands.Sound.sound_apply(%{"source" => "boot.wav", "route" => "chat"})

      assert result.layer == "bundled"
      assert Sound.resolved("chat") == "boot.wav"
    end

    test "the way back is in the result", %{root: root} do
      library(root, "old.wav")
      library(root, "new.wav")
      assert :ok = Sound.assign("email", "old.wav")

      assert {:ok, result} =
               Commands.Sound.sound_apply(%{"source" => "new.wav", "route" => "email"})

      assert result.previous_sound == "old.wav"
      assert result.previously_played == "old.wav"
      assert result.plays == "new.wav"
      assert Enum.any?(result.notes, &(&1 =~ "old.wav"))
      assert Enum.any?(result.notes, &(&1 =~ "sound_restore_defaults"))
    end

    test "a typo'd route, and a sound that isn't there, are refused BEFORE anything changes",
         %{root: root} do
      library(root, "sentence.wav")

      assert {:error, :unknown_route} =
               Commands.Sound.sound_apply(%{"source" => "sentence.wav", "route" => "voicemale"})

      assert {:error, :not_found} =
               Commands.Sound.sound_apply(%{"source" => "nope.wav", "route" => "email"})

      assert {:error, :invalid_name} =
               Commands.Sound.sound_apply(%{"source" => "../escape.wav", "route" => "email"})

      # Nothing routed — which is the entire point of validating at the verb
      # rather than at the assignment.
      assert Sound.sound_map() == %{}

      assert {:error, :missing_route} = Commands.Sound.sound_apply(%{"source" => "sentence.wav"})
      assert {:error, :missing_source} = Commands.Sound.sound_apply(%{"route" => "email"})
    end

    test "it says so when the master switch is off", %{root: root} do
      library(root, "sentence.wav")
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
      library(root, "ramshackle.wav")

      assert {:ok, _applied} =
               Commands.Sound.sound_apply(%{"source" => "ramshackle.wav", "route" => "email"})

      assert Sound.resolved("email") == "ramshackle.wav"

      assert {:ok, result} =
               Commands.Sound.sound_restore_defaults(%{"sounds" => false, "routes" => true})

      assert result.cleared_routes == ["email"]
      assert result.counts.copied == 0

      # The key inherits again and falls back to its bundled chime. The routed
      # file is still on disk — nothing is deleted, only unrouted.
      assert Sound.sound_map() == %{}
      assert File.regular?(Path.join([root, "sounds", "ramshackle.wav"]))
    end
  end

  describe "dispatch by name" do
    # The wiring is the surface: a handler nothing can reach through call/3 is
    # not a command. Catalog entry, registration, delegate and handler all have
    # to line up for these to answer.
    test "the verbs are reachable through Commands.call/3", %{root: root} do
      library(root, "chime.wav")
      recording(root, "calls/take-1.wav")

      assert {:ok, %{sounds: sounds}} = Commands.call("sound_list", %{})
      assert Enum.any?(sounds, &(&1.name == "chime.wav"))

      assert {:ok, %{routes: routes}} = Commands.call("sound_routes", %{})
      assert length(routes) == length(Sound.route_keys())

      assert {:ok, %{name: "chime.wav", layer: "workspace"}} =
               Commands.call("sound_probe", %{"name" => "chime.wav"})

      assert {:ok, %{layer: "library"}} =
               Commands.call("sound_probe", %{"path" => "calls/take-1.wav"})

      assert {:error, :absolute_path} = Commands.call("sound_probe", %{"path" => "/etc/passwd"})
      assert {:error, :not_found} = Commands.call("sound_probe", %{"name" => "nope.wav"})
      assert {:error, :invalid_name} = Commands.call("sound_probe", %{"name" => "../secrets.wav"})
    end

    test "the catalog advertises reads as safe, the undo as restricted, and routing as gated" do
      catalog = Map.new(Commands.list_commands(), &{&1.name, &1})

      for name <- ~w(sound_list sound_routes sound_probe) do
        entry = Map.fetch!(catalog, name)
        assert entry.type == :read, "#{name} should be a read"
        assert entry.tier == :safe, "#{name} should be safe"
        refute Map.get(entry, :gated, false), "#{name} should not be gated"
      end

      # The way back: restricted, and deliberately NOT gated.
      restore = Map.fetch!(catalog, "sound_restore_defaults")
      assert restore.type == :mutate
      assert restore.tier == :restricted
      refute Map.get(restore, :gated, false), "gating the undo strands whoever needs it"

      # And the one that is. Routing changes what the machine does when nobody
      # is watching, which is the whole of the difference.
      apply_entry = Map.fetch!(catalog, "sound_apply")
      assert apply_entry.type == :mutate
      assert apply_entry.tier == :restricted
      assert apply_entry.gated
      assert apply_entry.args["source"].required
      assert apply_entry.args["route"].required
      assert apply_entry.description =~ "unknown_route"
      assert apply_entry.description =~ "sound_routes"

      # sound_probe takes one of two inputs, so neither is required on its own —
      # the handler names the missing one instead.
      probe = Map.fetch!(catalog, "sound_probe")
      refute probe.args["name"].required
      assert Map.has_key?(probe.args, "path")
      refute Map.has_key?(probe.args, "decode")

      # The Studio's verbs left 10-16 (STUDIO_REMOVAL_ROADMAP), the cut-up's
      # 09-19. A stale entry would teach a model a command that answers
      # `unknown_command`.
      for gone <- ~w(
            sound_sources sound_import sound_trim sound_fade sound_normalize
            sound_concat sound_delete sound_devices sound_input_level
            sound_input_level_set sound_record
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
