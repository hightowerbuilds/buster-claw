defmodule BusterClaw.Agent.ChatSubmitTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.FakeChatTransport

  # A spawner whose run never finishes on its own, so the conversation stays
  # `:running` and every delivery mode below is exercised against a live turn.
  defp hanging_spawner, do: fn _prompt, _opts -> {:ok, make_ref()} end

  defp start_chat(opts) do
    conv_id = "submit-#{System.unique_integer([:positive])}"
    Chat.subscribe(conv_id)

    {:ok, _pid} =
      Chat.start_link(
        [conv_id: conv_id, spawner: hanging_spawner(), persist: false, audit: false] ++ opts
      )

    conv_id
  end

  # A conversation whose backend can steer.
  defp steerable_chat, do: start_chat(transport_mod: FakeChatTransport)

  # A conversation on the real Phase 1 adapters, none of which can steer yet.
  defp one_shot_chat, do: start_chat([])

  describe "delivery modes while idle" do
    test "every mode starts a turn — there is nothing to steer into or queue behind" do
      for delivery <- [:auto, :next, :steer] do
        conv = steerable_chat()
        assert {:ok, :started} = Chat.submit(conv, "go", delivery: delivery)
        assert Chat.running?(conv)
        assert Chat.queue(conv) == []
      end
    end
  end

  describe "delivery modes while a turn is running" do
    test ":steer on a steerable backend joins the active turn and does not queue" do
      conv = steerable_chat()
      assert {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)

      assert {:ok, :steered} = Chat.submit(conv, "actually do this instead", delivery: :steer)

      # The defining property: a steered message is part of the turn already
      # running, so it must NOT appear in the on-deck queue.
      assert Chat.queue(conv) == []
      assert Chat.running?(conv)
    end

    test ":steer is still rendered as a user message, because the operator said it" do
      conv = steerable_chat()
      assert {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)
      assert_receive {:agent_chat, ^conv, {:message, %{role: :user, text: "first"}}}

      assert {:ok, :steered} = Chat.submit(conv, "redirect", delivery: :steer)
      assert_receive {:agent_chat, ^conv, {:message, %{role: :user, text: "redirect"}}}
    end

    test ":next queues without touching the active turn" do
      conv = steerable_chat()
      assert {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)

      assert {:ok, :queued} = Chat.submit(conv, "afterwards, run the tests", delivery: :next)

      assert [%{text: "afterwards, run the tests"}] = Chat.queue(conv)
      assert Chat.running?(conv)
    end

    test ":auto queues, preserving the behaviour send_message/2 has always had" do
      conv = steerable_chat()
      assert {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)
      assert {:ok, :queued} = Chat.submit(conv, "second", delivery: :auto)
      assert [%{text: "second"}] = Chat.queue(conv)
    end
  end

  describe "when steering cannot happen" do
    test ":steer falls back to the queue on a backend that cannot steer" do
      conv = one_shot_chat()
      assert {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)

      # The honest outcome, and the one the UI must render: this was queued.
      assert {:ok, :queued} = Chat.submit(conv, "redirect", delivery: :steer)
      assert [%{text: "redirect"}] = Chat.queue(conv)
    end

    test "a backend that reports :not_supported mid-flight also demotes to the queue" do
      conv = steerable_chat()
      assert {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)

      assert {:ok, :queued} = Chat.submit(conv, "NOSTEER please", delivery: :steer)
      assert [%{text: "NOSTEER please"}] = Chat.queue(conv)
    end

    test "the completion race demotes to the queue rather than steering a later turn" do
      conv = steerable_chat()
      assert {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)

      # The turn ended between the operator hitting send and the adapter being
      # asked. Scenario C: this must never be applied to whatever turn starts
      # next, and must never be reported as steered.
      assert {:ok, :queued} = Chat.submit(conv, "RACE redirect", delivery: :steer)
      assert [%{text: "RACE redirect"}] = Chat.queue(conv)
    end

    test "a race-demoted message goes to the FRONT, ahead of earlier queue-next work" do
      conv = steerable_chat()
      assert {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)
      assert {:ok, :queued} = Chat.submit(conv, "later, run the tests", delivery: :next)

      assert {:ok, :queued} = Chat.submit(conv, "RACE redirect", delivery: :steer)

      # The operator aimed the redirect at work happening a moment ago. Putting
      # it behind a message they wrote earlier would invert their intent.
      assert [%{text: "RACE redirect"}, %{text: "later, run the tests"}] = Chat.queue(conv)
    end

    test "an ordinary un-steerable message keeps its place in line instead" do
      conv = steerable_chat()
      assert {:ok, :started} = Chat.submit(conv, "first", delivery: :auto)
      assert {:ok, :queued} = Chat.submit(conv, "later, run the tests", delivery: :next)

      assert {:ok, :queued} = Chat.submit(conv, "NOSTEER please", delivery: :steer)

      assert [%{text: "later, run the tests"}, %{text: "NOSTEER please"}] = Chat.queue(conv)
    end
  end

  describe "send_message/2 compatibility" do
    test "still returns a bare :ok for both the start and the queue path" do
      conv = one_shot_chat()
      assert Chat.send_message(conv, "first") == :ok
      assert Chat.send_message(conv, "second") == :ok
      assert [%{text: "second"}] = Chat.queue(conv)
    end

    test "still surfaces a spawn failure to the caller" do
      conv_id = "submit-fail-#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Chat.start_link(
          conv_id: conv_id,
          spawner: fn _p, _o -> {:error, :no_agent_cli} end,
          persist: false,
          audit: false
        )

      assert Chat.send_message(conv_id, "go") == {:error, :no_agent_cli}
      assert Chat.submit(conv_id, "go", delivery: :steer) == {:error, :no_agent_cli}
    end
  end

  describe "capabilities/1" do
    test "reports what the conversation's backend can actually do" do
      assert %{modes: modes, receipt: :none} = Chat.capabilities(one_shot_chat())
      refute :steer in modes

      assert %{modes: steer_modes, receipt: :turn_addressed} =
               Chat.capabilities(steerable_chat())

      assert :steer in steer_modes
    end

    test "answers for a conversation that has no process yet, so a UI can label its button" do
      assert %{modes: modes, receipt: :none} =
               Chat.capabilities("never-started-#{System.unique_integer([:positive])}")

      assert :start_turn in modes
      assert :queue_next in modes
    end
  end
end
