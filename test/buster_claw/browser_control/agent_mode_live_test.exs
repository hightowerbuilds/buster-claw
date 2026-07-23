defmodule BusterClaw.BrowserControl.AgentModeLiveTest do
  @moduledoc """
  Agent Mode driving a REAL session end to end — launches Chromium. The default
  `navigate_mod` (BrowserControl) and a real leased session, so the scope gate,
  the trajectory, and the mode machine all run against a live engine.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl.{AgentMode, Pool, Scope}
  alias BusterClaw.BrowserControl.AgentMode.Trajectory

  @moduletag :browser_engine
  @moduletag timeout: 90_000

  test "a real run navigates in scope, records it, and halts out of scope" do
    {:ok, pool} = Pool.start_link(name: nil, max_sessions: 1, idle_ms: 60_000)
    {:ok, session} = Pool.checkout(pool)

    scope = Scope.new("read example", ["example.com"], id: "live-run")

    {:ok, run} =
      AgentMode.start_link(scope: scope, session: session, clock: fn -> 0 end)

    assert {:ok, :agent_working} = AgentMode.start_run(run)

    # In scope: the real engine navigates and the step is recorded ok.
    assert {:ok, _origin} = AgentMode.navigate(run, "https://example.com/")
    assert AgentMode.mode(run) == :agent_working
    assert Trajectory.last(AgentMode.trajectory(run)).type == :navigate

    # Out of scope: the run halts and stops acting.
    assert {:halt, :out_of_scope, _} = AgentMode.navigate(run, "https://evil.example.org/")
    assert AgentMode.mode(run) == :halted
    assert {:error, {:not_acting, :halted}} = AgentMode.navigate(run, "https://example.com/again")

    summary = AgentMode.summary(run)
    assert summary.steps == 2
    assert summary.outcomes[:halted] == 1
  end
end
