defmodule BusterClaw.Notifications.SoundBoardTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.SoundBoard

  describe "event_key/1 — the mapping is the policy" do
    test "group A: agent attention" do
      assert SoundBoard.event_key({:pending_action, %{id: 1}}) == "confirm"
      assert SoundBoard.event_key({:orchestration, :shift_stopped}) == "shift"

      assert SoundBoard.event_key({:dispatch, :dispatch_item_finished, %{status: "blocked"}}) ==
               "blocked"

      assert SoundBoard.event_key({:agent_mode, "run1", {:mode_changed, :halted}}) == "web"

      assert SoundBoard.event_key({:agent_mode, "run1", {:mode_changed, :awaiting_human}}) ==
               "web"
    end

    test "group A refusals: normal lifecycle is silent" do
      # A shift starting or completing normally is not an interruption.
      assert SoundBoard.event_key({:orchestration, :shift_started}) == nil
      assert SoundBoard.event_key({:orchestration, :shift_completed}) == nil

      # Items finishing fine, being claimed, or updating are the loop working.
      assert SoundBoard.event_key({:dispatch, :dispatch_item_finished, %{status: "done"}}) == nil

      assert SoundBoard.event_key({:dispatch, :dispatch_item_finished, %{status: "failed"}}) ==
               nil

      assert SoundBoard.event_key({:dispatch, :dispatch_item_claimed, %{status: "claimed"}}) ==
               nil

      # A browser run getting to work is not news; it going quiet is.
      assert SoundBoard.event_key({:agent_mode, "r", {:mode_changed, :agent_working}}) == nil
      assert SoundBoard.event_key({:agent_mode, "r", {:mode_changed, :idle}}) == nil
      assert SoundBoard.event_key({:agent_mode, "r", :run_started}) == nil
    end

    test "group B: inbound comms ring, our own sends never do" do
      assert SoundBoard.event_key({:telephony_event, %{direction: "inbound", kind: "voicemail"}}) ==
               "voicemail"

      assert SoundBoard.event_key({:telephony_event, %{direction: "inbound", kind: "sms"}}) ==
               "sms"

      assert SoundBoard.event_key({:telephony_event, %{direction: "outbound", kind: "sms"}}) ==
               nil

      assert SoundBoard.event_key(:telephony_costs_updated) == nil
    end

    test "group B: only mail-sourced queue items ring email" do
      assert SoundBoard.event_key({:dispatch, :dispatch_item_queued, %{source: "gmail"}}) ==
               "email"

      # Voicemail/SMS items already rang from their Telephony broadcast —
      # ringing the queued item too would double-ring one arrival.
      assert SoundBoard.event_key({:dispatch, :dispatch_item_queued, %{source: "voicemail"}}) ==
               nil

      assert SoundBoard.event_key({:dispatch, :dispatch_item_queued, %{source: "sms"}}) == nil
      # A manual enqueue is the operator talking to themselves.
      assert SoundBoard.event_key({:dispatch, :dispatch_item_queued, %{source: nil}}) == nil
    end

    test "group C: security rings on :critical and NOTHING else — the pinned rubric" do
      assert SoundBoard.event_key({:security_event, %{severity: :critical}}) == "security"

      for severity <- [:warning, :notice, :info] do
        assert SoundBoard.event_key({:security_event, %{severity: severity}}) == nil,
               "severity #{severity} must never ring"
      end
    end

    test "the direct lane passes through" do
      assert SoundBoard.event_key({:sound_ring, "order"}) == "order"
      assert SoundBoard.event_key({:sound_ring, "boot"}) == "boot"
    end

    test "everything else is silence" do
      assert SoundBoard.event_key({:music_state, %{}}) == nil
      assert SoundBoard.event_key({:notification_fired, %{}}) == nil
      assert SoundBoard.event_key(:junk) == nil
      assert SoundBoard.event_key(nil) == nil
    end
  end

  describe "allow/3 — cooldown" do
    test "first ring is allowed and recorded" do
      assert {:ring, rung} = SoundBoard.allow(%{}, "chat", 1_000)
      assert rung == %{"chat" => 1_000}
    end

    test "a burst inside the window collapses to the first ring" do
      {:ring, rung} = SoundBoard.allow(%{}, "chat", 1_000)

      assert SoundBoard.allow(rung, "chat", 1_001) == :skip
      assert SoundBoard.allow(rung, "chat", 1_000 + SoundBoard.cooldown_ms("chat") - 1) == :skip
    end

    test "the window elapsing re-arms the key" do
      {:ring, rung} = SoundBoard.allow(%{}, "chat", 1_000)

      assert {:ring, _} = SoundBoard.allow(rung, "chat", 1_000 + SoundBoard.cooldown_ms("chat"))
    end

    test "keys cool down independently" do
      {:ring, rung} = SoundBoard.allow(%{}, "chat", 1_000)

      # A chat chime must not eat a voicemail arriving a second later.
      assert {:ring, _} = SoundBoard.allow(rung, "voicemail", 1_001)
    end

    test "the act-now keys re-arm faster than the rest" do
      assert SoundBoard.cooldown_ms("security") < SoundBoard.cooldown_ms("chat")
      assert SoundBoard.cooldown_ms("confirm") < SoundBoard.cooldown_ms("chat")

      {:ring, rung} = SoundBoard.allow(%{}, "security", 0)
      # Past its own short window, still inside the default one.
      assert {:ring, _} = SoundBoard.allow(rung, "security", SoundBoard.cooldown_ms("security"))
    end
  end

  describe "ring/1 — the direct lane" do
    test "broadcasts a valid routing key to subscribers" do
      SoundBoard.subscribe()

      assert SoundBoard.ring("order") == :ok
      assert_receive {:sound_ring, "order"}
    end

    test "refuses a key the routing table doesn't know" do
      SoundBoard.subscribe()

      assert SoundBoard.ring("kazoo") == {:error, :unknown_key}
      assert SoundBoard.ring(nil) == {:error, :unknown_key}
      refute_receive {:sound_ring, _}, 50
    end
  end
end
