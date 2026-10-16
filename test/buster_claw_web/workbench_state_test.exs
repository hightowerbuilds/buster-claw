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
    assert State.arrange(two, "pairs") == two
    refute Enum.find(State.payload(two).layouts, &(&1.key == "grid")).enabled
    refute Enum.find(State.payload(two).layouts, &(&1.key == "pairs")).enabled

    three = two |> State.open("clock") |> State.arrange("grid")
    assert three.tree["first"] == "chat"
    assert three.tree["second"]["axis"] == "vertical"
    assert State.leaves(three.tree["second"]) == ["workspace", "clock"]
    assert State.arrange(three, "invalid") == three
  end

  test "every preset preserves every open panel and focus, and round-trips, for two through eight panels" do
    for count <- 2..8, preset <- ["columns", "rows", "grid", "pairs"] do
      keys = Enum.take(State.keys(), count)
      state = Enum.reduce(keys, State.new(), &State.open(&2, &1)) |> State.zoom("chat")
      arranged = State.arrange(state, preset)
      assert State.leaves(arranged.tree) == keys
      assert arranged.active == "chat"
      assert arranged |> Jason.encode!() |> Jason.decode!() |> State.restore() == arranged
      preview = Enum.find(State.payload(state).layouts, &(&1.key == preset))

      available =
        case preset do
          "pairs" -> count >= 4
          "grid" -> count >= 3
          _linear -> count <= 3
        end

      if available do
        assert arranged.zoom == nil
        assert preview.enabled
        assert preview.tree == arranged.tree
      else
        assert arranged == state
        refute preview.enabled
        assert is_binary(preview.hint)
      end
    end
  end

  test "four panels become two columns of two, five become three columns with two stacked" do
    open = fn n -> Enum.reduce(Enum.take(State.keys(), n), State.new(), &State.open(&2, &1)) end

    four = open.(4)
    assert four.preset == "pairs"
    assert four.tree["axis"] == "horizontal"
    assert four.tree["first"]["axis"] == "vertical"
    assert State.leaves(four.tree["first"]) == ["chat", "workspace"]
    assert State.leaves(four.tree["second"]) == ["terminal", "pockets"]

    five = open.(5)
    assert State.leaves(five.tree["first"]) == ["chat", "workspace"]
    assert five.tree["second"]["axis"] == "horizontal"
    assert State.leaves(five.tree["second"]["first"]) == ["terminal", "pockets"]
    assert five.tree["second"]["second"] == "phone"

    # Stacked holds three; the fourth panel moves the work area to pairs on its
    # own, the picker refuses a row of four, and closing back to three returns
    # to side by side.
    stacked =
      State.new() |> State.open("workspace") |> State.arrange("rows") |> State.open("clock")

    assert stacked.preset == "rows"
    fourth = State.open(stacked, "terminal")
    assert fourth.preset == "pairs"
    assert State.arrange(fourth, "rows") == fourth
    assert State.arrange(fourth, "columns") == fourth
    refute Enum.find(State.payload(fourth).layouts, &(&1.key == "rows")).enabled
    back = State.close(fourth, "clock")
    assert back.preset == "columns"
    assert back.tree["axis"] == "horizontal"
  end

  test "legacy saved divider positions survive until an arrangement is selected" do
    tree = %{"axis" => "vertical", "ratio" => 0.7, "first" => "chat", "second" => "clock"}
    state = State.restore(%{"tree" => tree, "active" => "clock", "direction" => "vertical"})
    assert state.tree == tree
    assert state.preset == nil
    assert State.arrange(state, "columns").tree["axis"] == "horizontal"
  end

  test "terminal slots: the lowest free slot is reused, a fifth is refused, a gap restores" do
    {:ok, one} = State.open_terminal(State.new())
    assert State.leaves(one.tree) == ["chat", "terminal"]
    assert one.active == "terminal"
    {:ok, two} = State.open_terminal(one)
    {:ok, three} = State.open_terminal(two)
    assert State.leaves(three.tree) == ["chat", "terminal", "terminal-2", "terminal-3"]
    assert State.terminal_count(three) == 3

    {:ok, reopened} = three |> State.close("terminal-2") |> State.open_terminal()
    assert State.leaves(reopened.tree) == ["chat", "terminal", "terminal-3", "terminal-2"]

    {:ok, four} = State.open_terminal(three)
    assert State.terminal_count(four) == 4
    assert State.open_terminal(four) == {:error, :limit}
    assert State.payload(four).terminal_count == 4
    assert State.payload(four).terminal_limit == 4

    gap = %{
      "tree" => %{
        "axis" => "horizontal",
        "ratio" => 0.5,
        "first" => "chat",
        "second" => "terminal-3"
      }
    }

    assert State.leaves(State.restore(gap).tree) == ["chat", "terminal-3"]
    assert State.restore(%{"tree" => "terminal-5"}) == State.new()

    assert State.session_key("terminal") == "workbench"
    assert State.session_key("terminal-4") == "workbench-4"
    assert State.label("terminal") == "Terminal"
    assert State.label("terminal-2") == "Terminal 2"
    assert State.label("clock") == "Clock"
    refute "terminal-2" in Enum.map(State.panels(), & &1.key)
  end

  test "reordering keeps the arrangement's shape and only moves panels; junk is ignored" do
    four = Enum.reduce(["workspace", "terminal", "clock"], State.new(), &State.open(&2, &1))
    moved = State.reorder(four, ["clock", "chat", "workspace", "terminal"])
    assert State.leaves(moved.tree) == ["clock", "chat", "workspace", "terminal"]
    assert moved.preset == four.preset
    assert State.leaves(moved.tree["first"]) == ["clock", "chat"]
    assert moved.active == four.active

    legacy =
      State.restore(%{
        "tree" => %{"axis" => "vertical", "ratio" => 0.7, "first" => "chat", "second" => "clock"},
        "active" => "clock"
      })

    swapped = State.reorder(legacy, ["clock", "chat"])
    assert swapped.preset == nil
    assert swapped.tree == %{legacy.tree | "first" => "clock", "second" => "chat"}
    assert swapped.tree["ratio"] == 0.7

    for junk <- [["chat"], ["chat", "clock", "clock"], ["chat", "phone"], "chat", nil, []] do
      assert State.reorder(legacy, junk) == legacy
    end

    assert State.reorder(four, State.leaves(four.tree)) == four
  end
end
