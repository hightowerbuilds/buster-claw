defmodule BusterClaw.DispatchTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Dispatch
  alias BusterClaw.Orchestration

  test "enqueue creates a queued Dispatch item with a Gmail dedupe key" do
    assert {:ok, item} =
             Dispatch.enqueue(%{
               "source" => "gmail",
               "gmail_message_id" => "19ea389de2179b2b",
               "trusted_sender" => "hightowerbuilds.dev@gmail.com",
               "trusted" => true,
               "auth_status" => "trusted",
               "request_summary" => "Build an agentic plan to follow the World Cup.",
               "recommended_agent" => "Ingest Analyst",
               "risk" => "safe_research_planning"
             })

    assert item.status == "queued"
    assert item.dedupe_key == "gmail:19ea389de2179b2b"
    assert item.trusted
    assert item.auth_status == "trusted"
  end

  test "dedupe key prevents repeated Dispatch entries for the same request" do
    attrs = %{
      source: "gmail",
      gmail_message_id: "message-1",
      request_summary: "Do the thing."
    }

    assert {:ok, _item} = Dispatch.enqueue(attrs)
    assert {:error, changeset} = Dispatch.enqueue(attrs)
    assert %{dedupe_key: _} = errors_on(changeset)
  end

  test "enqueue_gmail maps message context into a Dispatch item" do
    account = %{email: "operator@example.com"}

    message = %{
      id: "message-2",
      thread_id: "thread-2",
      from: "Luke <hightowerbuilds.dev@gmail.com>",
      subject: "Buster Claw request",
      body_text: String.duplicate("follow the world cup ", 200)
    }

    assert {:ok, item} =
             Dispatch.enqueue_gmail(account, message, %{
               trusted_sender: "hightowerbuilds.dev@gmail.com",
               trusted: true,
               auth_status: "trusted",
               request_summary: "Build an agentic World Cup follow-up plan.",
               recommended_agent: "Ingest Analyst",
               recommended_role_key: "ingest-analyst"
             })

    assert item.source == "gmail"
    assert item.source_account == "operator@example.com"
    assert item.sender == "Luke <hightowerbuilds.dev@gmail.com>"
    assert item.gmail_message_id == "message-2"
    assert item.gmail_thread_id == "thread-2"
    assert item.subject == "Buster Claw request"
    assert item.dedupe_key == "gmail:message-2"
    assert item.recommended_role_key == "ingest-analyst"
    assert String.length(item.request_body_excerpt) <= 2000
  end

  test "claim_next claims the oldest queued item" do
    assert {:ok, first} =
             Dispatch.enqueue(%{
               source: "gmail",
               gmail_message_id: "first",
               request_summary: "First request."
             })

    assert {:ok, second} =
             Dispatch.enqueue(%{
               source: "gmail",
               gmail_message_id: "second",
               request_summary: "Second request."
             })

    assert {:ok, claimed} = Dispatch.claim_next("dispatcher")
    assert claimed.id == first.id
    assert claimed.status == "claimed"
    assert claimed.claimed_by == "dispatcher"
    assert claimed.claimed_at

    assert [queued] = Dispatch.list_queued()
    assert queued.id == second.id
  end

  test "running and finish transitions link Dispatch to shift and role session" do
    {:ok, shift} = Orchestration.start_shift(job: "lookout")
    {:ok, assignment} = Orchestration.start_shift_assignment(role_key: "mail-triage")

    {:ok, _item} =
      Dispatch.enqueue(%{
        source: "gmail",
        gmail_message_id: "running-message",
        request_summary: "Handle a trusted operator request."
      })

    {:ok, claimed} = Dispatch.claim_next("dispatcher")

    assert {:ok, running} =
             Dispatch.mark_running(claimed, %{
               shift_id: shift.id,
               shift_assignment_id: assignment.id
             })

    assert running.status == "running"
    assert running.shift_id == shift.id
    assert running.shift_assignment_id == assignment.id
    assert running.started_at
    assert running.heartbeat_at

    assert {:ok, done} =
             Dispatch.finish(running, "done", %{
               outcome: "Agent completed the request.",
               notes: "Outcome appended to Dispatch."
             })

    assert done.status == "done"
    assert done.finished_at
    assert done.outcome == "Agent completed the request."
    assert done.notes == "Outcome appended to Dispatch."
  end

  test "reclaim_orphans returns in-flight items to the queue and clears claim fields" do
    {:ok, _} = Dispatch.enqueue(%{source: "gmail", gmail_message_id: "orphan-1"})
    {:ok, _} = Dispatch.enqueue(%{source: "gmail", gmail_message_id: "orphan-2"})

    {:ok, claimed} = Dispatch.claim_next("dispatcher")
    {:ok, _running} = Dispatch.mark_running(claimed)

    # A queued item is untouched; the running one is reset.
    assert Dispatch.reclaim_orphans() == 1

    reclaimed = Dispatch.get_item!(claimed.id)
    assert reclaimed.status == "queued"
    assert reclaimed.claimed_by == nil
    assert reclaimed.claimed_at == nil
    assert reclaimed.started_at == nil

    # Everything is back in the open/queued pool, nothing stuck in-flight.
    assert length(Dispatch.list_queued()) == 2
  end

  test "any_untrusted_open? weighs the whole open pool, not a newest-first sample" do
    # An empty pool is trusted; a trusted-only pool stays trusted.
    refute Dispatch.any_untrusted_open?()

    {:ok, _} =
      Dispatch.enqueue(%{source: "gmail", gmail_message_id: "trusted-1", trusted: true})

    refute Dispatch.any_untrusted_open?()

    # Bury an untrusted item under more than a default page of trusted items; the
    # EXISTS probe must still find it (the old newest-first sample would miss it).
    {:ok, buried} =
      Dispatch.enqueue(%{source: "gmail", gmail_message_id: "untrusted", trusted: false})

    for i <- 1..60 do
      {:ok, _} = Dispatch.enqueue(%{source: "gmail", gmail_message_id: "t-#{i}", trusted: true})
    end

    assert Dispatch.any_untrusted_open?()

    # Resolving the untrusted item out of the open pool clears the flag (only
    # queued/claimed/running items count).
    {:ok, _done} = Dispatch.finish(buried, "done")
    refute Dispatch.any_untrusted_open?()

    # A freshly-queued untrusted item flips it back.
    {:ok, _} = Dispatch.enqueue(%{source: "manual", trusted: false})
    assert Dispatch.any_untrusted_open?()
  end
end
