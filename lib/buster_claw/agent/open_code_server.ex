defmodule BusterClaw.Agent.OpenCodeServer do
  @moduledoc """
  One supervised `opencode serve` for the whole application, multiplexing every
  OpenCode conversation over it by session id.

  Same shape as `BusterClaw.Agent.CodexAppServer`, for the same reason: threads
  and sessions are cheap, servers are not.

  ## What Phase 0 established, and what it forces

  `scripts/probe_opencode_server.exs`, against opencode 1.18.3:

  * **It steers.** A prompt submitted while the session was busy redirected the
    *active* run — step 1 finished, the redirect ran, steps 2 and 3 never did,
    and there was exactly one `session.idle` at the end.
  * ⚠ **v1 is the only API that runs.** The v2 surface (`/api/session/…`)
    natively models `delivery: "steer" | "queue"` with a proper receipt, and
    then never executes: a v2 session parks the prompt in a `session.next.*`
    buffer awaiting a driver we are not. v1 `/session/{id}/prompt_async` is what
    works. Re-check v2 on every upgrade; when it self-drives it is the better
    target by a distance.
  * ⚠ **v1 returns an EMPTY body.** There is no admission receipt in the HTTP
    response at all. Acceptance is derived from the SSE `message.updated` that
    follows ~20ms later, keyed on a `messageID` we supply — never from the HTTP
    call. This is why `await_receipt/3` exists.
  * ⚠ **Confinement fails open and the API will not say so.** A session created
    with a nonexistent `agent` is accepted, echoes the bogus name back on create
    AND re-fetch, then admits a prompt. The server is strictly worse than the
    CLI, which at least prints the line `AgentBackend.fallback_warning?/2`
    scrapes. **So this module refuses to create a confined session at all** —
    see `create_session/3`. General chat is unaffected.

  ## Auth

  Basic, and the username is literally `opencode` — an empty username is
  rejected with 401. The password is generated per boot and passed through the
  environment, never argv, so it cannot be read out of `ps`.
  """

  use GenServer

  require Logger

  alias BusterClaw.Agent.StreamEvent
  alias BusterClaw.AgentBackend
  alias BusterClaw.AgentRunner

  @name __MODULE__
  @user "opencode"
  @call_timeout 30_000
  @boot_timeout 30_000

  # Measured at ~20ms. A generous ceiling: the cost of waiting is a brief pause
  # in one conversation, and the cost of NOT waiting is claiming a delivery we
  # cannot prove.
  @receipt_timeout 2_000

  # --- public API ----------------------------------------------------------

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, @name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "True when the opencode CLI is present, so callers can degrade rather than crash."
  def available?, do: AgentBackend.available?(:opencode)

  @doc """
  Create a session and register `ref` for its events.

  **Refuses a confined session.** `opts[:agent]` names an agent file, and Phase 0
  proved the server neither validates it nor reports the fallback — so a caller
  asking for confinement would silently get `{"*", allow, "*"}` instead. Refusing
  is the only honest answer available; `{:error, :confinement_unsupported}`.
  """
  def create_session(server \\ @name, ref, opts) do
    if opts[:agent] do
      {:error, :confinement_unsupported}
    else
      GenServer.call(server, {:create_session, ref, self(), opts}, @call_timeout)
    end
  end

  @doc "Re-register `ref` for a session that already exists."
  def attach_session(server \\ @name, ref, session_id),
    do: GenServer.call(server, {:attach_session, ref, self(), session_id}, @call_timeout)

  @doc """
  Send `text` to `session_id`, asynchronously.

  Returns `{:ok, message_id}` once the server has taken the request. That is
  **not** proof of acceptance — pair it with `await_receipt/3`.
  """
  def prompt(server \\ @name, session_id, text, opts \\ []),
    do: GenServer.call(server, {:prompt, session_id, text, opts}, @call_timeout)

  @doc """
  Block the CALLER (not this server) until the SSE echo for `message_id` lands.

  The only evidence OpenCode offers that a message was accepted. Returns
  `:ok`, or `{:error, :timeout}` — which does **not** mean the message was lost;
  it means we cannot prove it arrived, and the caller must say so rather than
  claiming a steer.
  """
  def await_receipt(ref, message_id, timeout \\ @receipt_timeout) do
    receive do
      {:chat_receipt, ^ref, ^message_id} -> :ok
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc "Abort the session's active run."
  def abort(server \\ @name, session_id),
    do: GenServer.call(server, {:abort, session_id}, @call_timeout)

  @doc "Forget a conversation's registration."
  def unregister(server \\ @name, ref), do: GenServer.cast(server, {:unregister, ref})

  # --- GenServer -----------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       port: nil,
       base: nil,
       password: nil,
       sse: nil,
       sse_buf: "",
       # session_id => {ref, pid}
       sessions: %{},
       refs: %{},
       # message_id => role, so a text PART can be attributed. SSE part events
       # carry no role of their own.
       roles: %{},
       # session_id => accumulated cost for the turn in flight
       turn_cost: %{},
       # Tool part ids already announced to the transcript. OpenCode re-sends
       # `message.part.updated` for the SAME part as its state advances, so
       # without this a single command appears three or four times.
       tools_seen: MapSet.new(),
       booter: Keyword.get(opts, :booter, &default_boot/1),
       http: Keyword.get(opts, :http, &default_http/1),
       # Injectable alongside `:booter` and `:http` so a test never opens a real
       # socket. Without this the reader dials a port nothing is listening on
       # and Req's retry logic turns a quiet suite into a noisy one.
       sse_starter: Keyword.get(opts, :sse_starter, &default_sse/3)
     }}
  end

  @impl true
  def handle_call({:create_session, ref, pid, opts}, _from, state) do
    with {:ok, state} <- ensure_running(state),
         {:ok, body} <- post(state, "/session", %{"title" => opts[:title] || "Buster Claw"}) do
      case body["id"] do
        nil -> {:reply, {:error, {:bad_session_response, body}}, state}
        id -> {:reply, {:ok, id}, register(state, id, ref, pid)}
      end
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:attach_session, ref, pid, session_id}, _from, state) do
    case ensure_running(state) do
      {:ok, state} -> {:reply, {:ok, session_id}, register(state, session_id, ref, pid)}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:prompt, session_id, text, opts}, _from, state) do
    message_id = opts[:message_id] || generate_message_id()

    body =
      %{
        "messageID" => message_id,
        "parts" => [%{"type" => "text", "text" => text}]
      }
      |> maybe_put("model", model_ref(opts[:model]))

    # A new turn starts here, so the accumulated per-turn cost restarts with it.
    state = %{state | turn_cost: Map.put(state.turn_cost, session_id, 0.0)}

    case post(state, "/session/#{session_id}/prompt_async", body) do
      {:ok, _body} -> {:reply, {:ok, message_id}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:abort, session_id}, _from, state) do
    case post(state, "/session/#{session_id}/abort", %{}) do
      {:ok, _body} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:unregister, ref}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {session_id, refs} ->
        {:noreply, %{state | refs: refs, sessions: Map.delete(state.sessions, session_id)}}
    end
  end

  @impl true
  def handle_info({:sse_chunk, data}, state) do
    {lines, buf} = split_lines(state.sse_buf <> data)
    {:noreply, Enum.reduce(lines, %{state | sse_buf: buf}, &sse_line/2)}
  end

  # The SSE reader died. Reconnect with a bounded delay rather than hammering:
  # the server itself may still be fine, and a tight loop would make a blip
  # into an outage.
  def handle_info({:sse_down, reason}, state) do
    Logger.warning("OpenCodeServer SSE reader stopped (#{inspect(reason)}); reconnecting")
    Process.send_after(self(), :sse_reconnect, 500)
    {:noreply, %{state | sse: nil, sse_buf: ""}}
  end

  def handle_info(:sse_reconnect, %{base: nil} = state), do: {:noreply, state}
  def handle_info(:sse_reconnect, state), do: {:noreply, start_sse(state)}

  def handle_info({port, {:data, _data}}, %{port: port} = state), do: {:noreply, state}

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("OpenCodeServer exited with status #{code}")
    notify_all_down(state, {:exit_status, code})
    {:stop, {:server_exited, code}, %{state | port: nil, base: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    notify_all_down(state, reason)
    if is_port(state.port), do: AgentRunner.kill_port(state.port)
    :ok
  end

  # --- boot ----------------------------------------------------------------

  defp ensure_running(%{base: base} = state) when is_binary(base) do
    if is_port(state.port) and Port.info(state.port) == nil,
      do: {:error, :server_down, %{state | port: nil, base: nil}},
      else: {:ok, state}
  end

  defp ensure_running(state) do
    password = generate_password()

    case state.booter.(password) do
      {:ok, port, base} ->
        {:ok, start_sse(%{state | port: port, base: base, password: password})}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # `--port 0` asks the OS for a free one and the server prints where it landed,
  # so nothing here guesses a port or races another process for it. The password
  # goes through the environment: argv is visible in `ps`.
  defp default_boot(password) do
    parent = self()

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :hide,
        {:args,
         [
           "-lc",
           ~s|exec perl -e 'setpgrp(0,0); exec @ARGV or exit 127' "$@" 2>&1|,
           "sh",
           System.find_executable("opencode") || "opencode",
           "serve",
           "--port",
           "0",
           "--hostname",
           "127.0.0.1"
         ]},
        {:env, [{~c"OPENCODE_SERVER_PASSWORD", String.to_charlist(password)}]}
      ])

    case await_listening(port, "", System.monotonic_time(:millisecond) + @boot_timeout) do
      {:ok, base} ->
        send(parent, :noop)
        {:ok, port, base}

      {:error, reason} ->
        AgentRunner.kill_port(port)
        {:error, reason}
    end
  end

  # The server announces its port on stdout; there is no other way to learn it
  # when it was assigned by the OS.
  defp await_listening(port, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        acc = acc <> data

        case Regex.run(~r{listening on (http://127\.0\.0\.1:\d+)}, acc) do
          [_, base] -> {:ok, base}
          nil -> await_listening(port, acc, deadline)
        end

      {^port, {:exit_status, code}} ->
        {:error, {:server_exited, code}}
    after
      remaining -> {:error, :boot_timeout}
    end
  end

  # --- SSE -----------------------------------------------------------------

  defp start_sse(state) do
    %{state | sse: state.sse_starter.(self(), state.base, state.password), sse_buf: ""}
  end

  # Chunks are forwarded to the connection rather than parsed here, so all the
  # per-session routing state stays in one process.
  defp default_sse(parent, base, password) do
    {:ok, pid} =
      Task.start(fn ->
        result =
          Req.get(base <> "/event",
            auth: {:basic, "#{@user}:#{password}"},
            receive_timeout: :infinity,
            into: fn {:data, data}, acc ->
              send(parent, {:sse_chunk, data})
              {:cont, acc}
            end
          )

        send(parent, {:sse_down, result})
      end)

    pid
  end

  defp sse_line("data: " <> payload, state) do
    case Jason.decode(String.trim(payload)) do
      {:ok, %{} = event} -> handle_event(state, event)
      _ -> state
    end
  end

  defp sse_line(_line, state), do: state

  # Learn which message ids belong to the assistant, and fire the acceptance
  # receipt when one of OUR user messages comes back. SSE part events carry no
  # role, so this map is what lets a text part be attributed at all.
  defp handle_event(state, %{"type" => "message.updated", "properties" => %{"info" => info}}) do
    id = info["id"]
    role = info["role"]
    state = %{state | roles: Map.put(state.roles, id, role)}

    if role == "user", do: receipt(state, info["sessionID"], id)
    state
  end

  # Per-step cost accumulates into the turn. OpenCode reports cost per step, not
  # per turn, and summing here is what lets the transcript show a turn's spend
  # without inventing a number.
  defp handle_event(state, %{"type" => "message.part.updated", "properties" => %{"part" => part}}) do
    state = accumulate_cost(state, part)

    if tool_repeat?(state, part) do
      # Already announced. OpenCode re-sends a tool part on every state change
      # (pending -> running -> completed), and the other two backends emit one
      # transcript line per tool call — so forwarding each update would make
      # opencode's transcript the odd one out, with a command repeated three or
      # four times.
      state
    else
      role = Map.get(state.roles, part["messageID"])

      state
      |> remember_tool(part)
      |> forward(part["sessionID"], Map.put(%{"type" => "part", "part" => part}, "role", role))
    end
  end

  # The turn boundary. Exactly one per run, measured — including a run that was
  # steered mid-flight, which is how Phase 0 proved the steer joined the ACTIVE
  # turn rather than starting a second one.
  defp handle_event(state, %{"type" => "session.idle", "properties" => %{"sessionID" => id}}) do
    cost = Map.get(state.turn_cost, id, 0.0)

    state
    |> forward(id, %{"type" => "idle", "cost" => cost})
    |> Map.update!(:turn_cost, &Map.put(&1, id, 0.0))
    # The turn is over, so its part ids can never repeat again. Clearing bounds
    # the set on a long conversation.
    |> Map.put(:tools_seen, MapSet.new())
  end

  defp handle_event(state, _event), do: state

  # A tool part is announced ONCE, on the first update that actually carries its
  # arguments. An earlier update with an empty input would render as a bare tool
  # name with no command — which is the `bash` with nothing after it that the
  # acceptance smoke showed.
  defp tool_repeat?(state, %{"type" => "tool", "id" => id} = part) do
    MapSet.member?(state.tools_seen, id) or empty_input?(part)
  end

  defp tool_repeat?(_state, _part), do: false

  defp empty_input?(part) do
    case get_in(part, ["state", "input"]) do
      input when is_map(input) and map_size(input) > 0 -> false
      _ -> get_in(part, ["state", "status"]) != "completed"
    end
  end

  defp remember_tool(state, %{"type" => "tool", "id" => id}),
    do: %{state | tools_seen: MapSet.put(state.tools_seen, id)}

  defp remember_tool(state, _part), do: state

  defp accumulate_cost(state, %{"cost" => cost, "sessionID" => id}) when is_number(cost),
    do: %{state | turn_cost: Map.update(state.turn_cost, id, cost, &(&1 + cost))}

  defp accumulate_cost(state, _part), do: state

  defp receipt(state, session_id, message_id) do
    case Map.get(state.sessions, session_id) do
      {ref, pid} -> send(pid, {:chat_receipt, ref, message_id})
      nil -> :ok
    end
  end

  defp forward(state, session_id, payload) do
    case Map.get(state.sessions, session_id) do
      {ref, pid} ->
        send(pid, {:chat_event, ref, StreamEvent.normalize(:opencode_server, payload)})
        state

      nil ->
        state
    end
  end

  # --- HTTP ----------------------------------------------------------------

  defp post(%{base: nil}, _path, _body), do: {:error, :server_down}

  defp post(state, path, body) do
    state.http.(%{
      method: :post,
      url: state.base <> path,
      auth: {@user, state.password},
      json: body
    })
  end

  defp default_http(%{method: :post, url: url, auth: {user, password}, json: body}) do
    case Req.post(url, auth: {:basic, "#{user}:#{password}"}, json: body, receive_timeout: 30_000) do
      # `prompt_async` answers with an EMPTY body. A 2xx with nothing in it is a
      # success here, not a malformed response — and emphatically not a receipt.
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, if(is_map(body), do: body, else: %{})}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # --- helpers -------------------------------------------------------------

  defp register(state, session_id, ref, pid),
    do: %{
      state
      | sessions: Map.put(state.sessions, session_id, {ref, pid}),
        refs: Map.put(state.refs, ref, session_id)
    }

  defp notify_all_down(state, reason) do
    Enum.each(state.sessions, fn {_id, {ref, pid}} ->
      send(pid, {:chat_transport_down, ref, reason})
    end)
  end

  defp model_ref(nil), do: nil

  defp model_ref(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider, id] -> %{"providerID" => provider, "modelID" => id}
      # A bare id is not valid in opencode's namespace (it needs
      # `provider/model`), so sending one would be a request the server rejects.
      # Omitting it leaves the operator's own default in charge.
      _ -> nil
    end
  end

  defp generate_password,
    do: "bc-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  defp generate_message_id,
    do: "msg_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)
    {complete, rest}
  end
end
