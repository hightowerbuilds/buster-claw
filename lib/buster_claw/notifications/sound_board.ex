defmodule BusterClaw.Notifications.SoundBoard do
  @moduledoc """
  Event → sound-key mapping and cooldown for the app-wide SoundBoard
  (SOUND_ROADMAP Phase 1).

  `BusterClawWeb.SoundBoardLive` (sticky, app-wide) subscribes to the app's
  existing PubSub families and asks this module two questions per message:
  *does this event ring* (`event_key/1`) and *is it allowed to right now*
  (`allow/3`). Both are pure functions, because an event-to-sound policy you
  can only test by mounting a LiveView is a policy nobody tests — the same
  split `Music.Player` uses, for the same reason.

  ## The mapping is the policy

  Every clause of `event_key/1` is a line item from SOUND_ROADMAP Part II, and
  the refusals are as deliberate as the matches:

  - A security event **below `:critical` never rings** — `outbound_send` fires
    on routine deliveries, and an alarm that is always ringing is not an alarm.
  - A queued dispatch item rings `email` **only for source "gmail"**: voicemail
    and SMS items ring from their own Telephony broadcasts, and a manual
    enqueue is the operator talking to themselves.
  - Telephony rings on **inbound** only; the box's own sends are not news.

  ## The direct lane

  `ring/1` is for the few moments that have no broadcast: `TradingLive` pinning
  an order card, the Phase 3 boot chime. It validates against
  `Sound.route_keys/0` before broadcasting, so a typo'd key dies at the caller
  instead of crashing the board's LiveView mid-`handle_info`.
  """

  alias BusterClaw.Notifications.Sound
  alias Phoenix.PubSub

  @topic "sound_board"

  # One chime per key per window. confirm/security run shorter windows — those
  # are the two "act now" keys, and a second genuine occurrence deserves a
  # second ring sooner. Nothing bypasses cooldown entirely: a storm of critical
  # events is ONE klaxon per window, because twenty klaxons carry less
  # information than one.
  @default_cooldown_ms 5_000
  @cooldown_ms %{"security" => 2_000, "confirm" => 2_000}

  # ---------------------------------------------------------------------------
  # Mapping (SOUND_ROADMAP Part II)
  # ---------------------------------------------------------------------------

  @doc """
  The routing key an app event should ring, or `nil` for the (common) silence.
  """
  # Group A — agent attention
  def event_key({:pending_action, _entry}), do: "confirm"
  def event_key({:orchestration, :shift_stopped}), do: "shift"

  def event_key({:dispatch, :dispatch_item_finished, %{status: "blocked"}}), do: "blocked"

  # :awaiting_human is the payment gate (and any other pause-for-human);
  # :halted is a run ending. Working transitions stay silent.
  def event_key({:agent_mode, _run_id, {:mode_changed, mode}})
      when mode in [:halted, :awaiting_human],
      do: "web"

  # Group B — comms arrivals (inbound only; our own sends are not news)
  def event_key({:telephony_event, %{direction: "inbound", kind: "voicemail"}}), do: "voicemail"
  def event_key({:telephony_event, %{direction: "inbound", kind: "sms"}}), do: "sms"

  def event_key({:dispatch, :dispatch_item_queued, %{source: "gmail"}}), do: "email"

  # Group C — security, :critical ONLY. The clause order is the rubric: match
  # critical, then swallow every other severity explicitly.
  def event_key({:security_event, %{severity: :critical}}), do: "security"
  def event_key({:security_event, _event}), do: nil

  # The direct lane (ring/1) arrives pre-validated.
  def event_key({:sound_ring, key}) when is_binary(key), do: key

  def event_key(_message), do: nil

  # ---------------------------------------------------------------------------
  # Cooldown
  # ---------------------------------------------------------------------------

  @doc """
  May `key` ring at `now_ms`? Returns `{:ring, last_rung}` with the updated
  map, or `:skip`. `last_rung` is `%{key => monotonic ms}` owned by the caller —
  kept out of any process here so a burst of N events collapsing to one chime
  is a three-line unit test.
  """
  def allow(last_rung, key, now_ms) when is_map(last_rung) do
    window = Map.get(@cooldown_ms, key, @default_cooldown_ms)

    case Map.get(last_rung, key) do
      last when is_integer(last) and now_ms - last < window -> :skip
      _ -> {:ring, Map.put(last_rung, key, now_ms)}
    end
  end

  @doc "The cooldown window for a key, in ms (exposed for tests and the UI)."
  def cooldown_ms(key), do: Map.get(@cooldown_ms, key, @default_cooldown_ms)

  # ---------------------------------------------------------------------------
  # The direct lane + subscription
  # ---------------------------------------------------------------------------

  @doc "Subscribe to direct ring requests. Only the SoundBoard should."
  def subscribe, do: PubSub.subscribe(BusterClaw.PubSub, @topic)

  @doc """
  Ring a routing key directly — for moments with no broadcast of their own
  (the trading order card, the boot chime). Unknown keys are refused here, at
  the caller, rather than crashing the board mid-`handle_info`.
  """
  def ring(key) when is_binary(key) do
    if key in Sound.route_keys() do
      PubSub.broadcast(BusterClaw.PubSub, @topic, {:sound_ring, key})
    else
      {:error, :unknown_key}
    end
  end

  def ring(_key), do: {:error, :unknown_key}
end
