defmodule BusterClaw.Browser.ActivityCaptureTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Browser.{Activity, Bridge}
  alias BusterClaw.BrowserControl.{AgentMode, Scope}

  setup do
    previous = Application.get_env(:buster_claw, :browser_activity_enabled)
    Application.put_env(:buster_claw, :browser_activity_enabled, true)
    on_exit(fn -> Application.put_env(:buster_claw, :browser_activity_enabled, previous) end)
    :ok
  end

  test "shared browser records actual results without changing the command reply" do
    Bridge.subscribe()
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         result = Bridge.request(:fill, %{"selector" => "#password", "value" => "keep-private"})
         send(parent, {:result, result})
       end}
    )

    assert_receive {:browser_command, ref, :fill, _}, 1_000
    result = {:ok, %{data: Jason.encode!(%{ok: false, error: "not fillable"})}}
    Bridge.fulfill(ref, result, %{"url" => "https://example.com/login?private=true"})
    assert_receive {:result, ^result}, 1_000
    assert [event] = Activity.snapshot().events
    assert event.action == "fill"
    assert event.outcome == "error"
    assert event.url == "https://example.com/login"
    assert event.duration_ms >= 0
    refute Jason.encode!(event) =~ "keep-private"
    refute Jason.encode!(event) =~ "password"
  end

  test "an unanswered shared browser request records its failure" do
    assert {:error, :browser_timeout} = Bridge.request(:read, %{}, timeout_ms: 1)
    assert [%{action: "read", outcome: "error", url: nil}] = Activity.snapshot().events
  end

  test "Agent Mode lifecycle is durable and independent of the in-memory trajectory" do
    scope = Scope.new("read a page", ["example.com"], id: "activity-run")
    run = start_supervised!({AgentMode, scope: scope, session: :unused})
    assert {:ok, :agent_working} = AgentMode.start_run(run)
    assert {:ok, :stopped} = AgentMode.stop_run(run)
    stop_supervised!(AgentMode)

    assert [%{action: "start", run_id: "activity-run"}, %{action: "stop", outcome: "stopped"}] =
             Activity.snapshot(%{"source" => "agent"}).events
  end

  test "Agent Mode steps never persist a fill summary" do
    step = %{type: :fill, outcome: :ok, summary: "fill password = keep-private"}
    Activity.capture_agent("run-secret", step, "https://example.com/login")
    assert [event] = Activity.snapshot().events
    assert event.source == "agent"
    refute Jason.encode!(event) =~ "keep-private"
  end
end
