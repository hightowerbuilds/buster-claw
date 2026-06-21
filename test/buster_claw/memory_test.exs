defmodule BusterClaw.MemoryTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.{Commands, Memory}
  alias BusterClaw.Memory.RunSummary

  defp record!(attrs) do
    {:ok, summary} = Memory.record_run(attrs)
    summary
  end

  test "record_run persists a summary and recent/1 returns it newest-first" do
    record!(%{
      goal: "Unattended shift: mail-triage",
      outcome: "completed",
      detail: "replied to alice"
    })

    record!(%{goal: "Unattended shift: research", outcome: "failed", detail: "site down"})

    goals = Memory.recent(10) |> Enum.map(& &1.goal)
    assert "Unattended shift: research" in goals
    assert hd(goals) == "Unattended shift: research", "newest first"
  end

  test "record_run validates outcome" do
    assert {:error, changeset} = Memory.record_run(%{goal: "x", outcome: "bogus"})
    assert %{outcome: _} = errors_on(changeset)
  end

  test "record_run accepts atom provenance and agent (the runner's real shape)" do
    summary = record!(%{goal: "g", outcome: "completed", provenance: :trusted, agent: :claude})
    assert summary.provenance == "trusted"
    assert summary.agent == "claude"
  end

  test "search finds a summary by a term in the detail and ranks by relevance" do
    record!(%{
      goal: "Unattended shift: mail-triage",
      outcome: "completed",
      detail: "drafted an invoice for acme"
    })

    record!(%{
      goal: "Unattended shift: research",
      outcome: "completed",
      detail: "summarized the news"
    })

    assert {:ok, [hit]} = Memory.search("invoice")
    assert hit.detail =~ "invoice"
  end

  test "search matches across goal and detail, OR-combining terms" do
    record!(%{
      goal: "Unattended shift: research",
      outcome: "completed",
      detail: "read about widgets"
    })

    assert {:ok, results} = Memory.search("research nonexistentword")
    assert Enum.any?(results, &(&1.goal =~ "research"))
  end

  test "search returns empty_query when there are no searchable terms" do
    assert {:error, :empty_query} = Memory.search("   ?! ")
    assert {:error, :empty_query} = Memory.search("")
  end

  test "search tolerates FTS operator characters in user input" do
    record!(%{goal: "g", outcome: "completed", detail: "handled a refund"})
    # Quotes/parens/AND would break a naive MATCH; the builder quotes terms.
    assert {:ok, results} = Memory.search("refund AND (\"oops\")")
    assert Enum.any?(results, &(&1.detail =~ "refund"))
  end

  test "deleting a summary removes it from the FTS index (trigger sync)" do
    summary = record!(%{goal: "g", outcome: "completed", detail: "unique_token_zzz"})
    assert {:ok, [_]} = Memory.search("unique_token_zzz")

    Repo.delete(summary)
    assert {:ok, []} = Memory.search("unique_token_zzz")
  end

  describe "memory_search command" do
    test "returns matching summaries as views" do
      record!(%{
        goal: "Unattended shift: mail-triage",
        outcome: "completed",
        detail: "booked a flight"
      })

      assert {:ok, [view]} = Commands.call("memory_search", %{"query" => "flight"}, caller: :mcp)
      assert view.outcome == "completed"
      assert view.detail =~ "flight"
    end

    test "honors a limit" do
      for i <- 1..5,
          do: record!(%{goal: "g#{i}", outcome: "completed", detail: "shared keyword market"})

      assert {:ok, results} = Commands.call("memory_search", %{"query" => "market", "limit" => 2})
      assert length(results) == 2
    end

    test "empty query is a clean error" do
      assert {:error, :empty_query} = Commands.call("memory_search", %{"query" => "  "})
    end

    test "is a safe-tier command runnable by an untrusted caller" do
      record!(%{goal: "g", outcome: "completed", detail: "did a thing"})
      assert {:ok, _} = Commands.call("memory_search", %{"query" => "thing"}, caller: :mcp)
    end
  end

  test "RunSummary changeset requires goal and outcome" do
    assert %{goal: _, outcome: _} = errors_on(RunSummary.changeset(%RunSummary{}, %{}))
  end
end
