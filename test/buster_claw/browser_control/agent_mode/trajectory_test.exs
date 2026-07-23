defmodule BusterClaw.BrowserControl.AgentMode.TrajectoryTest do
  use ExUnit.Case, async: true

  alias BusterClaw.BrowserControl.AgentMode.Trajectory
  alias BusterClaw.BrowserControl.Egress.Report

  test "steps are appended with monotonic seqs and read back oldest-first" do
    t =
      Trajectory.new()
      |> Trajectory.step(%{type: :navigate, summary: "a"})
      |> Trajectory.step(%{type: :click, summary: "b"})

    steps = Trajectory.steps(t)
    assert Enum.map(steps, & &1.seq) == [0, 1]
    assert Enum.map(steps, & &1.summary) == ["a", "b"]
    assert Trajectory.last(t).summary == "b"
  end

  test "redaction at capture: a secret reference in a summary is masked before storage" do
    t = Trajectory.step(Trajectory.new(), %{type: :fill, summary: "fill #card = $secret.card"})
    assert Trajectory.last(t).summary == "fill #card = ⟨secret:card⟩"
  end

  test "redaction at capture: a literal card in a summary is redacted before storage" do
    t = Trajectory.step(Trajectory.new(), %{type: :fill, summary: "typed 4242424242424242"})
    assert Trajectory.last(t).summary =~ "⟨redacted:card⟩"
    refute Trajectory.last(t).summary =~ "4242"
  end

  test "a step carries its motivating origin" do
    origin = %{scope_id: "s1", intent: "buy paper", host: "example.com"}
    t = Trajectory.step(Trajectory.new(), %{type: :navigate, summary: "go", origin: origin})
    assert Trajectory.last(t).origin == origin
  end

  test "summary rolls up steps, egress, and outcomes" do
    report = %Report{
      host: "example.com",
      level: :full,
      bytes_out: 100,
      redactions: %{card: 1, ssn: 0, iban: 0, token: 0},
      secrets_resolved: 2
    }

    t =
      Trajectory.new()
      |> Trajectory.step(%{type: :navigate, summary: "go", outcome: :ok})
      |> Trajectory.step(%{type: :extract, summary: "read", outcome: :ok, egress: report})
      |> Trajectory.step(%{type: :halt, summary: "stop", outcome: :halted})

    s = Trajectory.summary(t)
    assert s.steps == 3
    assert s.egress.steps == 1
    assert s.egress.bytes_out == 100
    assert s.egress.redactions.card == 1
    assert s.egress.secrets_resolved == 2
    assert s.outcomes == %{ok: 2, halted: 1}
  end

  test "a caller-supplied timestamp is stored; none is read here" do
    t = Trajectory.step(Trajectory.new(), %{type: :navigate, summary: "go", at: 123})
    assert Trajectory.last(t).at == 123
  end
end
