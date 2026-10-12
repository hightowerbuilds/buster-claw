defmodule BusterClaw.AppTabs do
  @moduledoc """
  Acknowledged requests to the live app's tab strip. Tabs belong to the UI's
  local storage, so commands ask the most recently focused shell to apply a
  layout. No requests are queued for an absent UI or broadcast to every window.
  """
  use GenServer

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, [], if(name, do: [name: name], else: []))
  end

  def register(server \\ __MODULE__), do: GenServer.call(server, {:register, self()})

  def request(action, args \\ %{}, opts \\ []) when action in [:list, :join, :separate] do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, 4_000)
    GenServer.call(server, {:request, action, args, timeout}, timeout + 1_000)
  catch
    :exit, _ -> {:error, :app_tabs_unavailable}
  end

  def fulfill(ref, result, server \\ __MODULE__),
    do: GenServer.call(server, {:fulfill, self(), ref, result})

  @impl true
  def init(_opts), do: {:ok, %{clients: [], pending: %{}}}

  @impl true
  def handle_call({:register, pid}, _from, state) do
    unless pid in state.clients, do: Process.monitor(pid)
    {:reply, :ok, %{state | clients: [pid | List.delete(state.clients, pid)]}}
  end

  def handle_call({:request, _action, _args, _timeout}, _from, %{clients: []} = state),
    do: {:reply, {:error, :app_tabs_unavailable}, state}

  def handle_call({:request, action, args, timeout}, from, state) do
    if map_size(state.pending) > 0 do
      {:reply, {:error, :app_tabs_busy}, state}
    else
      [client | _] = state.clients
      ref = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      timer = Process.send_after(self(), {:expire, ref}, timeout)

      send(
        client,
        {:app_tabs,
         %{
           ref: ref,
           action: action,
           args: args,
           expires_at: System.system_time(:millisecond) + timeout
         }}
      )

      {:noreply, put_in(state.pending[ref], %{from: from, client: client, timer: timer})}
    end
  end

  def handle_call({:fulfill, client, ref, result}, _from, state) do
    case state.pending[ref] do
      %{client: ^client} -> {:reply, true, finish(state, ref, result)}
      _ -> {:reply, false, state}
    end
  end

  @impl true
  def handle_info({:expire, ref}, state),
    do: {:noreply, finish(state, ref, {:error, :app_tabs_timeout})}

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    state =
      Enum.reduce(state.pending, state, fn
        {ref, %{client: ^pid}}, acc -> finish(acc, ref, {:error, :app_tabs_disconnected})
        _, acc -> acc
      end)

    {:noreply, %{state | clients: List.delete(state.clients, pid)}}
  end

  defp finish(state, ref, result) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        state

      {%{from: from, timer: timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, result)
        %{state | pending: pending}
    end
  end
end
