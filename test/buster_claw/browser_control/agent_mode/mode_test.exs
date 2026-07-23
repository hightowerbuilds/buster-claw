defmodule BusterClaw.BrowserControl.AgentMode.ModeTest do
  use ExUnit.Case, async: true

  alias BusterClaw.BrowserControl.AgentMode.Mode

  test "the happy path walks idle → working → awaiting → working → done" do
    assert {:ok, :agent_working} = Mode.transition(:idle, :start)
    assert {:ok, :awaiting_human} = Mode.transition(:agent_working, :need_human)
    assert {:ok, :agent_working} = Mode.transition(:awaiting_human, :resume)
    assert {:ok, :done} = Mode.transition(:agent_working, :complete)
  end

  test "take-the-wheel and stop reach non-acting states" do
    assert {:ok, :awaiting_human} = Mode.transition(:agent_working, :take_wheel)
    assert {:ok, :stopped} = Mode.transition(:agent_working, :stop)
    assert {:ok, :stopped} = Mode.transition(:awaiting_human, :stop)
    assert {:ok, :halted} = Mode.transition(:agent_working, :halt)
  end

  test "only agent_working permits acting" do
    assert Mode.acting_allowed?(:agent_working)

    for m <- [:idle, :awaiting_human, :done, :stopped, :halted] do
      refute Mode.acting_allowed?(m), "#{m} must not allow acting"
    end
  end

  test "terminal states are terminal and take no transition" do
    for m <- [:done, :stopped, :halted] do
      assert Mode.terminal?(m)

      for e <- [:start, :resume, :need_human, :complete, :stop] do
        assert {:error, :invalid_transition} = Mode.transition(m, e)
      end
    end
  end

  test "illegal pairs are always errors, never silent" do
    assert {:error, :invalid_transition} = Mode.transition(:idle, :complete)
    assert {:error, :invalid_transition} = Mode.transition(:idle, :resume)
    assert {:error, :invalid_transition} = Mode.transition(:agent_working, :start)
    assert {:error, :invalid_transition} = Mode.transition(:awaiting_human, :complete)
  end
end
