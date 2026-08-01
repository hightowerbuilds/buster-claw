defmodule BusterClaw.Notifications.StudioAudioTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Notifications.StudioAudio

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
      audio = StudioAudio.new("idea")

      # Zero tracks is a surface with nothing to drop onto.
      assert length(audio.tracks) == 1
      assert hd(audio.tracks).label == "A"
      assert hd(audio.tracks).clips == []
    end

    test "tracks are labelled A, B, C… and capped" do
      audio = Enum.reduce(1..20, StudioAudio.new("idea"), fn _, a -> StudioAudio.add_track(a) end)

      assert length(audio.tracks) == StudioAudio.max_tracks()
      assert Enum.map(audio.tracks, & &1.label) |> Enum.take(3) == ["A", "B", "C"]
    end

    test "the last track cannot be removed" do
      audio = StudioAudio.new("idea")
      assert StudioAudio.remove_track(audio, track_id(audio, 0)).tracks == audio.tracks
    end

    test "removing a track takes its clips with it" do
      audio =
        StudioAudio.new("idea")
        |> StudioAudio.add_track()

      audio = StudioAudio.add_clip(audio, track_id(audio, 1), "sound:alarm.wav", 0, 100)
      assert length(StudioAudio.clips(audio)) == 1

      audio = StudioAudio.remove_track(audio, track_id(audio, 1))
      assert StudioAudio.clips(audio) == []
    end
  end

  describe "clips" do
    setup do
      audio = StudioAudio.new("idea") |> StudioAudio.add_track()
      {:ok, audio: audio}
    end

    test "a clip lands where it was placed", %{audio: audio} do
      audio = StudioAudio.add_clip(audio, track_id(audio, 0), "sound:alarm.wav", 250, 1320)

      assert [{track, clip}] = StudioAudio.clips(audio)
      assert track.label == "A"
      assert clip.start_ms == 250.0
      assert clip.duration_ms == 1320.0
      assert clip.source == "sound:alarm.wav"
    end

    test "a negative offset clamps to the start of the ruler", %{audio: audio} do
      audio = StudioAudio.add_clip(audio, track_id(audio, 0), "sound:alarm.wav", -500, 100)
      assert [{_track, clip}] = StudioAudio.clips(audio)
      assert clip.start_ms == 0.0
    end

    test "moving across tracks leaves exactly ONE copy", %{audio: audio} do
      audio = StudioAudio.add_clip(audio, track_id(audio, 0), "sound:alarm.wav", 0, 100)
      [{_track, clip}] = StudioAudio.clips(audio)

      moved = StudioAudio.move_clip(audio, clip.id, track_id(audio, 1), 900)

      # A cross-track move is a removal plus an insertion; doing it as one
      # mutation is how a clip ends up on two tracks at once.
      assert [{track, one}] = StudioAudio.clips(moved)
      assert track.label == "B"
      assert one.start_ms == 900.0
      assert one.id == clip.id
    end

    test "a move onto an unknown track is refused, not a dropped clip", %{audio: audio} do
      audio = StudioAudio.add_clip(audio, track_id(audio, 0), "sound:alarm.wav", 0, 100)
      [{_track, clip}] = StudioAudio.clips(audio)

      assert StudioAudio.move_clip(audio, clip.id, "no-such-track", 500) == audio
    end

    test "moving a clip that is not there changes nothing", %{audio: audio} do
      assert StudioAudio.move_clip(audio, "ghost", track_id(audio, 0), 100) == audio
    end

    test "duration is the furthest clip's far edge, across all tracks", %{audio: audio} do
      audio =
        audio
        |> StudioAudio.add_clip(track_id(audio, 0), "a", 0, 500)
        |> StudioAudio.add_clip(track_id(audio, 1), "b", 2_000, 750)

      assert StudioAudio.duration_ms(audio) == 2_750.0
      assert StudioAudio.duration_ms(StudioAudio.new("empty")) == 0.0
    end

    test "clip ids are unique across an audio", %{audio: audio} do
      audio =
        Enum.reduce(1..25, audio, fn _, a ->
          StudioAudio.add_clip(a, track_id(a, 0), "sound:alarm.wav", 0, 10)
        end)

      ids = audio |> StudioAudio.clips() |> Enum.map(fn {_t, c} -> c.id end)
      assert length(Enum.uniq(ids)) == 25
    end
  end

  describe "mute and solo" do
    setup do
      audio = StudioAudio.new("mix") |> StudioAudio.add_track()
      {:ok, audio: audio}
    end

    test "a fresh track is neither muted nor soloed", %{audio: audio} do
      assert Enum.all?(audio.tracks, &(not &1.muted and not &1.soloed))
    end

    test "toggles flip and flip back", %{audio: audio} do
      id = track_id(audio, 0)

      muted = StudioAudio.toggle_mute(audio, id)
      assert hd(muted.tracks).muted
      refute hd(StudioAudio.toggle_mute(muted, id).tracks).muted

      soloed = StudioAudio.toggle_solo(audio, id)
      assert hd(soloed.tracks).soloed
    end

    test "with no solo anywhere, mute is the whole story", %{audio: audio} do
      muted = StudioAudio.toggle_mute(audio, track_id(audio, 0))

      refute StudioAudio.audible?(muted, Enum.at(muted.tracks, 0))
      assert StudioAudio.audible?(muted, Enum.at(muted.tracks, 1))
    end

    test "one solo silences every unsoloed track", %{audio: audio} do
      soloed = StudioAudio.toggle_solo(audio, track_id(audio, 0))

      assert StudioAudio.audible?(soloed, Enum.at(soloed.tracks, 0))
      refute StudioAudio.audible?(soloed, Enum.at(soloed.tracks, 1))
    end

    test "solo beats mute on the same track", %{audio: audio} do
      id = track_id(audio, 0)
      both = audio |> StudioAudio.toggle_mute(id) |> StudioAudio.toggle_solo(id)

      # Engaging solo is the stronger, more recent statement of intent —
      # the Pro Tools and Logic resolution, i.e. what DAW fingers expect.
      assert StudioAudio.audible?(both, Enum.at(both.tracks, 0))
    end

    test "audible_clips is what a render mixes", %{audio: audio} do
      audio =
        audio
        |> StudioAudio.add_clip(track_id(audio, 0), "sound:a.wav", 0, 100)
        |> StudioAudio.add_clip(track_id(audio, 1), "sound:b.wav", 0, 100)

      muted = StudioAudio.toggle_mute(audio, track_id(audio, 1))

      assert [{_track, clip}] = StudioAudio.audible_clips(muted)
      assert clip.source == "sound:a.wav"
    end

    test "mute and solo survive the round trip to disk" do
      {:ok, name} = StudioAudio.create("flags")
      {:ok, audio} = StudioAudio.load(name)
      audio = StudioAudio.add_track(audio)

      audio =
        audio
        |> StudioAudio.toggle_mute(track_id(audio, 0))
        |> StudioAudio.toggle_solo(track_id(audio, 1))

      :ok = StudioAudio.save(audio)
      {:ok, reloaded} = StudioAudio.load(name)

      assert Enum.at(reloaded.tracks, 0).muted
      assert Enum.at(reloaded.tracks, 1).soloed
    end

    test "a hand-edited non-boolean flag is ignored, not honored", %{root: root} do
      {:ok, name} = StudioAudio.create("edited-flags")
      path = Path.join([root, "sounds", "studio", "tracks", name <> ".track.json"])

      # "yes" is a helpful human's boolean. Honoring truthiness would produce
      # a track the UI's boolean flip can never seem to unmute.
      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "name" => name,
          "lanes" => [%{"id" => "L1", "label" => "A", "muted" => "yes", "clips" => []}]
        })
      )

      assert {:ok, audio} = StudioAudio.load(name)
      refute hd(audio.tracks).muted
    end
  end

  describe "storage" do
    test "create/1 sanitizes the name and never collides" do
      assert {:ok, "my idea"} = StudioAudio.create("  my idea  ")
      assert {:ok, "my idea-2"} = StudioAudio.create("my idea")
      assert StudioAudio.list() == ["my idea", "my idea-2"]
    end

    test "create/1 refuses a name that reduces to nothing" do
      # An empty name would write `.track.json` — a dotfile the listing ignores,
      # so the audio would vanish the instant it was made.
      assert {:error, :invalid_name} = StudioAudio.create("   ")
      assert {:error, :invalid_name} = StudioAudio.create("///")
      assert StudioAudio.list() == []
    end

    test "a hostile name cannot escape the storage folder", %{root: root} do
      assert {:ok, name} = StudioAudio.create("../../etc/evil")
      refute name =~ "/"
      assert File.regular?(Path.join([root, "sounds", "studio", "tracks", name <> ".track.json"]))
    end

    test "an audio survives a round trip to disk" do
      {:ok, name} = StudioAudio.create("round")
      {:ok, audio} = StudioAudio.load(name)

      audio =
        audio
        |> StudioAudio.add_track()

      audio = StudioAudio.add_clip(audio, track_id(audio, 1), "import:cut.wav", 1_500, 300)
      :ok = StudioAudio.save(audio)

      {:ok, reloaded} = StudioAudio.load(name)
      assert [{track, clip}] = StudioAudio.clips(reloaded)
      assert track.label == "B"
      assert clip.source == "import:cut.wav"
      assert clip.start_ms == 1_500.0
      assert clip.duration_ms == 300.0
    end

    test "loading something that is not there reports rather than raises" do
      assert {:error, :not_found} = StudioAudio.load("nope")
      assert {:error, :not_found} = StudioAudio.delete("nope")
    end

    test "the v1 disk format still speaks the old vocabulary, and loads", %{root: root} do
      {:ok, name} = StudioAudio.create("edited")
      path = Path.join([root, "sounds", "studio", "tracks", name <> ".track.json"])

      # The serialization key is "lanes" — written before the vocabulary swap
      # and stable on purpose, because these files are in the operator's
      # workspace and may be hand-edited. One bad row must not make the audio
      # unopenable, and the old key must keep working forever.
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

      assert {:ok, audio} = StudioAudio.load(name)
      assert length(audio.tracks) == 2
      assert [{_track, clip}] = StudioAudio.clips(audio)
      assert clip.source == "sound:boot.wav"
      # A clip with no cached duration still loads; a render re-reads the source.
      assert clip.duration_ms == 0.0
    end

    test "a file with no rows at all opens with one track, not zero", %{root: root} do
      {:ok, name} = StudioAudio.create("bare")
      path = Path.join([root, "sounds", "studio", "tracks", name <> ".track.json"])
      File.write!(path, Jason.encode!(%{"version" => 1, "name" => name, "lanes" => []}))

      assert {:ok, audio} = StudioAudio.load(name)
      assert length(audio.tracks) == 1
    end

    test "audios do not show up as importable audio files" do
      {:ok, _name} = StudioAudio.create("quiet")
      # `.track.json` is not an audio extension, so the Imports group ignores it.
      assert BusterClaw.Notifications.SoundStudio.list() == []
    end
  end
end
