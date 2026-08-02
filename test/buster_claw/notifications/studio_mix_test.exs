defmodule BusterClaw.Notifications.StudioMixTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Notifications.StudioMix

  setup do
    root = Path.join(System.tmp_dir!(), "bc_audio_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp track_id(audio, index), do: Enum.at(audio.tracks, index).id

  describe "shape" do
    test "a new audio opens with one track, not zero" do
      audio = StudioMix.new("idea")

      # Zero tracks is a surface with nothing to drop onto.
      assert length(audio.tracks) == 1
      assert hd(audio.tracks).label == "A"
      assert hd(audio.tracks).clips == []
    end

    test "tracks are labelled A, B, C… and capped" do
      audio = Enum.reduce(1..20, StudioMix.new("idea"), fn _, a -> StudioMix.add_track(a) end)

      assert length(audio.tracks) == StudioMix.max_tracks()
      assert Enum.map(audio.tracks, & &1.label) |> Enum.take(3) == ["A", "B", "C"]
    end

    test "the last track cannot be removed" do
      audio = StudioMix.new("idea")
      assert StudioMix.remove_track(audio, track_id(audio, 0)).tracks == audio.tracks
    end

    test "removing a track takes its clips with it" do
      audio =
        StudioMix.new("idea")
        |> StudioMix.add_track()

      audio = StudioMix.add_clip(audio, track_id(audio, 1), "sound:alarm.wav", 0, 100)
      assert length(StudioMix.clips(audio)) == 1

      audio = StudioMix.remove_track(audio, track_id(audio, 1))
      assert StudioMix.clips(audio) == []
    end
  end

  describe "clips" do
    setup do
      audio = StudioMix.new("idea") |> StudioMix.add_track()
      {:ok, audio: audio}
    end

    test "a clip lands where it was placed", %{audio: audio} do
      audio = StudioMix.add_clip(audio, track_id(audio, 0), "sound:alarm.wav", 250, 1320)

      assert [{track, clip}] = StudioMix.clips(audio)
      assert track.label == "A"
      assert clip.start_ms == 250.0
      assert clip.duration_ms == 1320.0
      assert clip.source == "sound:alarm.wav"
    end

    test "a negative offset clamps to the start of the ruler", %{audio: audio} do
      audio = StudioMix.add_clip(audio, track_id(audio, 0), "sound:alarm.wav", -500, 100)
      assert [{_track, clip}] = StudioMix.clips(audio)
      assert clip.start_ms == 0.0
    end

    test "moving across tracks leaves exactly ONE copy", %{audio: audio} do
      audio = StudioMix.add_clip(audio, track_id(audio, 0), "sound:alarm.wav", 0, 100)
      [{_track, clip}] = StudioMix.clips(audio)

      moved = StudioMix.move_clip(audio, clip.id, track_id(audio, 1), 900)

      # A cross-track move is a removal plus an insertion; doing it as one
      # mutation is how a clip ends up on two tracks at once.
      assert [{track, one}] = StudioMix.clips(moved)
      assert track.label == "B"
      assert one.start_ms == 900.0
      assert one.id == clip.id
    end

    test "a move onto an unknown track is refused, not a dropped clip", %{audio: audio} do
      audio = StudioMix.add_clip(audio, track_id(audio, 0), "sound:alarm.wav", 0, 100)
      [{_track, clip}] = StudioMix.clips(audio)

      assert StudioMix.move_clip(audio, clip.id, "no-such-track", 500) == audio
    end

    test "moving a clip that is not there changes nothing", %{audio: audio} do
      assert StudioMix.move_clip(audio, "ghost", track_id(audio, 0), 100) == audio
    end

    test "duration is the furthest clip's far edge, across all tracks", %{audio: audio} do
      audio =
        audio
        |> StudioMix.add_clip(track_id(audio, 0), "a", 0, 500)
        |> StudioMix.add_clip(track_id(audio, 1), "b", 2_000, 750)

      assert StudioMix.duration_ms(audio) == 2_750.0
      assert StudioMix.duration_ms(StudioMix.new("empty")) == 0.0
    end

    test "clip ids are unique across an audio", %{audio: audio} do
      audio =
        Enum.reduce(1..25, audio, fn _, a ->
          StudioMix.add_clip(a, track_id(a, 0), "sound:alarm.wav", 0, 10)
        end)

      ids = audio |> StudioMix.clips() |> Enum.map(fn {_t, c} -> c.id end)
      assert length(Enum.uniq(ids)) == 25
    end
  end

  describe "mute and solo" do
    setup do
      audio = StudioMix.new("mix") |> StudioMix.add_track()
      {:ok, audio: audio}
    end

    test "a fresh track is neither muted nor soloed", %{audio: audio} do
      assert Enum.all?(audio.tracks, &(not &1.muted and not &1.soloed))
    end

    test "toggles flip and flip back", %{audio: audio} do
      id = track_id(audio, 0)

      muted = StudioMix.toggle_mute(audio, id)
      assert hd(muted.tracks).muted
      refute hd(StudioMix.toggle_mute(muted, id).tracks).muted

      soloed = StudioMix.toggle_solo(audio, id)
      assert hd(soloed.tracks).soloed
    end

    test "with no solo anywhere, mute is the whole story", %{audio: audio} do
      muted = StudioMix.toggle_mute(audio, track_id(audio, 0))

      refute StudioMix.audible?(muted, Enum.at(muted.tracks, 0))
      assert StudioMix.audible?(muted, Enum.at(muted.tracks, 1))
    end

    test "one solo silences every unsoloed track", %{audio: audio} do
      soloed = StudioMix.toggle_solo(audio, track_id(audio, 0))

      assert StudioMix.audible?(soloed, Enum.at(soloed.tracks, 0))
      refute StudioMix.audible?(soloed, Enum.at(soloed.tracks, 1))
    end

    test "solo beats mute on the same track", %{audio: audio} do
      id = track_id(audio, 0)
      both = audio |> StudioMix.toggle_mute(id) |> StudioMix.toggle_solo(id)

      # Engaging solo is the stronger, more recent statement of intent —
      # the Pro Tools and Logic resolution, i.e. what DAW fingers expect.
      assert StudioMix.audible?(both, Enum.at(both.tracks, 0))
    end

    test "audible_clips is what a render mixes", %{audio: audio} do
      audio =
        audio
        |> StudioMix.add_clip(track_id(audio, 0), "sound:a.wav", 0, 100)
        |> StudioMix.add_clip(track_id(audio, 1), "sound:b.wav", 0, 100)

      muted = StudioMix.toggle_mute(audio, track_id(audio, 1))

      assert [{_track, clip}] = StudioMix.audible_clips(muted)
      assert clip.source == "sound:a.wav"
    end

    test "mute and solo survive the round trip to disk" do
      {:ok, name} = StudioMix.create("flags")
      {:ok, audio} = StudioMix.load(name)
      audio = StudioMix.add_track(audio)

      audio =
        audio
        |> StudioMix.toggle_mute(track_id(audio, 0))
        |> StudioMix.toggle_solo(track_id(audio, 1))

      :ok = StudioMix.save(audio)
      {:ok, reloaded} = StudioMix.load(name)

      assert Enum.at(reloaded.tracks, 0).muted
      assert Enum.at(reloaded.tracks, 1).soloed
    end

    test "a hand-edited non-boolean flag is ignored, not honored", %{root: root} do
      {:ok, name} = StudioMix.create("edited-flags")
      path = Path.join([root, "sounds", "studio", "mixes", name <> ".mix.json"])

      # "yes" is a helpful human's boolean. Honoring truthiness would produce
      # a track the UI's boolean flip can never seem to unmute.
      File.write!(
        path,
        Jason.encode!(%{
          "version" => 2,
          "name" => name,
          "tracks" => [%{"id" => "L1", "label" => "A", "muted" => "yes", "clips" => []}]
        })
      )

      assert {:ok, audio} = StudioMix.load(name)
      refute hd(audio.tracks).muted
    end
  end

  describe "storage" do
    test "create/1 sanitizes the name and never collides" do
      assert {:ok, "my idea"} = StudioMix.create("  my idea  ")
      assert {:ok, "my idea-2"} = StudioMix.create("my idea")
      assert StudioMix.list() == ["my idea", "my idea-2"]
    end

    test "create/1 refuses a name that reduces to nothing" do
      # An empty name would write `.mix.json` — a dotfile the listing ignores,
      # so the audio would vanish the instant it was made.
      assert {:error, :invalid_name} = StudioMix.create("   ")
      assert {:error, :invalid_name} = StudioMix.create("///")
      assert StudioMix.list() == []
    end

    test "a hostile name cannot escape the storage folder", %{root: root} do
      assert {:ok, name} = StudioMix.create("../../etc/evil")
      refute name =~ "/"
      assert File.regular?(Path.join([root, "sounds", "studio", "mixes", name <> ".mix.json"]))
    end

    test "an audio survives a round trip to disk" do
      {:ok, name} = StudioMix.create("round")
      {:ok, audio} = StudioMix.load(name)

      audio =
        audio
        |> StudioMix.add_track()

      audio = StudioMix.add_clip(audio, track_id(audio, 1), "import:cut.wav", 1_500, 300)
      :ok = StudioMix.save(audio)

      {:ok, reloaded} = StudioMix.load(name)
      assert [{track, clip}] = StudioMix.clips(reloaded)
      assert track.label == "B"
      assert clip.source == "import:cut.wav"
      assert clip.start_ms == 1_500.0
      assert clip.duration_ms == 300.0
    end

    test "loading something that is not there reports rather than raises" do
      assert {:error, :not_found} = StudioMix.load("nope")
      assert {:error, :not_found} = StudioMix.delete("nope")
    end

    test "a v1 file still loads, bad rows and all", %{root: root} do
      {:ok, name} = StudioMix.create("edited")
      path = Path.join([root, "sounds", "studio", "mixes", name <> ".mix.json"])

      # v1 said "lanes". These files live in the operator's workspace and are
      # invited to be hand-edited, so the old key must keep working — a copy
      # pasted back from an old backup opens. One bad row must not make the mix
      # unopenable either.
      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "name" => name,
          "lanes" => [
            %{"id" => "L1", "label" => "A", "clips" => [%{"nonsense" => true}]},
            %{"broken" => "no id"},
            %{
              "id" => "L2",
              "label" => "B",
              "clips" => [%{"id" => "C1", "source" => "sound:boot.wav", "start_ms" => 10}]
            }
          ]
        })
      )

      assert {:ok, mix} = StudioMix.load(name)
      assert length(mix.tracks) == 2
      assert [{_track, clip}] = StudioMix.clips(mix)
      assert clip.source == "sound:boot.wav"
      # A clip with no cached duration still loads; a render re-reads the source.
      assert clip.duration_ms == 0.0

      # And saving it back rewrites the file as v2 — reading old is forever,
      # writing old is not.
      :ok = StudioMix.save(mix)
      assert %{"version" => 2, "tracks" => [_ | _]} = path |> File.read!() |> Jason.decode!()
    end

    test "migrate_v1/0 moves a v1 folder to mixes/, keeping every arrangement", %{root: root} do
      old = Path.join([root, "sounds", "studio", "tracks"])
      File.mkdir_p!(old)

      File.write!(
        Path.join(old, "from-backup.track.json"),
        Jason.encode!(%{
          "version" => 1,
          "name" => "from-backup",
          "lanes" => [
            %{
              "id" => "L1",
              "label" => "A",
              "clips" => [%{"id" => "C1", "source" => "sound:boot.wav", "start_ms" => 0}]
            }
          ]
        })
      )

      # Not ours — left where it is rather than swept up.
      File.write!(Path.join(old, "notes.txt"), "hand-written")

      assert :ok = StudioMix.migrate_v1()

      assert "from-backup" in StudioMix.list()
      assert {:ok, mix} = StudioMix.load("from-backup")
      assert [{_track, %{source: "sound:boot.wav"}}] = StudioMix.clips(mix)
      # The stray file kept the old directory alive, exactly as intended.
      assert File.regular?(Path.join(old, "notes.txt"))
    end

    test "migrate_v1/0 never overwrites a name that already exists", %{root: root} do
      {:ok, name} = StudioMix.create("clash")
      new_path = Path.join([root, "sounds", "studio", "mixes", name <> ".mix.json"])
      mine = File.read!(new_path)

      old = Path.join([root, "sounds", "studio", "tracks"])
      File.mkdir_p!(old)
      File.write!(Path.join(old, name <> ".track.json"), ~s({"version":1,"name":"clash"}))

      assert :ok = StudioMix.migrate_v1()

      # We do not get to pick which of a user's two files survives.
      assert File.read!(new_path) == mine
      assert File.regular?(Path.join(old, name <> ".track.json"))
    end

    test "migrate_v1/0 is idempotent and a no-op without a v1 folder" do
      assert :ok = StudioMix.migrate_v1()
      assert :ok = StudioMix.migrate_v1()
    end

    test "a file with no rows at all opens with one track, not zero", %{root: root} do
      {:ok, name} = StudioMix.create("bare")
      path = Path.join([root, "sounds", "studio", "mixes", name <> ".mix.json"])
      File.write!(path, Jason.encode!(%{"version" => 2, "name" => name, "tracks" => []}))

      assert {:ok, audio} = StudioMix.load(name)
      assert length(audio.tracks) == 1
    end

    test "mixes do not show up as importable audio files" do
      {:ok, _name} = StudioMix.create("quiet")
      # `.mix.json` is not an audio extension, so the Imports group ignores it.
      assert BusterClaw.Notifications.SoundStudio.list() == []
    end
  end
end
