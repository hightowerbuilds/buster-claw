defmodule BusterClaw.BrowserControl.AgentModeTest do
  @moduledoc """
  The Agent Mode orchestrator, driven with stubs — no browser. Proves the
  load-bearing safety properties: only agent_working acts, stop halts before the
  next action, the scope gate halts the run, and secrets resolve in the executor
  while the trajectory stores only the masked form.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.BrowserControl.AgentMode
  alias BusterClaw.BrowserControl.AgentMode.Trajectory
  alias BusterClaw.BrowserControl.Scope

  # Stands in for BrowserControl (navigate/3) — scripted per URL host.
  defmodule StubNav do
    def navigate(_session, %Scope{} = scope, url) do
      cond do
        String.contains?(url, "evil.com") ->
          {:halt, :out_of_scope, %{url: url, host: "evil.com"}}

        String.contains?(url, "checkout") ->
          {:halt, :payment_stop, %{url: url, host: "example.com"}}

        true ->
          {:ok, %{scope_id: scope.id, intent: scope.intent, host: "example.com", url: url}}
      end
    end
  end

  # Stands in for Session — records DOM.setValue values the executor sends.
  defmodule RecordingSession do
    use Agent
    def start_link, do: Agent.start_link(fn -> [] end)

    def command(pid, "DOM.setValue", %{"value" => v}),
      do: Agent.update(pid, &[v | &1]) && {:ok, %{}}

    def values(pid), do: Agent.get(pid, &Enum.reverse(&1))
  end

  defp start(opts \\ []) do
    scope = Scope.new("buy paper", ["example.com"], id: "run1")
    {:ok, sess} = RecordingSession.start_link()

    {:ok, pid} =
      AgentMode.start_link(
        Keyword.merge(
          [
            scope: scope,
            session: sess,
            session_mod: RecordingSession,
            navigate_mod: StubNav,
            secret_resolver: fn
              "card" -> {:ok, "4242424242424242"}
              _ -> :error
            end,
            clock: fn -> 0 end
          ],
          opts
        )
      )

    {pid, sess}
  end

  test "starts idle and refuses to act before start_run" do
    {pid, _} = start()
    assert AgentMode.mode(pid) == :idle
    assert {:error, {:not_acting, :idle}} = AgentMode.navigate(pid, "https://example.com/")
  end

  test "start_run enters agent_working, then an in-scope navigation is recorded" do
    {pid, _} = start()
    assert {:ok, :agent_working} = AgentMode.start_run(pid)
    assert {:ok, origin} = AgentMode.navigate(pid, "https://example.com/products")
    assert origin.host == "example.com"

    step = AgentMode.trajectory(pid) |> Trajectory.last()
    assert step.type == :navigate
    assert step.outcome == :ok
  end

  test "an out-of-scope navigation halts the run and records a halt step" do
    {pid, _} = start()
    AgentMode.start_run(pid)

    assert {:halt, :out_of_scope, _} = AgentMode.navigate(pid, "https://evil.com/")
    assert AgentMode.mode(pid) == :halted

    step = AgentMode.trajectory(pid) |> Trajectory.last()
    assert step.type == :halt
    assert step.outcome == :halted
    # Halted is terminal — no further acting.
    assert {:error, {:not_acting, :halted}} = AgentMode.navigate(pid, "https://example.com/")
  end

  test "a payment URL halts the run (the Phase 5 handoff boundary)" do
    {pid, _} = start()
    AgentMode.start_run(pid)
    assert {:halt, :payment_stop, _} = AgentMode.navigate(pid, "https://example.com/checkout")
    assert AgentMode.mode(pid) == :halted
  end

  test "stop halts before the next action" do
    {pid, _} = start()
    AgentMode.start_run(pid)
    assert {:ok, :stopped} = AgentMode.stop_run(pid)
    assert {:error, {:not_acting, :stopped}} = AgentMode.navigate(pid, "https://example.com/")
    assert {:error, {:not_acting, :stopped}} = AgentMode.act(pid, :click, %{"selector" => "#x"})
  end

  test "take-the-wheel stops the agent; resume gives it back" do
    {pid, _} = start()
    AgentMode.start_run(pid)
    assert {:ok, :awaiting_human} = AgentMode.take_wheel(pid)

    assert {:error, {:not_acting, :awaiting_human}} =
             AgentMode.navigate(pid, "https://example.com/")

    assert {:ok, :agent_working} = AgentMode.resume(pid)
    assert {:ok, _} = AgentMode.navigate(pid, "https://example.com/ok")
  end

  test "fill resolves a secret in the executor but the trajectory stores only the reference" do
    {pid, sess} = start()
    AgentMode.start_run(pid)

    assert {:ok, _} =
             AgentMode.act(pid, :fill, %{"selector" => "#card", "value" => "$secret.card"})

    # The browser (executor) received the resolved value...
    assert RecordingSession.values(sess) == ["4242424242424242"]

    # ...but the trajectory shows only the masked reference, never the number.
    step = AgentMode.trajectory(pid) |> Trajectory.last()
    assert step.summary =~ "⟨secret:card⟩"
    refute step.summary =~ "4242"
  end

  test "an unresolved secret fails the fill without touching the browser" do
    {pid, sess} = start()
    AgentMode.start_run(pid)

    assert {:error, {:unknown_secret, "unknown"}} =
             AgentMode.act(pid, :fill, %{"selector" => "#x", "value" => "$secret.unknown"})

    assert RecordingSession.values(sess) == []
    assert AgentMode.trajectory(pid) |> Trajectory.last() |> Map.get(:outcome) == :error
  end

  test "subscribers see mode transitions and steps" do
    {pid, _} = start()
    :ok = AgentMode.subscribe(pid)

    AgentMode.start_run(pid)
    assert_receive {:agent_mode, "run1", {:mode_changed, :agent_working}}, 500

    AgentMode.navigate(pid, "https://example.com/x")
    assert_receive {:agent_mode, "run1", {:step, %{type: :navigate}}}, 500
  end

  test "the run summary reflects the recorded steps" do
    {pid, _} = start()
    AgentMode.start_run(pid)
    AgentMode.navigate(pid, "https://example.com/a")
    AgentMode.act(pid, :click, %{"selector" => "#go"})

    summary = AgentMode.summary(pid)
    assert summary.steps == 2
    assert summary.outcomes[:ok] == 2
  end
end
