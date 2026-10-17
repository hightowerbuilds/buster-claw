defmodule BusterClaw.Studio.MixTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Studio.Mix

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
      audio = Mix.new("idea")

      # Zero tracks is a surface with nothing to drop onto.
      assert length(audio.tracks) == 1
      assert hd(audio.tracks).label == "A"
      assert hd(audio.tracks).clips == []
    end

    test "tracks are labelled A, B, C… and capped" do
      audio = Enum.reduce(1..20, Mix.new("idea"), fn _, a -> Mix.add_track(a) end)

      assert length(audio.tracks) == Mix.max_tracks()
      assert Enum.map(audio.tracks, & &1.label) |> Enum.take(3) == ["A", "B", "C"]
    end

    test "the last track cannot be removed" do
      audio = Mix.new("idea")
      assert Mix.remove_track(audio, track_id(audio, 0)).tracks == audio.tracks
    end

    test "removing a track takes its clips with it" do
      audio =
        Mix.new("idea")
        |> Mix.add_track()

      audio = Mix.add_clip(audio, track_id(audio, 1), "sound:alarm.wav", 0, 100)
      assert length(Mix.clips(audio)) == 1

      audio = Mix.remove_track(audio, track_id(audio, 1))
      assert Mix.clips(audio) == []
    end
  end

  describe "clips" do
    setup do
      audio = Mix.new("idea") |> Mix.add_track()
      {:ok, audio: audio}
    end

    test "a clip lands where it was placed", %{audio: audio} do
      audio = Mix.add_clip(audio, track_id(audio, 0), "sound:alarm.wav", 250, 1320)

      assert [{track, clip}] = Mix.clips(audio)
      assert track.label == "A"
      assert clip.start_ms == 250.0
      assert clip.duration_ms == 1320.0
      assert clip.source == "sound:alarm.wav"
    end

    test "a negative offset clamps to the start of the ruler", %{audio: audio} do
      audio = Mix.add_clip(audio, track_id(audio, 0), "sound:alarm.wav", -500, 100)
      assert [{_track, clip}] = Mix.clips(audio)
      assert clip.start_ms == 0.0
    end

    test "moving across tracks leaves exactly ONE copy", %{audio: audio} do
      audio = Mix.add_clip(audio, track_id(audio, 0), "sound:alarm.wav", 0, 100)
      [{_track, clip}] = Mix.clips(audio)

      moved = Mix.move_clip(audio, clip.id, track_id(audio, 1), 900)

      # A cross-track move is a removal plus an insertion; doing it as one
      # mutation is how a clip ends up on two tracks at once.
      assert [{track, one}] = Mix.clips(moved)
      assert track.label == "B"
      assert one.start_ms == 900.0
      assert one.id == clip.id
    end

    test "a move onto an unknown track is refused, not a dropped clip", %{audio: audio} do
      audio = Mix.add_clip(audio, track_id(audio, 0), "sound:alarm.wav", 0, 100)
      [{_track, clip}] = Mix.clips(audio)

      assert Mix.move_clip(audio, clip.id, "no-such-track", 500) == audio
    end

    test "moving a clip that is not there changes nothing", %{audio: audio} do
      assert Mix.move_clip(audio, "ghost", track_id(audio, 0), 100) == audio
    end

    test "duration is the furthest clip's far edge, across all tracks", %{audio: audio} do
      audio =
        audio
        |> Mix.add_clip(track_id(audio, 0), "a", 0, 500)
        |> Mix.add_clip(track_id(audio, 1), "b", 2_000, 750)

      assert Mix.duration_ms(audio) == 2_750.0
      assert Mix.duration_ms(Mix.new("empty")) == 0.0
    end

    test "clip ids are unique across an audio", %{audio: audio} do
      audio =
        Enum.reduce(1..25, audio, fn _, a ->
          Mix.add_clip(a, track_id(a, 0), "sound:alarm.wav", 0, 10)
        end)

      ids = audio |> Mix.clips() |> Enum.map(fn {_t, c} -> c.id end)
      assert length(Enum.uniq(ids)) == 25
    end
  end

  describe "mute and solo" do
    setup do
      audio = Mix.new("mix") |> Mix.add_track()
      {:ok, audio: audio}
    end

    test "a fresh track is neither muted nor soloed", %{audio: audio} do
      assert Enum.all?(audio.tracks, &(not &1.muted and not &1.soloed))
    end

    test "toggles flip and flip back", %{audio: audio} do
      id = track_id(audio, 0)

      muted = Mix.toggle_mute(audio, id)
      assert hd(muted.tracks).muted
      refute hd(Mix.toggle_mute(muted, id).tracks).muted

      soloed = Mix.toggle_solo(audio, id)
      assert hd(soloed.tracks).soloed
    end

    test "with no solo anywhere, mute is the whole story", %{audio: audio} do
      muted = Mix.toggle_mute(audio, track_id(audio, 0))

      refute Mix.audible?(muted, Enum.at(muted.tracks, 0))
      assert Mix.audible?(muted, Enum.at(muted.tracks, 1))
    end

    test "one solo silences every unsoloed track", %{audio: audio} do
      soloed = Mix.toggle_solo(audio, track_id(audio, 0))

      assert Mix.audible?(soloed, Enum.at(soloed.tracks, 0))
      refute Mix.audible?(soloed, Enum.at(soloed.tracks, 1))
    end

    test "solo beats mute on the same track", %{audio: audio} do
      id = track_id(audio, 0)
      both = audio |> Mix.toggle_mute(id) |> Mix.toggle_solo(id)

      # Engaging solo is the stronger, more recent statement of intent —
      # the Pro Tools and Logic resolution, i.e. what DAW fingers expect.
      assert Mix.audible?(both, Enum.at(both.tracks, 0))
    end

    test "audible_clips is what a render mixes", %{audio: audio} do
      audio =
        audio
        |> Mix.add_clip(track_id(audio, 0), "sound:a.wav", 0, 100)
        |> Mix.add_clip(track_id(audio, 1), "sound:b.wav", 0, 100)

      muted = Mix.toggle_mute(audio, track_id(audio, 1))

      assert [{_track, clip}] = Mix.audible_clips(muted)
      assert clip.source == "sound:a.wav"
    end

    test "mute and solo survive the round trip to disk" do
      {:ok, name} = Mix.create("flags")
      {:ok, audio} = Mix.load(name)
      audio = Mix.add_track(audio)

      audio =
        audio
        |> Mix.toggle_mute(track_id(audio, 0))
        |> Mix.toggle_solo(track_id(audio, 1))

      :ok = Mix.save(audio)
      {:ok, reloaded} = Mix.load(name)

      assert Enum.at(reloaded.tracks, 0).muted
      assert Enum.at(reloaded.tracks, 1).soloed
    end

    test "a hand-edited non-boolean flag is ignored, not honored", %{root: root} do
      {:ok, name} = Mix.create("edited-flags")
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

      assert {:ok, audio} = Mix.load(name)
      refute hd(audio.tracks).muted
    end
  end

  describe "storage" do
    test "create/1 sanitizes the name and never collides" do
      assert {:ok, "my idea"} = Mix.create("  my idea  ")
      assert {:ok, "my idea-2"} = Mix.create("my idea")
      assert Mix.list() == ["my idea", "my idea-2"]
    end

    test "create/1 refuses a name that reduces to nothing" do
      # An empty name would write `.mix.json` — a dotfile the listing ignores,
      # so the audio would vanish the instant it was made.
      assert {:error, :invalid_name} = Mix.create("   ")
      assert {:error, :invalid_name} = Mix.create("///")
      assert Mix.list() == []
    end

    test "a hostile name cannot escape the storage folder", %{root: root} do
      assert {:ok, name} = Mix.create("../../etc/evil")
      refute name =~ "/"
      assert File.regular?(Path.join([root, "sounds", "studio", "mixes", name <> ".mix.json"]))
    end

    test "an audio survives a round trip to disk" do
      {:ok, name} = Mix.create("round")
      {:ok, audio} = Mix.load(name)

      audio =
        audio
        |> Mix.add_track()

      audio = Mix.add_clip(audio, track_id(audio, 1), "import:cut.wav", 1_500, 300)
      :ok = Mix.save(audio)

      {:ok, reloaded} = Mix.load(name)
      assert [{track, clip}] = Mix.clips(reloaded)
      assert track.label == "B"
      assert clip.source == "import:cut.wav"
      assert clip.start_ms == 1_500.0
      assert clip.duration_ms == 300.0
    end

    test "loading something that is not there reports rather than raises" do
      assert {:error, :not_found} = Mix.load("nope")
      assert {:error, :not_found} = Mix.delete("nope")
    end

    test "a v1 file still loads, bad rows and all", %{root: root} do
      {:ok, name} = Mix.create("edited")
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

      assert {:ok, mix} = Mix.load(name)
      assert length(mix.tracks) == 2
      assert [{_track, clip}] = Mix.clips(mix)
      assert clip.source == "sound:boot.wav"
      # A clip with no cached duration still loads; a render re-reads the source.
      assert clip.duration_ms == 0.0

      # And saving it back rewrites the file as v2 — reading old is forever,
      # writing old is not.
      :ok = Mix.save(mix)
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

      assert :ok = Mix.migrate_v1()

      assert "from-backup" in Mix.list()
      assert {:ok, mix} = Mix.load("from-backup")
      assert [{_track, %{source: "sound:boot.wav"}}] = Mix.clips(mix)
      # The stray file kept the old directory alive, exactly as intended.
      assert File.regular?(Path.join(old, "notes.txt"))
    end

    test "migrate_v1/0 never overwrites a name that already exists", %{root: root} do
      {:ok, name} = Mix.create("clash")
      new_path = Path.join([root, "sounds", "studio", "mixes", name <> ".mix.json"])
      mine = File.read!(new_path)

      old = Path.join([root, "sounds", "studio", "tracks"])
      File.mkdir_p!(old)
      File.write!(Path.join(old, name <> ".track.json"), ~s({"version":1,"name":"clash"}))

      assert :ok = Mix.migrate_v1()

      # We do not get to pick which of a user's two files survives.
      assert File.read!(new_path) == mine
      assert File.regular?(Path.join(old, name <> ".track.json"))
    end

    test "migrate_v1/0 is idempotent and a no-op without a v1 folder" do
      assert :ok = Mix.migrate_v1()
      assert :ok = Mix.migrate_v1()
    end

    test "a file with no rows at all opens with one track, not zero", %{root: root} do
      {:ok, name} = Mix.create("bare")
      path = Path.join([root, "sounds", "studio", "mixes", name <> ".mix.json"])
      File.write!(path, Jason.encode!(%{"version" => 2, "name" => name, "tracks" => []}))

      assert {:ok, audio} = Mix.load(name)
      assert length(audio.tracks) == 1
    end

    test "mixes do not show up as importable audio files" do
      {:ok, _name} = Mix.create("quiet")
      # `.mix.json` is not an audio extension, so the Imports group ignores it.
      assert BusterClaw.Studio.Editor.list() == []
    end
  end

  # Both of these used to exist TWICE — one copy in StatusLive, one in
  # SoundStudioComponent, in different shapes and unaware of each other.
  # Consolidated here 08-03; these are the tests neither copy had.
  describe "track_end_ms — where an appended clip lands" do
    test "an empty track ends at zero, not at nil" do
      audio = Mix.new("idea")
      assert Mix.track_end_ms(audio, track_id(audio, 0)) == 0.0
      assert Mix.track_end_ms(Enum.at(audio.tracks, 0)) == 0.0
    end

    test "it is the furthest clip END, not the furthest clip START" do
      audio =
        Mix.new("idea")
        |> then(&Mix.add_clip(&1, track_id(&1, 0), "a", 0, 900))
        |> then(&Mix.add_clip(&1, track_id(&1, 0), "b", 100, 200))

      # A long clip at 0 outreaches a short one starting later; taking the max
      # start would drop the next clip on top of audio already there.
      assert Mix.track_end_ms(audio, track_id(audio, 0)) == 900
    end

    test "an unknown track id reads as empty rather than raising" do
      audio = Mix.new("idea")
      assert Mix.track_end_ms(audio, "no-such-track") == 0.0
    end

    test "tracks are measured independently" do
      audio = Mix.new("idea") |> Mix.add_track()
      audio = Mix.add_clip(audio, track_id(audio, 0), "a", 0, 500)

      assert Mix.track_end_ms(audio, track_id(audio, 0)) == 500
      assert Mix.track_end_ms(audio, track_id(audio, 1)) == 0.0
    end
  end

  describe "paste_track — where a paste lands" do
    test "it lands on the track already holding the copied clip" do
      audio = Mix.new("idea") |> Mix.add_track()
      audio = Mix.add_clip(audio, track_id(audio, 1), "a", 0, 100)
      [{_track, clip}] = Mix.clips(audio)

      assert Mix.paste_track(audio, clip.id).id == track_id(audio, 1)
    end

    test "an unknown or nil clip id falls back to the first track" do
      audio = Mix.new("idea") |> Mix.add_track()

      assert Mix.paste_track(audio, "gone").id == track_id(audio, 0)
      assert Mix.paste_track(audio, nil).id == track_id(audio, 0)
    end
  end

  describe "trim_clip/4 — a clip's window into its source" do
    setup do
      {:ok, "trimmix"} = Mix.create("trimmix")
      {:ok, mix} = Mix.load("trimmix")
      [track | _] = mix.tracks
      placed = Mix.add_clip(mix, track.id, "a.wav", 0, 1_000)
      [clip] = Enum.map(Mix.clips(placed), fn {_t, c} -> c end)
      %{mix: placed, clip: clip}
    end

    test "narrows what the mix uses and leaves the timeline alone", %{mix: mix, clip: clip} do
      trimmed = Mix.trim_clip(mix, clip.id, 250, 400)
      got = Mix.find_clip(trimmed, clip.id)

      assert Mix.window(got) == {250.0, 400.0}
      # Trimming changes WHAT plays, not WHEN. A trim that also moved the clip
      # would make every edit a two-handed operation.
      assert got.start_ms == clip.start_ms
    end

    test "a clip written before the field still answers", %{mix: _mix, clip: clip} do
      # Every mix from before 08-16 has clips with no `offset_ms` key at all and
      # must keep opening — the same tolerance `chain/1` gives `effects`. Zero
      # is also the right answer: those clips start at the beginning.
      legacy = Map.delete(clip, :offset_ms)

      assert Mix.window(legacy) == {0.0, clip.duration_ms}
    end

    test "a zero or negative length is refused rather than written", %{mix: mix, clip: clip} do
      # A clip you cannot hear and cannot see is worse than a rejected edit.
      assert Mix.trim_clip(mix, clip.id, 0, 0) == mix
      assert Mix.trim_clip(mix, clip.id, 0, -5) == mix
    end

    test "a negative offset clamps rather than reaching before the file", %{mix: mix, clip: clip} do
      trimmed = Mix.trim_clip(mix, clip.id, -100, 200)
      assert Mix.window(Mix.find_clip(trimmed, clip.id)) == {0.0, 200.0}
    end

    test "a duplicate inherits the window", %{mix: mix, clip: clip} do
      # The dry-paste bug of 08-16, one field along: a copy that silently got
      # the whole source back would be the same silent loss.
      trimmed = Mix.trim_clip(mix, clip.id, 100, 300)
      copied = Mix.duplicate_clip(trimmed, clip.id)

      windows =
        copied
        |> Mix.clips()
        |> Enum.map(fn {_t, c} -> Mix.window(c) end)

      assert windows == [{100.0, 300.0}, {100.0, 300.0}]
    end
  end
end
