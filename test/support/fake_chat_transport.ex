defmodule BusterClaw.Agent.FakeChatTransport do
  @moduledoc """
  A `ChatTransport` that can steer, for testing the delivery paths no real
  adapter implements yet.

  Phase 1 leaves `steer/3` unimplemented on all three backends, so
  `Chat.steer_or_queue/2`'s success branch and its completion-race branch would
  otherwise ship with zero coverage — and those are exactly the branches where a
  bug shows the operator **STEERED** for a message that was quietly queued.

  ## Choosing an outcome

  The outcome is selected by a marker in the message text rather than by
  configuration, so the tests stay `async: true` with no shared state and each
  assertion says on its own line what it expects:

  | Text contains | `steer/3` answers | Chat should report |
  |---|---|---|
  | `"RACE"` | `{:error, :no_active_turn}` | `:queued`, at the FRONT of the queue |
  | `"NOSTEER"` | `{:error, :not_supported}` | `:queued` |
  | anything else | `{:ok, handle, receipt}` | `:steered` |

  Turn spawning is delegated to the real `ChatTransport.spawn_turn/3`, so the
  injected `:spawner` seam and `Chat`'s port handling behave exactly as they do
  with a live adapter.
  """

  @behaviour BusterClaw.Agent.ChatTransport

  alias BusterClaw.Agent.ChatTransport

  @impl true
  def open(opts), do: {:ok, ChatTransport.build(:claude, opts)}

  @impl true
  def capabilities,
    do: %{modes: [:start_turn, :queue_next, :steer, :interrupt], receipt: :turn_addressed}

  @impl true
  def start_turn(handle, text), do: ChatTransport.spawn_turn(handle, text, [])

  @impl true
  def steer(handle, turn_ref, text) do
    cond do
      String.contains?(text, "RACE") -> {:error, :no_active_turn}
      String.contains?(text, "NOSTEER") -> {:error, :not_supported}
      true -> {:ok, handle, %{turn_ref: turn_ref, accepted_at: :fake}}
    end
  end

  @impl true
  def interrupt(handle, _turn_ref), do: {:ok, %{handle | port: nil}}

  @impl true
  def close(_handle), do: :ok
end
