defmodule BusterClaw.Sentinel.Pending do
  @moduledoc """
  Lightweight, in-memory record of restricted commands that were *refused* for
  an untrusted caller (the chat agent or an MCP client). This is the Phase 0
  visibility stub for the larger "Sentinel" security layer.

  When `BusterClaw.Commands.call/3` refuses a restricted command for a
  `:agent`/`:mcp` caller it records an entry here and broadcasts
  `{:pending_action, entry}` on the `"security_alerts"` PubSub topic. Phase 1's
  audit/notify spine and Phase 2's approval gate are designed to consume the
  same topic, so this is a forward-compatible seam rather than throwaway code.

  Deliberately minimal: bounded in-memory list, no database, secrets redacted
  out of the recorded argument digest. Approve/deny actions are Phase 2.
  """

  use GenServer

  alias Phoenix.PubSub

  @topic "security_alerts"
  @max_entries 100
  @sensitive_key_fragments ~w(token secret password api_key apikey authorization auth credential private_key client_secret refresh_token access_token)

  # ---- Public API ----

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The PubSub topic security alerts are broadcast on."
  def topic, do: @topic

  @doc """
  Record a refused restricted command. Fire-and-forget; returns `:ok`.
  `args` are redacted before storage — secret-looking values never land here.
  """
  def record(command, args, caller) when is_binary(command) do
    GenServer.cast(__MODULE__, {:record, command, args, caller})
  end

  @doc "List recorded pending entries, newest first."
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Count of recorded pending entries."
  def count, do: GenServer.call(__MODULE__, :count)

  @doc "Clear all recorded entries (used by the UI and tests)."
  def clear, do: GenServer.call(__MODULE__, :clear)

  # ---- GenServer ----

  @impl true
  def init(:ok), do: {:ok, %{entries: [], seq: 0}}

  @impl true
  def handle_cast({:record, command, args, caller}, state) do
    seq = state.seq + 1

    entry = %{
      id: seq,
      command: command,
      args: redact(args),
      caller: caller,
      at: DateTime.utc_now()
    }

    entries = Enum.take([entry | state.entries], @max_entries)
    PubSub.broadcast(BusterClaw.PubSub, @topic, {:pending_action, entry})
    {:noreply, %{state | entries: entries, seq: seq}}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, state.entries, state}
  def handle_call(:count, _from, state), do: {:reply, length(state.entries), state}
  def handle_call(:clear, _from, state), do: {:reply, :ok, %{state | entries: []}}

  # ---- Redaction ----

  defp redact(args) when is_map(args) do
    Map.new(args, fn {k, v} -> {k, redact_value(k, v)} end)
  end

  defp redact(other), do: other

  defp redact_value(key, value) do
    cond do
      sensitive_key?(key) -> "[redacted]"
      is_map(value) -> redact(value)
      is_binary(value) and byte_size(value) > 120 -> binary_part(value, 0, 120) <> "…"
      true -> value
    end
  end

  defp sensitive_key?(key) do
    k = key |> to_string() |> String.downcase()
    Enum.any?(@sensitive_key_fragments, &String.contains?(k, &1))
  end
end
