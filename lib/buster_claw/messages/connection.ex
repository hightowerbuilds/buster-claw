defmodule BusterClaw.Messages.Connection do
  @moduledoc """
  On-demand, bounded stdio connection for the Messages feasibility probe.

  Only `status` is exposed: no message reads, sends, private-framework calls, or
  subscriptions. Nothing starts at app boot. Failed connections back off before
  the next explicit request; they never respawn in a loop. A later intake owner
  can supervise this process once packaged permission attribution is verified.
  """
  use GenServer

  alias BusterClaw.Messages.Status

  @max_line_bytes 65_536
  @max_pending 8

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def status(server), do: GenServer.call(server, :status, :infinity)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       binary: Keyword.fetch!(opts, :binary),
       database: Keyword.get(opts, :database),
       timeout: Keyword.get(opts, :timeout, 5_000),
       retry_ms: Keyword.get(opts, :retry_ms, 1_000),
       port: nil,
       buffer: "",
       sequence: 0,
       pending: %{},
       retry_at: now_ms()
     }}
  end

  @impl true
  def handle_call(:status, _from, %{pending: pending} = state)
      when map_size(pending) >= @max_pending,
      do: {:reply, {:error, :busy}, state}

  def handle_call(:status, from, state) do
    case connect(state) do
      {:ok, state} -> request_status(from, state)
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, bytes}}, %{port: port} = state) when is_port(port) do
    {:noreply, consume(state.buffer <> bytes, %{state | buffer: ""})}
  end

  def handle_info({port, {:exit_status, _}}, %{port: port} = state) when is_port(port),
    do: {:noreply, disconnect(state, :adapter_exited)}

  def handle_info({:EXIT, port, _}, %{port: port} = state) when is_port(port),
    do: {:noreply, disconnect(state, :adapter_exited)}

  def handle_info({:request_timeout, id}, state) do
    if Map.has_key?(state.pending, id),
      do: {:noreply, disconnect(state, :timeout)},
      else: {:noreply, state}
  end

  # Late responses and exit messages from a closed port cannot affect its successor.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    disconnect(state, :connection_closed)
    :ok
  end

  defp connect(%{port: port} = state) when is_port(port), do: {:ok, state}

  defp connect(state) do
    if now_ms() < state.retry_at do
      {:error, :backoff, state}
    else
      open_port(state)
    end
  end

  defp open_port(state) do
    args = [state.binary, "rpc"] ++ database_args(state.database)

    # Fixed shell source; all paths are individual argv values. Discard stderr
    # so helper diagnostics cannot put personal paths/text into app logs. Exec
    # replaces the wrapper; closing the port closes the helper's stdin.
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        args: ["-c", "exec \"$@\" 2>/dev/null", "messages-adapter" | args]
      ])

    {:ok, %{state | port: port, buffer: ""}}
  rescue
    _ -> {:error, :adapter_unavailable, cooldown(state)}
  end

  defp database_args(nil), do: []
  defp database_args(path), do: ["--db", path]

  defp request_status(from, state) do
    id = state.sequence + 1
    request = Jason.encode!(%{jsonrpc: "2.0", id: id, method: "status", params: %{}})

    if write(state.port, request <> "\n") do
      timer = Process.send_after(self(), {:request_timeout, id}, state.timeout)
      pending = Map.put(state.pending, id, {from, timer})
      {:noreply, %{state | sequence: id, pending: pending}}
    else
      {:reply, {:error, :adapter_exited}, disconnect(state, :adapter_exited)}
    end
  end

  defp write(port, bytes) do
    Port.command(port, bytes)
  rescue
    ArgumentError -> false
  end

  defp consume(bytes, state) do
    case :binary.split(bytes, "\n") do
      [line, rest] when byte_size(line) <= @max_line_bytes ->
        case decode(line, state) do
          {:ok, state} -> consume(rest, state)
          {:error, reason} -> disconnect(state, reason)
        end

      [buffer] when byte_size(buffer) <= @max_line_bytes ->
        %{state | buffer: buffer}

      _ ->
        disconnect(state, :response_too_large)
    end
  end

  defp decode(line, state) do
    case Jason.decode(line) do
      {:ok, %{"jsonrpc" => "2.0", "id" => id} = response} when is_integer(id) ->
        complete(id, response, state)

      _ ->
        {:error, :invalid_response}
    end
  end

  defp complete(id, response, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:error, :unexpected_response}

      {{from, timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, result(response))
        {:ok, %{state | pending: pending}}
    end
  end

  defp result(%{"result" => result} = response) when not is_map_key(response, "error"),
    do: Status.from_rpc(result)

  defp result(%{"error" => %{"code" => code}} = response)
       when is_integer(code) and not is_map_key(response, "result"),
       do: {:error, :adapter_error}

  defp result(_), do: {:error, :invalid_response}

  defp disconnect(state, reason) do
    Enum.each(state.pending, fn {_id, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)

    close_port(state.port)
    cooldown(%{state | port: nil, buffer: "", pending: %{}})
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp cooldown(state), do: %{state | retry_at: now_ms() + state.retry_ms}
  defp now_ms, do: System.monotonic_time(:millisecond)
end
