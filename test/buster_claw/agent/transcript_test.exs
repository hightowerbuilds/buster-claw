defmodule BusterClaw.Agent.TranscriptTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Agent.Transcript

  test "records messages and returns them oldest-first per conversation" do
    {:ok, _} = Transcript.record("c1", :user, "first")
    {:ok, _} = Transcript.record("c1", :assistant, "second", cost_usd: 0.01, num_turns: 2)
    {:ok, _} = Transcript.record("c2", :user, "other conversation")

    rows = Transcript.recent("c1")
    assert Enum.map(rows, & &1.content) == ["first", "second"]
    assert Enum.map(rows, & &1.role) == ["user", "assistant"]

    assert [%{content: "other conversation"}] = Transcript.recent("c2")
  end

  test "honors the limit, keeping the most recent" do
    for n <- 1..5, do: {:ok, _} = Transcript.record("c", :user, "m#{n}")
    assert Transcript.recent("c", limit: 2) |> Enum.map(& &1.content) == ["m4", "m5"]
  end

  test "rejects an unknown role" do
    assert {:error, changeset} = Transcript.record("c", :bogus, "x")
    assert %{role: ["is invalid"]} = errors_on(changeset)
  end
end
