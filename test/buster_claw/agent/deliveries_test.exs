defmodule BusterClaw.Agent.DeliveriesTest do
  @moduledoc """
  The delivery ledger, and the property the whole phase exists for:

  > every prompt ends in exactly one terminal state, and no prompt is silently
  > discarded

  The tests that matter most here are the ones that kill a conversation between
  submission and receipt, because that is the only situation in which a
  memory-only queue lost work — and it lost it silently, which is why nobody
  noticed.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.Deliveries
  alias BusterClaw.Agent.FakeChatTransport

  defp start_chat(conv_id, opts \\ []) do
    {:ok, pid} =
      Chat.start_link(
        [
          conv_id: conv_id,
          spawner: fn _p, _o -> {:ok, make_ref()} end,
          # Explicit: `config/test.exs` turns persistence OFF for the whole
          # suite, so every other chat test runs without a ledger. This one is
          # about durability, so it opts back in.
          persist: true,
          audit: false
        ] ++ opts
      )

    pid
  end

  defp conv_id, do: "ledger-#{System.unique_integer([:positive])}"

  defp statuses(conv), do: conv |> Deliveries.list() |> Enum.map(& &1.status) |> Enum.sort()

  # `start_link` links the conversation to the test, so an UNLINKED kill is the
  # only way to simulate a crash without taking the test down with it.
  defp kill(pid) do
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1000 -> flunk("chat process did not die")
    end
  end

  describe "every submission is written down" do
    test "a message that starts a turn is recorded as delivered" do
      conv = conv_id()
      start_chat(conv)

      assert {:ok, :started} = Chat.submit(conv, "go", delivery: :auto)

      assert [row] = Deliveries.list(conv)
      assert row.content == "go"
      assert row.requested_mode == "auto"
      assert row.effective_mode == "started"
      assert row.status == "delivered"
      assert row.accepted_at
    end

    test "a queued message is recorded as queued, with what was ASKED for kept" do
      conv = conv_id()
      start_chat(conv)

      {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)
      assert {:ok, :queued} = Chat.submit(conv, "second", delivery: :next)

      row = Deliveries.list(conv) |> Enum.find(&(&1.content == "second"))
      assert row.requested_mode == "next"
      assert row.effective_mode == "queued"
      assert row.status == "queued"
    end

    test "a steer records BOTH what was requested and what happened" do
      conv = conv_id()
      start_chat(conv, transport_mod: FakeChatTransport)

      {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)
      assert {:ok, :steered} = Chat.submit(conv, "redirect", delivery: :steer)

      row = Deliveries.list(conv) |> Enum.find(&(&1.content == "redirect"))
      assert row.requested_mode == "steer"
      assert row.effective_mode == "steered"
      assert row.status == "delivered"
    end

    test "a steer that lost the race records the DEMOTION, not a success" do
      conv = conv_id()
      start_chat(conv, transport_mod: FakeChatTransport)

      {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)
      assert {:ok, :queued} = Chat.submit(conv, "RACE late", delivery: :steer)

      row = Deliveries.list(conv) |> Enum.find(&(&1.content == "RACE late"))

      # The pair is the point: an audit can now answer "how often does a steer
      # lose the race", which one field could not.
      assert row.requested_mode == "steer"
      assert row.effective_mode == "queued"
    end

    test "a spawn failure is terminal, so recovery never retries it" do
      conv = conv_id()

      {:ok, _pid} =
        Chat.start_link(
          conv_id: conv,
          spawner: fn _p, _o -> {:error, :no_agent_cli} end,
          persist: true,
          audit: false
        )

      assert {:error, :no_agent_cli} = Chat.submit(conv, "go", delivery: :auto)

      assert [row] = Deliveries.list(conv)
      assert row.status == "failed"
      assert row.failed_at
      assert row.error =~ "no_agent_cli"
    end
  end

  describe "surviving a crash — the whole point" do
    test "a queued message is still there after the chat process dies" do
      conv = conv_id()
      pid = start_chat(conv)

      {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)
      {:ok, :queued} = Chat.submit(conv, "do this next", delivery: :next)
      assert [%{text: "do this next"}] = Chat.queue(conv)

      # Kill the conversation the way a crash would.
      kill(pid)

      # A fresh process picks the work back up. Before the ledger this message
      # simply vanished, with the operator having been SHOWN it as queued.
      start_chat(conv)
      assert [%{text: "do this next"}] = Chat.queue(conv)
    end

    test "queued messages come back in their original order" do
      conv = conv_id()
      pid = start_chat(conv)

      {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)
      {:ok, :queued} = Chat.submit(conv, "second", delivery: :next)
      {:ok, :queued} = Chat.submit(conv, "third", delivery: :next)

      kill(pid)

      start_chat(conv)
      assert [%{text: "second"}, %{text: "third"}] = Chat.queue(conv)
    end

    test "a race-demoted message keeps its place at the FRONT across a restart" do
      conv = conv_id()
      pid = start_chat(conv, transport_mod: FakeChatTransport)

      {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)
      {:ok, :queued} = Chat.submit(conv, "later", delivery: :next)
      {:ok, :queued} = Chat.submit(conv, "RACE redirect", delivery: :steer)

      assert [%{text: "RACE redirect"}, %{text: "later"}] = Chat.queue(conv)

      kill(pid)

      # Ordering is a ledger fact, not an in-memory one.
      start_chat(conv, transport_mod: FakeChatTransport)
      assert [%{text: "RACE redirect"}, %{text: "later"}] = Chat.queue(conv)
    end

    test "a DELIVERED message is not resurrected — it already ran" do
      conv = conv_id()
      pid = start_chat(conv)

      {:ok, :started} = Chat.submit(conv, "already ran", delivery: :auto)

      kill(pid)

      start_chat(conv)

      # Recovering it would re-run an instruction the agent already acted on.
      assert Chat.queue(conv) == []
    end
  end

  describe "recovery never resends what it cannot vouch for" do
    test "a row left mid-send becomes uncertain, and is NOT resumed" do
      conv = conv_id()

      # A row stuck in `sending`: the process died between handing the message
      # over and learning what happened to it.
      row = Deliveries.record(conv, "did this land?", :steer)
      Deliveries.transition(row, %{status: "sending"})

      assert %{resumable: [], uncertain: [recovered]} = Deliveries.recover(conv)

      assert recovered.status == "uncertain"
      assert recovered.error =~ "interrupted"
    end

    test "an uncertain row stays out of the queue on the next start" do
      conv = conv_id()
      row = Deliveries.record(conv, "did this land?", :steer)
      Deliveries.transition(row, %{status: "sending"})

      start_chat(conv)

      # Resending would apply the instruction twice. The operator can retype a
      # message they can see went unanswered; they cannot un-run a duplicate.
      assert Chat.queue(conv) == []
      assert "uncertain" in statuses(conv)
    end

    test "recovery is idempotent — starting twice does not duplicate work" do
      conv = conv_id()
      pid = start_chat(conv)
      {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)
      {:ok, :queued} = Chat.submit(conv, "queued work", delivery: :next)

      kill(pid)

      pid2 = start_chat(conv)
      assert [%{text: "queued work"}] = Chat.queue(conv)

      kill(pid2)

      start_chat(conv)
      assert [%{text: "queued work"}] = Chat.queue(conv)
    end
  end

  describe "thread bindings are per backend" do
    test "switching harness does not overwrite the other's thread" do
      conv = conv_id()

      Deliveries.put_thread(conv, :claude, "sess-claude")
      Deliveries.put_thread(conv, :codex, "thread-codex")

      # The bug this prevents: visiting codex and coming back to a claude
      # conversation that had forgotten itself.
      assert Deliveries.thread_for(conv, :claude) == "sess-claude"
      assert Deliveries.thread_for(conv, :codex) == "thread-codex"
    end

    test "the same backend's thread is updated, not duplicated" do
      conv = conv_id()

      Deliveries.put_thread(conv, :claude, "sess-1")
      Deliveries.put_thread(conv, :claude, "sess-2")

      assert Deliveries.thread_for(conv, :claude) == "sess-2"
    end

    test "a reset forgets EVERY backend, not just the current one" do
      conv = conv_id()
      Deliveries.put_thread(conv, :claude, "sess-claude")
      Deliveries.put_thread(conv, :codex, "thread-codex")

      start_chat(conv)
      :ok = Chat.reset(conv)

      # Leaving one behind would mean switching harness after a reset silently
      # resumed the old conversation.
      assert Deliveries.thread_for(conv, :claude) == nil
      assert Deliveries.thread_for(conv, :codex) == nil
    end

    test "a conversation resumes the thread its backend last used" do
      conv = conv_id()
      Deliveries.put_thread(conv, :claude, "sess-remembered")

      parent = self()

      {:ok, _pid} =
        Chat.start_link(
          conv_id: conv,
          agent: :claude,
          persist: true,
          audit: false,
          spawner: fn _p, opts ->
            send(parent, {:spawned, opts})
            {:ok, make_ref()}
          end
        )

      {:ok, :started} = Chat.submit(conv, "go", delivery: :auto)

      assert_receive {:spawned, opts}
      args = Keyword.fetch!(opts, :extra_args)
      assert "--resume" in args
      assert "sess-remembered" in args
    end
  end
end
