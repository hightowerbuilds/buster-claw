defmodule BusterClaw.Music.PlayerTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Music.Player

  describe "a fresh player" do
    test "is idle and holds nothing" do
      state = Player.new()

      assert state.track == nil
      assert state.queue == []
      assert state.history == []
      refute state.playing?
      assert Player.idle?(state)
    end
  end

  describe "play/2" do
    test "starts a track" do
      state = Player.new() |> Player.play("a.mp3")

      assert state.track == "a.mp3"
      assert state.playing?
      assert state.position == 0.0
      refute Player.idle?(state)
    end

    test "pushes what was playing onto history" do
      state = Player.new() |> Player.play("a.mp3") |> Player.play("b.mp3")

      assert state.track == "b.mp3"
      assert state.history == ["a.mp3"]
    end

    test "resets a stale duration so the old track's length is never shown" do
      state =
        Player.new()
        |> Player.play("long.mp3")
        |> Player.report_duration(300)
        |> Player.play("short.mp3")

      assert state.duration == nil
    end
  end

  describe "enqueue/2" do
    test "an idle player starts playing instead of silently queueing" do
      state = Player.new() |> Player.enqueue("a.mp3")

      assert state.track == "a.mp3"
      assert state.playing?
      assert state.queue == []
    end

    test "a busy player appends, preserving order" do
      state =
        Player.new()
        |> Player.play("a.mp3")
        |> Player.enqueue("b.mp3")
        |> Player.enqueue("c.mp3")

      assert state.track == "a.mp3"
      assert state.queue == ["b.mp3", "c.mp3"]
    end
  end

  describe "advance/1" do
    test "pulls the next track and remembers the last" do
      state =
        Player.new()
        |> Player.play("a.mp3")
        |> Player.enqueue("b.mp3")
        |> Player.advance()

      assert state.track == "b.mp3"
      assert state.queue == []
      assert state.history == ["a.mp3"]
      assert state.playing?
    end

    test "an empty queue stops cleanly rather than showing a finished track" do
      state = Player.new() |> Player.play("a.mp3") |> Player.advance()

      assert state.track == nil
      refute state.playing?
      assert state.history == ["a.mp3"]
    end

    test "drains a whole queue and then stops" do
      state =
        Player.new()
        |> Player.play("a.mp3")
        |> Player.enqueue("b.mp3")
        |> Player.enqueue("c.mp3")
        |> Player.advance()
        |> Player.advance()
        |> Player.advance()

      assert state.track == nil
      refute state.playing?
      assert state.queue == []
    end
  end

  describe "previous/1" do
    test "goes back and pushes the current track to the front of the queue" do
      state =
        Player.new()
        |> Player.play("a.mp3")
        |> Player.play("b.mp3")
        |> Player.previous()

      assert state.track == "a.mp3"
      assert state.queue == ["b.mp3"]
      assert state.history == []
    end

    test "is a no-op with no history" do
      state = Player.new() |> Player.play("a.mp3")

      assert Player.previous(state) == state
    end

    test "round-trips: next then previous returns you where you were" do
      start = Player.new() |> Player.play("a.mp3") |> Player.enqueue("b.mp3")
      back = start |> Player.advance() |> Player.previous()

      assert back.track == start.track
      assert back.queue == start.queue
    end
  end

  describe "toggle/1" do
    test "flips play state" do
      state = Player.new() |> Player.play("a.mp3")

      assert Player.toggle(state).playing? == false
      assert state |> Player.toggle() |> Player.toggle() |> Map.get(:playing?) == true
    end

    test "does nothing with no track — a paused nothing is not a state" do
      state = Player.new()
      assert Player.toggle(state) == state
    end
  end

  describe "stop/1" do
    test "unloads but keeps the queue for later" do
      state =
        Player.new()
        |> Player.play("a.mp3")
        |> Player.enqueue("b.mp3")
        |> Player.stop()

      assert state.track == nil
      refute state.playing?
      assert state.queue == ["b.mp3"]
    end

    test "does not erase history" do
      # push_history/1 returned [] for a nil track once, which made
      # stop-then-play quietly destroy everything previous/1 could reach.
      state =
        Player.new()
        |> Player.play("a.mp3")
        |> Player.play("b.mp3")
        |> Player.stop()

      assert state.history == ["b.mp3", "a.mp3"]

      resumed = Player.play(state, "c.mp3")
      assert resumed.history == ["b.mp3", "a.mp3"]
      assert Player.previous(resumed).track == "b.mp3"
    end
  end

  describe "seek/2" do
    test "bumps the id so a repeat seek to the same spot still moves the head" do
      state = Player.new() |> Player.play("a.mp3")

      once = Player.seek(state, 30)
      twice = Player.seek(once, 30)

      assert once.seek_to == 30.0
      assert twice.seek_to == 30.0
      assert twice.seek_id == once.seek_id + 1
    end

    test "clamps to the known duration and never goes negative" do
      state =
        Player.new()
        |> Player.play("a.mp3")
        |> Player.report_duration(100)

      assert Player.seek(state, 500).seek_to == 100.0
      assert Player.seek(state, -20).seek_to == 0.0
    end

    test "is a no-op with nothing loaded" do
      state = Player.new()
      assert Player.seek(state, 30) == state
    end
  end

  describe "set_volume/2" do
    test "clamps instead of raising" do
      state = Player.new()

      assert Player.set_volume(state, 50).volume == 50
      assert Player.set_volume(state, 900).volume == 100
      assert Player.set_volume(state, -5).volume == 0
      assert Player.set_volume(state, 42.7).volume == 43
    end
  end

  describe "reports from the element" do
    test "position and duration are recorded, junk is ignored" do
      state = Player.new() |> Player.play("a.mp3")

      assert Player.report_position(state, 12.5).position == 12.5
      assert Player.report_position(state, -3).position == state.position
      assert Player.report_duration(state, 200).duration == 200.0
      assert Player.report_duration(state, 0).duration == nil
    end

    test "the element's playing state wins over the server's intent" do
      # Autoplay refusal: the server asked to play, the browser said no.
      state = Player.new() |> Player.play("a.mp3") |> Player.report_playing(false)

      refute state.playing?
    end
  end

  describe "fail_current/1" do
    test "records the failure, advances, and keeps playing the queue" do
      state =
        Player.new()
        |> Player.play("bad.mp3")
        |> Player.enqueue("good.mp3")
        |> Player.fail_current()

      assert state.last_error == "bad.mp3"
      assert state.track == "good.mp3"
      assert state.playing?
    end

    test "an empty queue fails to a stopped player with the message, not a dead one" do
      state = Player.new() |> Player.play("bad.mp3") |> Player.fail_current()

      assert state.last_error == "bad.mp3"
      assert state.track == nil
      refute state.playing?
    end

    test "the failed track is unreachable via previous" do
      # Otherwise back-arrow bounces onto the bad file and straight into
      # fail_current again.
      state =
        Player.new()
        |> Player.play("good.mp3")
        |> Player.play("bad.mp3")
        |> Player.fail_current()

      refute "bad.mp3" in state.history
      assert Player.previous(state).track == "good.mp3"
    end

    test "a whole shelf of bad files drains and stops rather than looping" do
      state =
        Player.new()
        |> Player.play("bad1.mp3")
        |> Player.enqueue("bad2.mp3")
        |> Player.enqueue("bad3.mp3")
        |> Player.fail_current()
        |> Player.fail_current()
        |> Player.fail_current()

      assert state.track == nil
      assert state.queue == []
      assert state.last_error == "bad3.mp3"
      # Nothing more to fail on: idempotent from here.
      assert Player.fail_current(state) == state
    end

    test "the note survives the next track starting, and clears on a deliberate play" do
      state =
        Player.new()
        |> Player.play("bad.mp3")
        |> Player.enqueue("good.mp3")
        |> Player.fail_current()
        # The replacement track starts playing — the skip note must outlive this,
        # or nobody ever sees it.
        |> Player.report_playing(true)

      assert state.last_error == "bad.mp3"

      assert Player.play(state, "chosen.mp3").last_error == nil
    end
  end

  describe "prune/2" do
    test "drops tracks the library no longer has" do
      state =
        Player.new()
        |> Player.play("a.mp3")
        |> Player.enqueue("gone.mp3")
        |> Player.enqueue("b.mp3")
        |> Player.prune(["a.mp3", "b.mp3"])

      assert state.queue == ["b.mp3"]
    end

    test "cleans history too, so previous cannot land on a deleted file" do
      state =
        Player.new()
        |> Player.play("gone.mp3")
        |> Player.play("a.mp3")
        |> Player.prune(["a.mp3"])

      assert state.history == []
      assert Player.previous(state) == state
    end
  end

  describe "history is bounded" do
    test "keeps the most recent entries and drops the oldest" do
      state =
        Enum.reduce(1..80, Player.new(), fn n, acc -> Player.play(acc, "track-#{n}.mp3") end)

      assert length(state.history) == 50
      assert hd(state.history) == "track-79.mp3"
    end
  end

  describe "apply_command/2" do
    test "maps every command in the vocabulary" do
      base = Player.new() |> Player.play("a.mp3") |> Player.enqueue("b.mp3")

      assert Player.apply_command(base, {:play, "c.mp3"}).track == "c.mp3"
      assert Player.apply_command(base, {:enqueue, "c.mp3"}).queue == ["b.mp3", "c.mp3"]
      assert Player.apply_command(base, :toggle).playing? == false
      assert Player.apply_command(base, :next).track == "b.mp3"
      assert Player.apply_command(base, :stop).track == nil
      assert Player.apply_command(base, {:seek, 10}).seek_to == 10.0
      assert Player.apply_command(base, {:volume, 20}).volume == 20
    end

    test "an unknown command is ignored, not a crash" do
      # The bus is open to verbs added later; an older player has to survive
      # hearing one.
      base = Player.new() |> Player.play("a.mp3")

      assert Player.apply_command(base, :teleport) == base
      assert Player.apply_command(base, {:play, :not_a_name}) == base
      assert Player.apply_command(base, nil) == base
    end
  end

  describe "the bus" do
    test "a command reaches a subscriber" do
      Player.subscribe_commands()

      Player.request_play("a.mp3")
      assert_receive {:music_command, {:play, "a.mp3"}}

      Player.request_toggle()
      assert_receive {:music_command, :toggle}

      Player.request_seek(42)
      assert_receive {:music_command, {:seek, 42}}
    end

    test "state announcements reach a subscriber and return the state" do
      Player.subscribe_state()
      state = Player.new() |> Player.play("a.mp3")

      assert ^state = Player.announce(state)
      assert_receive {:music_state, ^state}
    end

    test "commanding with no player listening is not an error" do
      assert Player.request_next() == :ok
    end
  end
end
