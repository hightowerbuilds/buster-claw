defmodule BusterClawWeb.WorkbenchStateTest do
  use ExUnit.Case, async: true
  alias BusterClawWeb.WorkbenchState, as: State

  test "new panels follow the selected arrangement and existing panels only gain focus" do
    state =
      State.new() |> State.open("terminal") |> State.arrange("rows") |> State.open("clock")

    assert state.tree["axis"] == "vertical"
    assert state.tree["second"]["axis"] == "vertical"
    assert State.leaves(state.tree) == ["chat", "terminal", "clock"]
    assert State.open(state, "chat").tree == state.tree
    assert State.open(state, "chat").active == "chat"
  end

  test "hiding collapses the partition and leaves the neighboring panes intact" do
    state = State.new() |> State.open("terminal") |> State.open("workspace")
    closed = State.close(state, "terminal")
    assert State.leaves(closed.tree) == ["chat", "workspace"]
    assert closed.active == "workspace"
    empty = closed |> State.close("workspace") |> State.close("chat")
    assert empty.tree == nil
    assert State.open(empty, "clock").tree == "clock"
  end

  test "zoom preserves layout and opening another pane restores the split" do
    state = State.new() |> State.open("workspace")
    assert State.zoom(state, "chat").tree == state.tree
    assert state |> State.zoom("chat") |> State.zoom("chat") |> Map.get(:zoom) == nil
    assert state |> State.zoom("chat") |> State.open("terminal") |> Map.get(:zoom) == nil
  end

  test "saved layouts round-trip and reject unknown, repeated, or deeply nested panels" do
    state = Enum.reduce(State.keys(), State.new(), &State.open(&2, &1))
    assert state |> Jason.encode!() |> Jason.decode!() |> State.restore() == state
    invalid = %{"axis" => "horizontal", "ratio" => 0.5, "first" => "chat", "second" => "chat"}
    assert State.restore(%{"tree" => invalid}) == State.new()
    assert State.restore(%{"tree" => "browser"}) == State.new()
    assert State.restore(%{"tree" => %{"first" => nil}}) == State.new()
    nested = Enum.reduce(1..20, "chat", fn _, node -> Map.put(invalid, "second", node) end)
    assert State.restore(%{"tree" => nested}) == State.new()
  end

  test "resize targets one partition, clamps ratios, and ignores forged paths" do
    state = State.new() |> State.open("terminal") |> State.open("clock")
    resized = State.resize(state, ["second"], 0.7)
    assert resized.tree["ratio"] == state.tree["ratio"]
    assert resized.tree["second"]["ratio"] == 0.7
    assert State.resize(state, [], 100).tree["ratio"] == 0.85
    assert State.resize(state, ["unknown"], 0.7) == state
    assert State.resize(state, [], "invalid") == state
  end

  test "two panels offer columns or rows and three add a main pane beside a stack" do
    two = State.new() |> State.open("workspace")
    assert State.arrange(two, "columns").tree["axis"] == "horizontal"
    assert State.arrange(two, "rows").tree["axis"] == "vertical"
    assert State.arrange(two, "grid") == two
    refute Enum.find(State.payload(two).layouts, &(&1.key == "grid")).enabled

    three = two |> State.open("clock") |> State.arrange("grid")
    assert three.tree["first"] == "chat"
    assert three.tree["second"]["axis"] == "vertical"
    assert State.leaves(three.tree["second"]) == ["workspace", "clock"]
    assert State.arrange(three, "invalid") == three
  end

  test "all presets preserve every open panel, focus, and round-trip for two through eight panels" do
    for count <- 2..8, preset <- ["columns", "rows", "grid"] do
      keys = Enum.take(State.keys(), count)
      state = Enum.reduce(keys, State.new(), &State.open(&2, &1)) |> State.zoom("chat")
      arranged = State.arrange(state, preset)
      assert State.leaves(arranged.tree) == keys
      assert arranged.active == "chat"
      assert arranged |> Jason.encode!() |> Jason.decode!() |> State.restore() == arranged

      if preset != "grid" or count >= 3 do
        assert arranged.zoom == nil
        preview = Enum.find(State.payload(state).layouts, &(&1.key == preset))
        assert preview.enabled
        assert preview.tree == arranged.tree
      end
    end
  end

  test "legacy saved divider positions survive until an arrangement is selected" do
    tree = %{"axis" => "vertical", "ratio" => 0.7, "first" => "chat", "second" => "clock"}
    state = State.restore(%{"tree" => tree, "active" => "clock", "direction" => "vertical"})
    assert state.tree == tree
    assert state.preset == nil
    assert State.arrange(state, "columns").tree["axis"] == "horizontal"
  end
end
