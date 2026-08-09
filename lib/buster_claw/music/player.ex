defmodule BusterClaw.Music.Player do
  @moduledoc """
  Transport state for the dock music player, plus the PubSub bus that lets any
  LiveView drive it.

  ## Why this is a struct and not just LiveView assigns

  The player lives in a sticky LiveView in the dock (`MusicPlayerLive`) so it
  survives tab switches and page navigation — see MUSIC_ROADMAP Finding 2. That
  makes it the wrong place to *also* keep the queue rules: a state machine
  reachable only by driving a browser is a state machine nobody tests. So every
  transition here is a pure function on a struct, and the LiveView is a shell
  that applies them and re-renders.

  ## The bus

  Two topics, deliberately separate:

    * **commands** — anything (the Music tab, a future command-surface verb) asks
      for a change. `MusicPlayerLive` is the only subscriber.
    * **state** — the player announces what it is now. The Music tab subscribes
      so it can render transport it does not own.

  One-directional in each case, which keeps a tab from having to distinguish
  "the state I just asked for" from "the state something else caused".

  ## What the client owns

  Playback *position* belongs to the `<audio>` element; the hook reports it on a
  throttle so the server can display it. Nothing here ticks — this struct's
  `position` is a periodically-refreshed readout, not a clock.
  """

  alias Phoenix.PubSub

  @state_topic "music:player:state"
  @command_topic "music:player:commands"

  @default_volume 80

  # Back-button depth. Unbounded history on a player left running for days is a
  # slow leak in a process that never restarts, and nobody presses previous
  # fifty times.
  @max_history 50

  defstruct track: nil,
            queue: [],
            history: [],
            playing?: false,
            volume: @default_volume,
            position: 0.0,
            duration: nil,
            # Bumped on every seek so the client can tell a NEW seek request
            # from a re-render carrying the same target position.
            seek_id: 0,
            seek_to: nil,
            # The track that most recently failed to load/decode, kept so the
            # Music tab can say "couldn't play X — skipped" instead of the queue
            # silently shortening. Cleared the next time anything succeeds.
            last_error: nil

  @type t :: %__MODULE__{}

  @doc "A player with nothing loaded."
  def new, do: %__MODULE__{}

  # ---------------------------------------------------------------------------
  # Transitions — pure
  # ---------------------------------------------------------------------------

  @doc """
  Play `name` now. Whatever was playing goes to history, so `previous/1` can
  come back to it.
  """
  def play(%__MODULE__{} = state, name) when is_binary(name) do
    %{
      state
      | track: name,
        playing?: true,
        position: 0.0,
        duration: nil,
        history: push_history(state),
        # A deliberate play is a fresh start; a stale failure note would read
        # as a verdict on the track just chosen.
        last_error: nil
    }
  end

  @doc """
  Queue `name`. With nothing playing this starts it instead — an "add to queue"
  on an idle player that did nothing would read as broken.
  """
  def enqueue(%__MODULE__{track: nil} = state, name) when is_binary(name),
    do: play(state, name)

  def enqueue(%__MODULE__{} = state, name) when is_binary(name),
    do: %{state | queue: state.queue ++ [name]}

  @doc "Play/pause. A no-op with nothing loaded rather than a paused nothing."
  def toggle(%__MODULE__{track: nil} = state), do: state
  def toggle(%__MODULE__{} = state), do: %{state | playing?: not state.playing?}

  @doc """
  Advance to the next queued track. An empty queue stops cleanly — track
  cleared, not left showing something that is no longer playing.

  This is also what a finished track calls, so "ended" and "next" cannot drift
  apart.
  """
  def advance(%__MODULE__{queue: []} = state) do
    %{
      state
      | track: nil,
        playing?: false,
        position: 0.0,
        duration: nil,
        history: push_history(state)
    }
  end

  def advance(%__MODULE__{queue: [next | rest]} = state) do
    %{
      state
      | track: next,
        queue: rest,
        playing?: true,
        position: 0.0,
        duration: nil,
        history: push_history(state)
    }
  end

  @doc """
  Back to the previously played track, pushing the current one to the front of
  the queue so it is not lost. No history is a no-op.
  """
  def previous(%__MODULE__{history: []} = state), do: state

  def previous(%__MODULE__{history: [prev | rest]} = state) do
    %{
      state
      | track: prev,
        history: rest,
        queue: requeue(state.track, state.queue),
        playing?: true,
        position: 0.0,
        duration: nil
    }
  end

  @doc "Ask the client to jump to `seconds`."
  def seek(%__MODULE__{track: nil} = state, _seconds), do: state

  def seek(%__MODULE__{} = state, seconds) when is_number(seconds) do
    target = seconds |> max(0.0) |> clamp_to_duration(state.duration)
    %{state | seek_to: target, seek_id: state.seek_id + 1, position: target}
  end

  @doc "Set volume, 0..100. Out-of-range values clamp rather than raise."
  def set_volume(%__MODULE__{} = state, volume) when is_number(volume) do
    %{state | volume: volume |> round() |> max(0) |> min(100)}
  end

  @doc "Stop and unload, keeping the queue for a later play."
  def stop(%__MODULE__{} = state) do
    %{
      state
      | track: nil,
        playing?: false,
        position: 0.0,
        duration: nil,
        history: push_history(state)
    }
  end

  @doc "Record where the client says it is. Ignores junk rather than trusting it."
  def report_position(%__MODULE__{} = state, seconds) when is_number(seconds) and seconds >= 0,
    do: %{state | position: seconds * 1.0}

  def report_position(%__MODULE__{} = state, _seconds), do: state

  @doc "Record the duration the client decoded."
  def report_duration(%__MODULE__{} = state, seconds) when is_number(seconds) and seconds > 0,
    do: %{state | duration: seconds * 1.0}

  def report_duration(%__MODULE__{} = state, _seconds), do: state

  @doc """
  The client says it is actually playing (or not) — the element is the truth.

  Note this does NOT clear `last_error`: after a failed track auto-advances, the
  next one starts playing within a second, and clearing on success would erase
  the "skipped X" note before anyone could read it. The note stays until the
  user deliberately plays something (`play/2` clears it) — it remains true
  either way.
  """
  def report_playing(%__MODULE__{} = state, playing?) when is_boolean(playing?),
    do: %{state | playing?: playing?}

  @doc """
  The current track failed to load or decode. Records the name for the UI and
  advances — the acceptance rule is *one track fails with a message, the player
  does not die*. Advancing (not retrying) is what makes a whole shelf of bad
  files drain instead of loop: the queue is finite and only ever shrinks.
  """
  def fail_current(%__MODULE__{track: nil} = state), do: state

  def fail_current(%__MODULE__{track: track} = state) do
    failed = %{advance(state) | last_error: track}
    # The failed track must not be reachable via previous/1 — going "back" onto
    # a file that cannot play would bounce straight into fail_current again.
    %{failed | history: Enum.reject(failed.history, &(&1 == track))}
  end

  @doc """
  Drop tracks that are no longer in the library — the user can delete a file in
  Finder at any moment, and a queue pointing at nothing would stall on advance.
  """
  def prune(%__MODULE__{} = state, available) when is_list(available) do
    %{
      state
      | queue: Enum.filter(state.queue, &(&1 in available)),
        history: Enum.filter(state.history, &(&1 in available))
    }
  end

  @doc "Is there anything to show? An idle player renders nothing in the dock."
  def idle?(%__MODULE__{track: nil, queue: []}), do: true
  def idle?(%__MODULE__{}), do: false

  # ---------------------------------------------------------------------------
  # The bus
  # ---------------------------------------------------------------------------

  @doc "Subscribe to player state announcements."
  def subscribe_state, do: PubSub.subscribe(BusterClaw.PubSub, @state_topic)

  @doc "Subscribe to commands. Only the dock player should do this."
  def subscribe_commands, do: PubSub.subscribe(BusterClaw.PubSub, @command_topic)

  @doc "Announce current state to anything rendering transport."
  def announce(%__MODULE__{} = state) do
    PubSub.broadcast(BusterClaw.PubSub, @state_topic, {:music_state, state})
    state
  end

  @doc """
  Ask the player to do something. Returns `:ok` whether or not a player is
  listening — a command with no dock present is a no-op, not an error.
  """
  def command(message) do
    PubSub.broadcast(BusterClaw.PubSub, @command_topic, {:music_command, message})
  end

  # Convenience wrappers so callers don't hand-build tuples. Only the verbs the
  # Music library tab offers live here — previous/stop/volume are dock-local
  # controls, so `music_player_live.ex` calls the pure transitions directly and
  # never needs a remote-control wrapper for them.
  def request_play(name) when is_binary(name), do: command({:play, name})
  def request_enqueue(name) when is_binary(name), do: command({:enqueue, name})
  def request_toggle, do: command(:toggle)
  def request_next, do: command(:next)
  def request_seek(seconds) when is_number(seconds), do: command({:seek, seconds})

  @doc """
  Apply a command tuple to a state. Kept here rather than in the LiveView so the
  command vocabulary and the transitions cannot drift apart, and so the whole
  mapping is testable without a socket.
  """
  def apply_command(%__MODULE__{} = state, {:play, name}) when is_binary(name),
    do: play(state, name)

  def apply_command(%__MODULE__{} = state, {:enqueue, name}) when is_binary(name),
    do: enqueue(state, name)

  def apply_command(%__MODULE__{} = state, :toggle), do: toggle(state)
  def apply_command(%__MODULE__{} = state, :next), do: advance(state)
  def apply_command(%__MODULE__{} = state, :previous), do: previous(state)
  def apply_command(%__MODULE__{} = state, :stop), do: stop(state)
  def apply_command(%__MODULE__{} = state, {:seek, seconds}), do: seek(state, seconds)
  def apply_command(%__MODULE__{} = state, {:volume, volume}), do: set_volume(state, volume)
  # An unknown command is ignored, not a crash: the bus is open to future verbs
  # and an old player must survive hearing a new one.
  def apply_command(%__MODULE__{} = state, _unknown), do: state

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Nothing loaded means nothing to remember — and crucially, the EXISTING
  # history is returned rather than an empty list. Returning [] here would make
  # stop-then-play quietly erase everything `previous/1` could go back to.
  defp push_history(%__MODULE__{track: nil, history: history}), do: history

  defp push_history(%__MODULE__{track: track, history: history}),
    do: Enum.take([track | history], @max_history)

  defp requeue(nil, queue), do: queue
  defp requeue(track, queue), do: [track | queue]

  defp clamp_to_duration(seconds, nil), do: seconds * 1.0
  defp clamp_to_duration(seconds, duration), do: min(seconds, duration) * 1.0
end
