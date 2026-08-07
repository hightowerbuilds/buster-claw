defmodule BusterClaw.Agent.CodexAppServer do
  @moduledoc """
  One `codex app-server` connection for the whole application, multiplexing
  every Codex conversation over it by thread id.

  ## Why this exists

  `codex exec` is the wrong surface for an interactive chat, and the cost of
  using it anyway was not just missing steering — **a Codex chat forgot
  everything between turns**. `codex exec resume <id>` is a subcommand, not a
  flag, so `Chat` could not express it and deliberately started fresh each time
  rather than appending a flag codex would reject. App Server fixes both at
  once: the thread id is durable and later turns append to it.

  Measured against codex-cli 0.146.0 by `scripts/probe_codex_appserver.exs`:

  * `turn/start` returns as soon as the turn EXISTS (`{turn: {id, status:
    "inProgress"}}`) and the work streams as notifications — which is what makes
    a running turn addressable.
  * `turn/steer` takes `expectedTurnId` and returns `{turnId}`. A wrong id while
    a turn is active, and any id after it finished, are both refused with
    `-32600`. **The completion race is guarded by the protocol.**
  * `clientUserMessageId` is a native field, echoed back on the `userMessage`
    item — a real receipt, not an assumption.

  ## One connection, not one per tab

  A codex app-server boots the operator's MCP servers on every thread, so a
  server per conversation would multiply that cost by the number of open tabs.
  Threads are cheap; servers are not. Conversations register a `ref` against
  their thread id and this process routes notifications to them.

  ## Failure

  If the connection dies, every registered conversation is told
  (`{:chat_transport_down, ref, reason}`) and this process exits so its
  supervisor restarts it clean. Thread ids are durable, so the next message
  resumes rather than starting over — the same contract the duplex Claude
  transport has.

  ⚠ App Server does **not** scope MCP any more than `codex exec` does. That is
  unchanged, not worsened, and it remains the reason the money surfaces stay
  Claude-pinned.
  """

  use GenServer

  require Logger

  alias BusterClaw.Agent.StreamEvent
  alias BusterClaw.AgentBackend
  alias BusterClaw.AgentRunner

  @name __MODULE__
  @call_timeout 30_000

  # --- public API ----------------------------------------------------------

  def start_link(opts \\ []) do
    # `name: nil` starts an UNREGISTERED connection, addressed by pid. Tests use
    # it so several can run concurrently without colliding on the singleton name
    # — and without minting a fresh atom per run to work around it.
    case Keyword.get(opts, :name, @name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Begin a thread and register `ref` to receive its events.

  `opts` carries `:cwd`, `:sandbox`, and `:model`. Returns `{:ok, thread_id}`.
  """
  def start_thread(server \\ @name, ref, opts),
    do: GenServer.call(server, {:start_thread, ref, self(), opts}, @call_timeout)

  @doc "Re-register `ref` for an existing thread, after a restart on either side."
  def resume_thread(server \\ @name, ref, thread_id, opts),
    do: GenServer.call(server, {:resume_thread, ref, self(), thread_id, opts}, @call_timeout)

  @doc "Begin a turn. Returns `{:ok, turn_id}` as soon as the turn exists."
  def start_turn(server \\ @name, thread_id, text, opts \\ []),
    do: GenServer.call(server, {:start_turn, thread_id, text, opts}, @call_timeout)

  @doc """
  Deliver `text` into `turn_id`, which is expected to still be running.

  `{:error, :no_active_turn}` covers both protocol refusals — a stale id and a
  finished turn — because `Chat` treats them identically: demote to the front of
  the queue, never apply to whatever turn is current.
  """
  def steer(server \\ @name, thread_id, turn_id, text, opts \\ []),
    do: GenServer.call(server, {:steer, thread_id, turn_id, text, opts}, @call_timeout)

  @doc "Stop `turn_id`. The thread survives."
  def interrupt(server \\ @name, thread_id, turn_id),
    do: GenServer.call(server, {:interrupt, thread_id, turn_id}, @call_timeout)

  @doc "Forget a conversation's registration (its tab closed)."
  def unregister(server \\ @name, ref), do: GenServer.cast(server, {:unregister, ref})

  @doc "True when the codex CLI is present, so callers can degrade rather than crash."
  def available?, do: AgentBackend.available?(:codex)

  # --- GenServer -----------------------------------------------------------

  @impl true
  def init(opts) do
    # The port is opened lazily on first use: a machine with no codex installed,
    # or an operator who never opens a codex chat, should not pay for a process
    # that boots their MCP servers.
    {:ok,
     %{
       port: nil,
       buf: "",
       next_id: 1,
       pending: %{},
       # thread_id => {ref, chat_pid}
       threads: %{},
       # ref => thread_id, for unregistering without a scan
       refs: %{},
       spawner: Keyword.get(opts, :spawner, &default_spawner/0),
       initialized?: false
     }}
  end

  @impl true
  def handle_call({:start_thread, ref, pid, opts}, _from, state) do
    with {:ok, state} <- ensure_connected(state),
         {:ok, state, result} <- request(state, "thread/start", thread_params(opts)) do
      case thread_id_from(result) do
        nil ->
          {:reply, {:error, {:bad_thread_response, result}}, state}

        thread_id ->
          {:reply, {:ok, thread_id}, register(state, thread_id, ref, pid)}
      end
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # `thread/resume` is what makes a codex conversation continuous across an
  # app-server restart. The thread id outlives the process on both sides.
  def handle_call({:resume_thread, ref, pid, thread_id, opts}, _from, state) do
    with {:ok, state} <- ensure_connected(state),
         {:ok, state, _result} <-
           request(state, "thread/resume", Map.put(thread_params(opts), "threadId", thread_id)) do
      {:reply, {:ok, thread_id}, register(state, thread_id, ref, pid)}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_turn, thread_id, text, opts}, _from, state) do
    params =
      %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => text}]
      }
      |> maybe_put("clientUserMessageId", opts[:client_message_id])
      |> maybe_put("model", opts[:model])

    case request(state, "turn/start", params) do
      {:ok, state, result} ->
        {:reply, {:ok, get_in(result, ["turn", "id"]) || result["turnId"]}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:steer, thread_id, turn_id, text, opts}, _from, state) do
    params =
      %{
        "threadId" => thread_id,
        "expectedTurnId" => turn_id,
        "input" => [%{"type" => "text", "text" => text}]
      }
      |> maybe_put("clientUserMessageId", opts[:client_message_id])

    case request(state, "turn/steer", params) do
      {:ok, state, result} ->
        {:reply, {:ok, result["turnId"] || turn_id}, state}

      # -32600 is both "wrong expectedTurnId" and "no active turn to steer".
      # They differ only in the message, and `Chat` does the same thing with
      # either: the message becomes the next turn rather than being applied to
      # one the operator never saw.
      {:error, %{"code" => -32_600}, state} ->
        {:reply, {:error, :no_active_turn}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:interrupt, thread_id, turn_id}, _from, state) do
    case request(state, "turn/interrupt", %{"threadId" => thread_id, "turnId" => turn_id}) do
      {:ok, state, _result} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:unregister, ref}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {thread_id, refs} ->
        {:noreply, %{state | refs: refs, threads: Map.delete(state.threads, thread_id)}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, buf} = split_lines(state.buf <> data)
    {:noreply, Enum.reduce(lines, %{state | buf: buf}, &route_line/2)}
  end

  # The connection died. Tell every conversation so their in-flight turn fails
  # visibly instead of hanging, then stop so the supervisor restarts us clean.
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("CodexAppServer exited with status #{code}")
    notify_all_down(state, {:exit_status, code})
    {:stop, {:app_server_exited, code}, %{state | port: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    notify_all_down(state, reason)
    if is_port(state.port), do: AgentRunner.kill_port(state.port)
    :ok
  end

  # --- connection ----------------------------------------------------------

  defp ensure_connected(%{port: port} = state) when is_port(port) do
    if Port.info(port) == nil,
      do: {:error, :app_server_down, %{state | port: nil}},
      else: {:ok, state}
  end

  defp ensure_connected(state) do
    case state.spawner.() do
      {:ok, port} -> initialize(%{state | port: port, buf: "", initialized?: false})
      {:error, reason} -> {:error, reason, state}
    end
  end

  # One handshake per connection. The schema defines no client notifications, so
  # there is no `initialized` follow-up to send — verified from the generated
  # bundle rather than assumed from other JSON-RPC protocols.
  defp initialize(state) do
    params = %{
      "clientInfo" => %{
        "name" => "buster-claw",
        "title" => "Buster Claw",
        "version" => to_string(Application.spec(:buster_claw, :vsn) || "0.0.0")
      }
    }

    case request(state, "initialize", params) do
      {:ok, state, _result} -> {:ok, %{state | initialized?: true}}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp default_spawner do
    case AgentRunner.open_duplex("", agent: :codex, argv: ["app-server"], login: true) do
      {:ok, %{port: port}} -> {:ok, port}
      {:error, _reason} = error -> error
    end
  end

  # --- JSON-RPC ------------------------------------------------------------
  #
  # Synchronous from the caller's point of view, and blocking inside this
  # GenServer while a reply is outstanding. That is deliberate: every request
  # here returns in milliseconds (`turn/start` answers as soon as the turn
  # EXISTS — the work streams afterwards as notifications), so there is nothing
  # long-running to serialise behind.

  defp request(%{port: nil} = state, _method, _params), do: {:error, :app_server_down, state}

  defp request(state, method, params) do
    id = state.next_id
    state = %{state | next_id: id + 1}

    line =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

    Port.command(state.port, line <> "\n")
    await(state, id, System.monotonic_time(:millisecond) + @call_timeout)
  rescue
    ArgumentError -> {:error, :app_server_down, %{state | port: nil}}
  end

  defp await(state, id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    port = state.port

    receive do
      {^port, {:data, data}} ->
        {lines, buf} = split_lines(state.buf <> data)
        {state, reply} = Enum.reduce(lines, {%{state | buf: buf}, nil}, &consume(&1, &2, id))

        case reply do
          nil -> await(state, id, deadline)
          {:ok, result} -> {:ok, state, result}
          {:error, error} -> {:error, error, state}
        end

      {^port, {:exit_status, code}} ->
        notify_all_down(state, {:exit_status, code})
        {:error, {:app_server_exited, code}, %{state | port: nil}}
    after
      remaining -> {:error, :timeout, state}
    end
  end

  # Notifications seen while waiting for a reply are routed exactly as they are
  # outside a request — a turn's whole event stream can arrive while a later
  # `turn/steer` is in flight, and dropping it would blank the transcript.
  defp consume(line, {state, reply}, id) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"id" => ^id} = msg} ->
        {state, if(msg["error"], do: {:error, msg["error"]}, else: {:ok, msg["result"] || %{}})}

      {:ok, %{"method" => _} = notification} ->
        {route(state, notification), reply}

      _ ->
        {state, reply}
    end
  end

  defp route_line(line, state) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"method" => _} = notification} -> route(state, notification)
      # A reply with no one waiting — a timed-out request's late answer.
      _ -> state
    end
  end

  # Notifications carry `threadId` in params (except `thread/started`, which
  # carries the thread itself). Anything we cannot attribute is logged at debug
  # and dropped rather than crashing the connection: an unknown notification is
  # a codex release adding a feature, not an error.
  defp route(state, notification) do
    case thread_of(notification) do
      nil ->
        state

      thread_id ->
        case Map.get(state.threads, thread_id) do
          {ref, pid} ->
            send(pid, {:chat_event, ref, StreamEvent.normalize(:codex_app_server, notification)})
            state

          nil ->
            state
        end
    end
  end

  defp thread_of(%{"params" => %{"threadId" => id}}) when is_binary(id), do: id
  defp thread_of(%{"params" => %{"thread" => %{"id" => id}}}) when is_binary(id), do: id
  defp thread_of(_notification), do: nil

  # NOTE on ordering: codex emits `thread/started` immediately after answering
  # `thread/start`, which is BEFORE the caller has been registered against the
  # new thread id — so that one notification is always dropped. Nothing depends
  # on it: the thread id comes from the response, and the transport puts it on
  # the handle where `Chat` reads it. Every event that matters (`item/*`,
  # `turn/*`) arrives after a `turn/start`, long after registration.

  # --- helpers -------------------------------------------------------------

  defp register(state, thread_id, ref, pid),
    do: %{
      state
      | threads: Map.put(state.threads, thread_id, {ref, pid}),
        refs: Map.put(state.refs, ref, thread_id)
    }

  defp notify_all_down(state, reason) do
    Enum.each(state.threads, fn {_thread_id, {ref, pid}} ->
      send(pid, {:chat_transport_down, ref, reason})
    end)
  end

  # `SandboxMode` is the same three-value enum `AgentBackend.permission_args/2`
  # already emits as `-s`, so the confinement translation is one-to-one and
  # needs no new judgement call. `bypassPermissions` deliberately does NOT become
  # `danger-full-access` — see AgentBackend's moduledoc for why that mapping is
  # an escalation rather than a translation.
  defp thread_params(opts) do
    %{"sandbox" => sandbox_for(opts[:permission_mode])}
    |> maybe_put("cwd", opts[:cwd])
    |> maybe_put("model", opts[:model])
    |> maybe_put("developerInstructions", opts[:instructions])
    |> Map.put("approvalPolicy", "never")
  end

  defp sandbox_for("dontAsk"), do: "read-only"
  defp sandbox_for(_other), do: "workspace-write"

  defp thread_id_from(%{"threadId" => id}) when is_binary(id), do: id
  defp thread_id_from(%{"thread" => %{"id" => id}}) when is_binary(id), do: id
  defp thread_id_from(_result), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)
    {complete, rest}
  end
end
