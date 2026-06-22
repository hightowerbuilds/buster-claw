defmodule BusterClaw.DispatchCommandsTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.{Commands, Dispatch}

  defp enqueue!(attrs) do
    {:ok, item} =
      Dispatch.enqueue(
        Map.merge(
          %{
            source: "gmail",
            dedupe_key: "k#{System.unique_integer([:positive])}",
            subject: "Hi",
            recommended_role_key: "mail-triage"
          },
          attrs
        )
      )

    item
  end

  test "dispatch_list returns open items, filterable by job" do
    enqueue!(%{recommended_role_key: "mail-triage", dedupe_key: "a"})
    enqueue!(%{recommended_role_key: "other", dedupe_key: "b"})

    {:ok, all} = Commands.call("dispatch_list", %{})
    assert length(all) == 2

    {:ok, scoped} = Commands.call("dispatch_list", %{"job" => "mail-triage"})
    assert [%{recommended_role_key: "mail-triage"}] = scoped
  end

  test "dispatch_strategy opts a queued item into the swarm path" do
    item = enqueue!(%{dedupe_key: "strat"})

    {:ok, updated} =
      Commands.call("dispatch_strategy", %{"id" => item.id, "strategy" => "swarm"})

    assert updated.strategy == "swarm"

    # An unknown strategy is rejected.
    assert {:error, :bad_strategy} =
             Commands.call("dispatch_strategy", %{"id" => item.id, "strategy" => "nope"})
  end

  test "dispatch_claim skips swarm-strategy items (coordinator owns them)" do
    swarm = enqueue!(%{dedupe_key: "sw"})
    {:ok, _} = Commands.call("dispatch_strategy", %{"id" => swarm.id, "strategy" => "swarm"})
    single = enqueue!(%{dedupe_key: "sg"})

    {:ok, claimed} = Commands.call("dispatch_claim", %{"claimed_by" => "tester"})
    assert claimed.id == single.id
  end

  test "dispatch_claim claims the oldest open item, then reports empty" do
    item = enqueue!(%{dedupe_key: "c"})

    {:ok, claimed} = Commands.call("dispatch_claim", %{"claimed_by" => "tester"})
    assert claimed.id == item.id
    assert claimed.status == "claimed"

    assert {:ok, %{"empty" => true}} = Commands.call("dispatch_claim", %{})
  end

  test "dispatch_claim scopes to a job even when another is older" do
    _older = enqueue!(%{recommended_role_key: "mail-triage", dedupe_key: "d"})
    target = enqueue!(%{recommended_role_key: "ci-fix", dedupe_key: "e"})

    {:ok, claimed} = Commands.call("dispatch_claim", %{"job" => "ci-fix"})
    assert claimed.id == target.id
  end

  test "dispatch_done and dispatch_block finish an item (with an optional note)" do
    item = enqueue!(%{dedupe_key: "f"})
    {:ok, done} = Commands.call("dispatch_done", %{"id" => item.id, "note" => "handled"})
    assert done.status == "done"
    assert done.notes == "handled"

    other = enqueue!(%{dedupe_key: "g"})
    {:ok, blocked} = Commands.call("dispatch_block", %{"id" => other.id})
    assert blocked.status == "blocked"
  end

  test "dispatch_show fetches by id and reports not_found for unknown" do
    item = enqueue!(%{dedupe_key: "h"})
    {:ok, shown} = Commands.call("dispatch_show", %{"id" => item.id})
    assert shown.id == item.id

    assert {:error, :not_found} = Commands.call("dispatch_show", %{"id" => 999_999})
  end

  test "the dispatch commands are all safe-tier (agent-callable)" do
    for name <- ~w(dispatch_list dispatch_show dispatch_claim dispatch_done dispatch_block) do
      assert Commands.command_tier(name) == :safe
    end
  end

  test "dispatch_enqueue queues a manual single-strategy item by default" do
    {:ok, item} = Commands.call("dispatch_enqueue", %{"summary" => "do the thing"})

    assert item.request_summary == "do the thing"
    assert item.source == "manual"
    assert item.strategy == "single"
    assert item.status == "queued"
    # Operator-authored via a restricted command → trusted provenance by default.
    assert item.trusted == true

    # It is now claimable on the generic (single) path.
    {:ok, claimed} = Commands.call("dispatch_claim", %{"claimed_by" => "tester"})
    assert claimed.id == item.id
  end

  test "dispatch_enqueue with strategy=swarm lands on the coordinator path, not the generic claim" do
    {:ok, item} =
      Commands.call("dispatch_enqueue", %{
        "summary" => "research and summarize",
        "subject" => "Quarterly review",
        "strategy" => "swarm"
      })

    assert item.strategy == "swarm"
    assert item.subject == "Quarterly review"

    # Swarm items are owned by the coordinator — the generic claim skips them.
    assert {:ok, %{"empty" => true}} = Commands.call("dispatch_claim", %{})
    assert [%{id: id}] = Dispatch.list_queued(strategy: "swarm")
    assert id == item.id
  end

  test "dispatch_enqueue can downgrade to untrusted provenance and rejects bad input" do
    {:ok, untrusted} =
      Commands.call("dispatch_enqueue", %{"summary" => "untrusted work", "trusted" => false})

    assert untrusted.trusted == false

    assert {:error, :missing_summary} = Commands.call("dispatch_enqueue", %{"summary" => "   "})
    assert {:error, :missing_summary} = Commands.call("dispatch_enqueue", %{})

    assert {:error, :bad_strategy} =
             Commands.call("dispatch_enqueue", %{"summary" => "x", "strategy" => "nope"})
  end

  test "dispatch_enqueue is restricted-tier (not freely agent/mcp-callable)" do
    assert Commands.command_tier("dispatch_enqueue") == :restricted
  end
end
