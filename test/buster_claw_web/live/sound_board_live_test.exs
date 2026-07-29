defmodule BusterClawWeb.SoundBoardLiveTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Notifications.SoundBoard

  setup do
    root = Path.join(System.tmp_dir!(), "bc_board_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sounds"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, view, _html} = live_isolated(build_conn(), BusterClawWeb.SoundBoardLive)
    {:ok, view: view, root: root}
  end

  # Events arrive via handle_info in production (PubSub); sending directly to
  # the process exercises the same path without staging real security events.
  defp deliver(view, message) do
    send(view.pid, message)
    _ = :sys.get_state(view.pid)
    view
  end

  describe "ringing" do
    test "a confirmation request rings the confirm chime — the highest-value sound",
         %{view: view} do
      deliver(view, {:pending_action, %{id: 1}})

      assert_push_event(view, "notify:play-sound", %{name: "confirm.wav"})
    end

    test "an inbound voicemail rings; the empty workspace resolves to bundled",
         %{view: view} do
      deliver(view, {:telephony_event, %{direction: "inbound", kind: "voicemail"}})

      assert_push_event(view, "notify:play-sound", %{name: "voicemail.wav"})
    end

    test "a workspace routing decides the file, the board only picks the key",
         %{view: view, root: root} do
      File.write!(Path.join([root, "sounds", "wilhelm.wav"]), "x")
      assert Sound.assign("confirm", "wilhelm.wav") == :ok

      deliver(view, {:pending_action, %{id: 1}})

      assert_push_event(view, "notify:play-sound", %{name: "wilhelm.wav"})
    end

    test "the direct lane rings through real PubSub", %{view: view} do
      assert SoundBoard.ring("boot") == :ok
      _ = :sys.get_state(view.pid)

      assert_push_event(view, "notify:play-sound", %{name: "boot.wav"})
    end
  end

  describe "refusals" do
    test "a burst collapses to exactly one chime", %{view: view} do
      for _ <- 1..5, do: deliver(view, {:pending_action, %{id: 1}})

      assert_push_event(view, "notify:play-sound", %{name: "confirm.wav"})
      refute_push_event(view, "notify:play-sound", %{})
    end

    test "a :warning security event is provably silent — the pinned rubric",
         %{view: view} do
      deliver(view, {:security_event, %{severity: :warning}})
      deliver(view, {:security_event, %{severity: :notice}})

      refute_push_event(view, "notify:play-sound", %{})
    end

    test "unmapped app traffic is silence, not a crash", %{view: view} do
      deliver(view, {:music_state, %{}})
      deliver(view, {:dispatch, :dispatch_item_claimed, %{status: "claimed"}})
      deliver(view, :telephony_costs_updated)

      refute_push_event(view, "notify:play-sound", %{})
    end

    test "the master switch silences the board", %{view: view} do
      Sound.set_enabled(false)
      on_exit(fn -> Sound.set_enabled(true) end)

      deliver(view, {:pending_action, %{id: 1}})

      refute_push_event(view, "notify:play-sound", %{})
    end

    test "a silenced event does not consume the cooldown", %{view: view} do
      # Gate order is mapping -> switch -> cooldown: an event that was silenced
      # by the switch must not eat the first audible chime after re-enabling.
      Sound.set_enabled(false)
      deliver(view, {:pending_action, %{id: 1}})
      Sound.set_enabled(true)

      deliver(view, {:pending_action, %{id: 2}})

      assert_push_event(view, "notify:play-sound", %{name: "confirm.wav"})
    end

    test "independent keys ring independently inside one window", %{view: view} do
      deliver(view, {:pending_action, %{id: 1}})
      deliver(view, {:telephony_event, %{direction: "inbound", kind: "sms"}})

      assert_push_event(view, "notify:play-sound", %{name: "confirm.wav"})
      assert_push_event(view, "notify:play-sound", %{name: "sms.wav"})
    end
  end

  describe "the client contract" do
    test "renders the NotifySound hook and nothing visible", %{view: view} do
      html = render(view)

      assert html =~ ~s(phx-hook="NotifySound")
      assert html =~ ~s(id="sound-board")
    end
  end
end
