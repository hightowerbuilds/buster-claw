defmodule BusterClaw.Notifications.StudioTrackTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Notifications.StudioTrack

  setup do
    root = Path.join(System.tmp_dir!(), "bc_track_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp lane_id(track, index), do: Enum.at(track.lanes, index).id

  describe "shape" do
    test "a new track opens with one lane, not zero" do
      track = StudioTrack.new("idea")

      # Zero lanes is a surface with nothing to drop onto.
      assert length(track.lanes) == 1
      assert hd(track.lanes).label == "A"
      assert hd(track.lanes).clips == []
    end

    test "lanes are labelled A, B, C… and capped" do
      track = Enum.reduce(1..20, StudioTrack.new("idea"), fn _, t -> StudioTrack.add_lane(t) end)

      assert length(track.lanes) == StudioTrack.max_lanes()
      assert Enum.map(track.lanes, & &1.label) |> Enum.take(3) == ["A", "B", "C"]
    end

    test "the last lane cannot be removed" do
      track = StudioTrack.new("idea")
      assert StudioTrack.remove_lane(track, lane_id(track, 0)).lanes == track.lanes
    end

    test "removing a lane takes its clips with it" do
      track =
        StudioTrack.new("idea")
        |> StudioTrack.add_lane()

      track = StudioTrack.add_clip(track, lane_id(track, 1), "sound:alarm.wav", 0, 100)
      assert length(StudioTrack.clips(track)) == 1

      track = StudioTrack.remove_lane(track, lane_id(track, 1))
      assert StudioTrack.clips(track) == []
    end
  end

  describe "clips" do
    setup do
      track = StudioTrack.new("idea") |> StudioTrack.add_lane()
      {:ok, track: track}
    end

    test "a clip lands where it was placed", %{track: track} do
      track = StudioTrack.add_clip(track, lane_id(track, 0), "sound:alarm.wav", 250, 1320)

      assert [{lane, clip}] = StudioTrack.clips(track)
      assert lane.label == "A"
      assert clip.start_ms == 250.0
      assert clip.duration_ms == 1320.0
      assert clip.source == "sound:alarm.wav"
    end

    test "a negative offset clamps to the start of the ruler", %{track: track} do
      track = StudioTrack.add_clip(track, lane_id(track, 0), "sound:alarm.wav", -500, 100)
      assert [{_lane, clip}] = StudioTrack.clips(track)
      assert clip.start_ms == 0.0
    end

    test "moving across lanes leaves exactly ONE copy", %{track: track} do
      track = StudioTrack.add_clip(track, lane_id(track, 0), "sound:alarm.wav", 0, 100)
      [{_lane, clip}] = StudioTrack.clips(track)

      moved = StudioTrack.move_clip(track, clip.id, lane_id(track, 1), 900)

      # A cross-lane move is a removal plus an insertion; doing it as one
      # mutation is how a clip ends up on two lanes at once.
      assert [{lane, one}] = StudioTrack.clips(moved)
      assert lane.label == "B"
      assert one.start_ms == 900.0
      assert one.id == clip.id
    end

    test "a move onto an unknown lane is refused, not a dropped clip", %{track: track} do
      track = StudioTrack.add_clip(track, lane_id(track, 0), "sound:alarm.wav", 0, 100)
      [{_lane, clip}] = StudioTrack.clips(track)

      assert StudioTrack.move_clip(track, clip.id, "no-such-lane", 500) == track
    end

    test "moving a clip that is not there changes nothing", %{track: track} do
      assert StudioTrack.move_clip(track, "ghost", lane_id(track, 0), 100) == track
    end

    test "duration is the furthest clip's far edge, across all lanes", %{track: track} do
      track =
        track
        |> StudioTrack.add_clip(lane_id(track, 0), "a", 0, 500)
        |> StudioTrack.add_clip(lane_id(track, 1), "b", 2_000, 750)

      assert StudioTrack.duration_ms(track) == 2_750.0
      assert StudioTrack.duration_ms(StudioTrack.new("empty")) == 0.0
    end

    test "clip ids are unique across a track", %{track: track} do
      track =
        Enum.reduce(1..25, track, fn _, t ->
          StudioTrack.add_clip(t, lane_id(t, 0), "sound:alarm.wav", 0, 10)
        end)

      ids = track |> StudioTrack.clips() |> Enum.map(fn {_l, c} -> c.id end)
      assert length(Enum.uniq(ids)) == 25
    end
  end

  describe "storage" do
    test "create/1 sanitizes the name and never collides" do
      assert {:ok, "my idea"} = StudioTrack.create("  my idea  ")
      assert {:ok, "my idea-2"} = StudioTrack.create("my idea")
      assert StudioTrack.list() == ["my idea", "my idea-2"]
    end

    test "create/1 refuses a name that reduces to nothing" do
      # An empty name would write `.track.json` — a dotfile the listing ignores,
      # so the track would vanish the instant it was made.
      assert {:error, :invalid_name} = StudioTrack.create("   ")
      assert {:error, :invalid_name} = StudioTrack.create("///")
      assert StudioTrack.list() == []
    end

    test "a hostile name cannot escape the tracks folder", %{root: root} do
      assert {:ok, name} = StudioTrack.create("../../etc/evil")
      refute name =~ "/"
      assert File.regular?(Path.join([root, "studio", "tracks", name <> ".track.json"]))
    end

    test "a track survives a round trip to disk" do
      {:ok, name} = StudioTrack.create("round")
      {:ok, track} = StudioTrack.load(name)

      track =
        track
        |> StudioTrack.add_lane()

      track = StudioTrack.add_clip(track, lane_id(track, 1), "import:cut.wav", 1_500, 300)
      :ok = StudioTrack.save(track)

      {:ok, reloaded} = StudioTrack.load(name)
      assert [{lane, clip}] = StudioTrack.clips(reloaded)
      assert lane.label == "B"
      assert clip.source == "import:cut.wav"
      assert clip.start_ms == 1_500.0
      assert clip.duration_ms == 300.0
    end

    test "loading something that is not there reports rather than raises" do
      assert {:error, :not_found} = StudioTrack.load("nope")
      assert {:error, :not_found} = StudioTrack.delete("nope")
    end

    test "a hand-edited file with a broken lane still opens", %{root: root} do
      {:ok, name} = StudioTrack.create("edited")
      path = Path.join([root, "studio", "tracks", name <> ".track.json"])

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

      # This file lives in the operator's workspace and they are invited to edit
      # it — one bad lane must not make the track unopenable.
      assert {:ok, track} = StudioTrack.load(name)
      assert length(track.lanes) == 2
      assert [{_lane, clip}] = StudioTrack.clips(track)
      assert clip.source == "sound:boot.wav"
      # A clip with no cached duration still loads; a render re-reads the source.
      assert clip.duration_ms == 0.0
    end

    test "a file with no lanes at all opens with one, not zero", %{root: root} do
      {:ok, name} = StudioTrack.create("bare")
      path = Path.join([root, "studio", "tracks", name <> ".track.json"])
      File.write!(path, Jason.encode!(%{"version" => 1, "name" => name, "lanes" => []}))

      assert {:ok, track} = StudioTrack.load(name)
      assert length(track.lanes) == 1
    end

    test "tracks do not show up as importable audio" do
      {:ok, _name} = StudioTrack.create("quiet")
      # `.track.json` is not an audio extension, so the Imports group ignores it.
      assert BusterClaw.Notifications.SoundStudio.list() == []
    end
  end
end
