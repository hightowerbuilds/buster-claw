defmodule BusterClaw.BrowserControl.CDP do
  @moduledoc """
  Our CDP client: one GenServer owning one engine process over the pipe.

  "Our own" is the point (BROWSER_ENGINE_ROADMAP Phase 1): no Playwright,
  Puppeteer, or Selenium — JSON over the fd3/fd4 pipe, and every byte on the
  wire is ours. The protocol is small: `{id, method, params}` out; `{id,
  result|error}` and `{method, params}` events back; a `sessionId` field scopes
  a message to an attached target (CDP "flat" mode).

  One process = one engine = one profile. Lifecycle:

    * `start_link/1` spawns the engine via `Launch.argv/2` and owns the port.
    * `command/4` correlates request → response by id; callers block with a
      deadline. Engine death fails every pending call loudly.
    * `subscribe/1` delivers events as `{:browser_control_event, method,
      params, session_id}` and death as `{:browser_control_exit, status}`.
    * `stop/2` is graceful-then-armed: `Browser.close`, await real exit, and
      only then escalate TERM → KILL on the OS pid. Because the shim `exec`s,
      that pid is the engine itself — no orphan (the Linux kill-pgid lesson
      from the shell rebuild, applied here from day one).
  """

  use GenServer
  require Logger

  alias BusterClaw.BrowserControl.{Frames, Launch}

  @default_command_timeout_ms 15_000
  @close_grace_ms 3_000
  @term_grace_ms 1_500

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Launch an engine and connect. Options: `:browser_path` (required),
  plus `Launch.argv/2` options (`:profile_dir` required, `:headless`, …).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Issue a CDP command and await its response: `{:ok, result_map}` or
  `{:error, {:cdp, %{"code" => _, "message" => _}}}` / `{:error, :browser_exited}`
  / `{:error, :timeout}`. `session_id: id` scopes to an attached target.
  """
  def command(server, method, params \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_command_timeout_ms)
    session_id = Keyword.get(opts, :session_id)

    try do
      GenServer.call(server, {:command, method, params, session_id}, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] -> {:error, :browser_exited}
    end
  end

  @doc "Subscribe the caller to engine events and the exit notification."
  def subscribe(server), do: GenServer.call(server, :subscribe)

  @doc "The engine's OS pid (the real one — the shim exec'd into it)."
  def os_pid(server), do: GenServer.call(server, :os_pid)

  @doc """
  Graceful stop: `Browser.close`, wait for the process to actually exit, then
  TERM → KILL as backstops. Returns `:ok` once the engine is gone.
  """
  def stop(server, timeout \\ @close_grace_ms + @term_grace_ms + 2_000) do
    ref = Process.monitor(server)
    GenServer.cast(server, :graceful_stop)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        GenServer.stop(server, :shutdown, 1_000)
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    browser = Keyword.fetch!(opts, :browser_path)
    args = Launch.argv(browser, opts)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :stream,
        :exit_status,
        args: args
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    {:ok,
     %{
       port: port,
       os_pid: os_pid,
       buffer: "",
       next_id: 1,
       pending: %{},
       subscribers: MapSet.new(),
       exit_status: nil
     }}
  end

  @impl true
  def handle_call({:command, _m, _p, _s}, _from, %{exit_status: status} = state)
      when status != nil do
    {:reply, {:error, :browser_exited}, state}
  end

  def handle_call({:command, method, params, session_id}, from, state) do
    id = state.next_id

    msg =
      %{"id" => id, "method" => method, "params" => params}
      |> then(&if session_id, do: Map.put(&1, "sessionId", session_id), else: &1)

    Port.command(state.port, Frames.encode(Jason.encode!(msg)))

    {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}
  end

  def handle_call(:subscribe, {pid, _tag}, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call(:os_pid, _from, state), do: {:reply, state.os_pid, state}

  @impl true
  def handle_cast(:graceful_stop, %{exit_status: nil} = state) do
    # Best-effort polite close; the engine's real exit lands as :exit_status,
    # which stops this server. The timer arms the TERM backstop for a wedged
    # engine that never exits.
    msg = %{"id" => state.next_id, "method" => "Browser.close", "params" => %{}}
    Port.command(state.port, Frames.encode(Jason.encode!(msg)))
    Process.send_after(self(), :close_overdue, @close_grace_ms)
    {:noreply, %{state | next_id: state.next_id + 1}}
  end

  def handle_cast(:graceful_stop, state), do: {:stop, :normal, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {frames, rest} = Frames.split(state.buffer <> data)
    {:noreply, Enum.reduce(frames, %{state | buffer: rest}, &handle_frame/2)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    for {_id, from} <- state.pending, do: GenServer.reply(from, {:error, :browser_exited})
    for pid <- state.subscribers, do: send(pid, {:browser_control_exit, status})
    {:stop, :normal, %{state | pending: %{}, exit_status: status}}
  end

  def handle_info(:close_overdue, state) do
    # Browser.close didn't produce an exit in time — escalate to TERM, arm KILL.
    signal(state.os_pid, "TERM")
    Process.send_after(self(), :term_overdue, @term_grace_ms)
    {:noreply, state}
  end

  def handle_info(:term_overdue, state) do
    signal(state.os_pid, "KILL")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Backstop only: a normal stop already saw :exit_status. Anything else —
    # supervisor shutdown, crash — must not leak a live engine process.
    if state.exit_status == nil and state.os_pid do
      signal(state.os_pid, "TERM")
      Process.sleep(300)
      if alive?(state.os_pid), do: signal(state.os_pid, "KILL")
    end

    :ok
  end

  # ── Frames ──────────────────────────────────────────────────────────────────

  defp handle_frame(frame, state) do
    case Jason.decode(frame) do
      {:ok, %{"id" => id} = msg} ->
        {from, pending} = Map.pop(state.pending, id)
        if from, do: GenServer.reply(from, response(msg))
        %{state | pending: pending}

      {:ok, %{"method" => method} = msg} ->
        event = {:browser_control_event, method, msg["params"] || %{}, msg["sessionId"]}
        for pid <- state.subscribers, do: send(pid, event)
        state

      _ ->
        Logger.warning("browser_control: undecodable CDP frame (#{byte_size(frame)} bytes)")
        state
    end
  end

  defp response(%{"error" => error}), do: {:error, {:cdp, error}}
  defp response(%{"result" => result}), do: {:ok, result}
  defp response(_), do: {:ok, %{}}

  defp signal(nil, _sig), do: :ok

  defp signal(os_pid, sig) do
    System.cmd("kill", ["-#{sig}", to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp alive?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true))
  rescue
    _ -> false
  end
end
