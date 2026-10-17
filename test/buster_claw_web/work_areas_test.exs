defmodule BusterClawWeb.WorkAreasTest do
  use ExUnit.Case, async: true
  alias BusterClawWeb.WorkAreas, as: Areas
  alias BusterClawWeb.WorkbenchState, as: Grid

  test "four panels per area, numbered overflow, singleton focus, and space stays with its area" do
    four = Enum.reduce(["workspace", "notes", "calendar"], Areas.new(), &Areas.open(&2, &1))
    five = Areas.open(four, "clock")
    assert length(five.areas) == 2
    assert Areas.current(five).id == "area-2"
    assert Areas.label(Areas.current(five)) == "Work Area 2"
    assert Grid.leaves(Areas.current(five).tree) == ["clock"]
    assert Grid.leaves(hd(five.areas).tree) == ["chat", "workspace", "notes", "calendar"]
    notes = Areas.open(five, "notes")
    assert length(notes.areas) == 2
    assert Areas.current(notes).id == "area-1"
    assert Areas.current(notes).active == "notes"
    reopened = notes |> Areas.close("workspace") |> Areas.open("workspace")
    assert length(reopened.areas) == 2
    assert length(Grid.leaves(Areas.current(reopened).tree)) == 4
  end

  test "nine terminals get independent keys across three areas and names never recycle" do
    state =
      Enum.reduce(1..9, Areas.close(Areas.new(), "chat"), fn _, state ->
        {:ok, state} = Areas.open_terminal(state)
        state
      end)

    assert Enum.map(state.areas, &length(Grid.leaves(&1.tree))) == [4, 4, 1]
    assert length(Enum.uniq(Enum.map(Areas.terminals(state), &Grid.session_key/1))) == 9
    assert Areas.current(state).id == "area-3"
    closed = Areas.close_area(state, "area-2")
    assert Areas.current(closed).id == "area-3"
    assert Areas.close_area(closed, "area-1") == closed

    state =
      Enum.reduce(1..4, closed, fn _, acc ->
        {:ok, next} = Areas.open_terminal(acc)
        next
      end)

    assert Areas.current(state).id == "area-4"
    assert Areas.current(state).active == "terminal-13"
  end

  test "mode and frames belong to an area and stale gestures cannot move another area" do
    state = Areas.new() |> Areas.open("notes") |> Areas.mode("overlap")
    grid = Areas.current(state).tree

    params = %{
      "key" => "notes",
      "area_id" => "area-1",
      "revision" => state.revision,
      "frame" => %{"x" => 0.2, "y" => 0.1, "width" => 0.6, "height" => 0.7}
    }

    moved = Areas.move(state, params)
    assert Areas.current(moved).frames["notes"]["x"] == 0.2
    assert Areas.current(moved).tree == grid
    assert Areas.move(moved, params) == moved
    roundtrip = moved |> Areas.mode("grid") |> Areas.mode("overlap")
    assert Areas.current(roundtrip).frames == Areas.current(moved).frames
    assert Areas.current(roundtrip).tree == grid
    overflow = Enum.reduce(["clock", "calendar", "workspace"], roundtrip, &Areas.open(&2, &1))
    assert Areas.current(overflow).mode == "overlap"
    assert Areas.current(Areas.mode(overflow, "grid")).id == "area-2"
    assert hd(Areas.mode(overflow, "grid").areas).mode == "overlap"
    assert Areas.move(overflow, %{params | "revision" => overflow.revision}) == overflow
  end

  test "legacy migration preserves small trees and partitions larger trees without changing terminal keys" do
    small = %{
      "tree" => %{"axis" => "vertical", "ratio" => 0.7, "first" => "chat", "second" => "notes"}
    }

    assert Areas.current(Areas.restore(small)).tree == small["tree"]

    legacy =
      Enum.reduce(
        ["workspace", "notes", "calendar", "terminal", "terminal-2"],
        Grid.new(),
        &Grid.open(&2, &1)
      )

    legacy = Grid.zoom(legacy, "terminal-2") |> Jason.encode!() |> Jason.decode!()
    migrated = Areas.restore(legacy)
    assert Enum.map(migrated.areas, &length(Grid.leaves(&1.tree))) == [4, 2]
    assert Areas.current(migrated).zoom == "terminal-2"
    assert Areas.terminals(migrated) == ["terminal", "terminal-2"]
    assert migrated.next_terminal_number == 3
    assert migrated |> Jason.encode!() |> Jason.decode!() |> Areas.restore() == migrated
  end

  test "restore validates duplicate ownership, IDs, mode, frames and counters" do
    {:ok, state} = Areas.open_terminal(Areas.new())
    saved = state |> Jason.encode!() |> Jason.decode!()
    [area] = saved["areas"]
    bad = %{saved | "areas" => [area, %{area | "number" => 2, "id" => "area-2"}]}
    assert Areas.restore(bad) == Areas.new()

    clamped = %{
      area
      | "mode" => "unknown",
        "frames" => %{"terminal" => %{"x" => -3, "y" => 8, "width" => 0.5, "height" => 0.5}}
    }

    restored = Areas.restore(%{saved | "areas" => [clamped], "next_terminal_number" => 1})
    assert restored.next_terminal_number == 2
    assert Areas.current(restored).mode == "grid"

    assert Areas.current(restored).frames["terminal"] == %{
             "x" => 0.0,
             "y" => 0.5,
             "width" => 0.5,
             "height" => 0.5
           }

    for bad <- [nil, %{}, %{"version" => 99}, %{"version" => 2, "areas" => []}] do
      assert Areas.restore(bad) == Areas.new()
    end
  end

  test "legacy restore cannot exceed the collection capacity" do
    legacy =
      Enum.reduce(2..257, Grid.open(Grid.new(), "terminal"), fn n, state ->
        Grid.open(state, "terminal-#{n}") |> Grid.arrange("grid")
      end)

    saved = legacy |> Jason.encode!() |> Jason.decode!()
    assert length(Grid.leaves(Grid.restore(saved).tree)) == 258
    assert Areas.restore(saved) == Areas.new()
  end
end
