defmodule BusterClaw.MCP.Client do
  @moduledoc "Port-backed MCP stdio client for one configured server."

  use GenServer

  alias BusterClaw.Automation.MCPServer
  alias BusterClaw.MCP

  @protocol_version "2024-11-05"
  @client_name "buster-claw"
  @client_version "0.1.0"
  @startup_timeout 5_000
  @stderr_limit 8_000

  def start_link(%MCPServer{} = server, opts \\ []) do
    GenServer.start_link(__MODULE__, {server, opts}, name: via(server.id))
  end

  def child_spec(%MCPServer{} = server) do
    %{
      id: {__MODULE__, server.id},
      start: {__MODULE__, :start_link, [server]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    }
  end

  def tools(pid, timeout \\ 5_000), do: GenServer.call(pid, :tools, timeout)
  def refresh_tools(pid, timeout \\ 5_000), do: GenServer.call(pid, :refresh_tools, timeout)
  def cached_tools(pid, timeout \\ 1_000), do: GenServer.call(pid, :cached_tools, timeout)

  def via(server_id), do: {:via, Registry, {BusterClaw.MCP.Registry, server_id}}

  @impl true
  def init({%MCPServer{} = server, opts}) do
    timeout = Keyword.get(opts, :timeout, @startup_timeout)

    with {:ok, port} <- open_port(server),
         state = new_state(server, port),
         {:ok, state} <- initialize(state, timeout) do
      {:ok, state}
    else
      {:error, reason} ->
        MCP.mark_unavailable(server, reason)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:tools, _from, state), do: {:reply, {:ok, state.tools}, state}

  def handle_call(:cached_tools, _from, state), do: {:reply, state.tools, state}

  def handle_call(:refresh_tools, _from, state) do
    case discover_tools(state, @startup_timeout) do
      {:ok, state} -> {:reply, {:ok, state.tools}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    MCP.mark_unavailable(state.server, {:exit_status, status, stderr_text(state)})
    {:stop, :normal, state}
  end

  def handle_info({_port, {:data, _data}}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  catch
    :error, _reason -> :ok
  end

  defp new_state(server, port) do
    %{
      server: server,
      port: port,
      next_id: 1,
      buffer: "",
      stderr: "",
      tools: []
    }
  end

  defp initialize(state, timeout) do
    params = %{
      protocolVersion: @protocol_version,
      capabilities: %{},
      clientInfo: %{name: @client_name, version: @client_version}
    }

    with {:ok, _result, state} <- request(state, "initialize", params, timeout),
         :ok <- notify(state, "notifications/initialized", %{}),
         {:ok, state} <- discover_tools(state, timeout),
         {:ok, server} <- mark_connected(state.server) do
      {:ok, %{state | server: server}}
    else
      {:error, reason, state} ->
        close_port(state)
        {:error, reason}

      {:error, reason} ->
        close_port(state)
        {:error, reason}
    end
  end

  defp discover_tools(state, timeout) do
    case request(state, "tools/list", %{}, timeout) do
      {:ok, %{"tools" => tools}, state} ->
        {:ok, %{state | tools: normalize_tools(tools)}}

      {:ok, _result, state} ->
        {:error, :missing_tools_list, state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp request(state, method, params, timeout) do
    id = state.next_id
    state = %{state | next_id: id + 1}

    payload =
      %{
        jsonrpc: "2.0",
        id: id,
        method: method
      }
      |> put_params(params)

    with :ok <- send_json(state.port, payload) do
      wait_for_response(state, id, deadline(timeout))
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp notify(state, method, params) do
    state.port
    |> send_json(%{jsonrpc: "2.0", method: method} |> put_params(params))
  end

  defp wait_for_response(state, id, deadline) do
    remaining = max(deadline - monotonic_ms(), 0)

    receive do
      {port, {:data, data}} when port == state.port ->
        {state, messages} = ingest_data(state, data)

        case response_for(messages, id) do
          {:ok, result} -> {:ok, result, state}
          {:error, reason} -> {:error, reason, state}
          :not_found -> wait_for_response(state, id, deadline)
        end

      {port, {:exit_status, status}} when port == state.port ->
        {:error, {:exit_status, status, stderr_text(state)}, state}
    after
      remaining ->
        {:error, {:timeout, stderr_text(state)}, state}
    end
  end

  defp ingest_data(state, data) do
    {lines, buffer} = complete_lines(state.buffer <> to_string(data))

    {messages, stderr} =
      Enum.reduce(lines, {[], state.stderr}, fn line, {messages, stderr} ->
        case decode_line(line) do
          {:ok, message} -> {[message | messages], stderr}
          {:stderr, text} -> {messages, bounded_stderr(stderr, text)}
          :ignore -> {messages, stderr}
        end
      end)

    {%{state | buffer: buffer, stderr: stderr}, Enum.reverse(messages)}
  end

  defp complete_lines(text) do
    parts = String.split(text, "\n")

    if String.ends_with?(text, "\n") do
      {Enum.reject(parts, &(&1 == "")), ""}
    else
      {parts |> Enum.drop(-1) |> Enum.reject(&(&1 == "")), List.last(parts) || ""}
    end
  end

  defp decode_line(line) do
    line = String.trim_trailing(line, "\r")

    cond do
      String.trim(line) == "" ->
        :ignore

      true ->
        case Jason.decode(line) do
          {:ok, %{} = message} -> {:ok, message}
          _error -> {:stderr, line}
        end
    end
  end

  defp response_for(messages, id) do
    Enum.find_value(messages, :not_found, fn
      %{"id" => ^id, "result" => result} -> {:ok, result}
      %{"id" => ^id, "error" => error} -> {:error, error}
      _message -> nil
    end)
  end

  defp open_port(%MCPServer{} = server) do
    with {:ok, executable} <- executable_path(server.command) do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: args_list(server.args),
          env: env_list(server.env)
        ])

      {:ok, port}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp executable_path(command) when is_binary(command) do
    command = String.trim(command)

    cond do
      command == "" ->
        {:error, :missing_command}

      String.contains?(command, "/") && File.exists?(command) ->
        {:ok, command}

      String.contains?(command, "/") ->
        {:error, {:command_not_found, command}}

      path = System.find_executable(command) ->
        {:ok, path}

      true ->
        {:error, {:command_not_found, command}}
    end
  end

  defp executable_path(_command), do: {:error, :missing_command}

  defp args_list(%{"items" => items}) when is_list(items), do: Enum.map(items, &to_string/1)
  defp args_list(%{"items" => item}) when item not in [nil, ""], do: [to_string(item)]
  defp args_list(_args), do: []

  defp env_list(env) when is_map(env) do
    env
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp env_list(_env), do: []

  defp send_json(port, payload) do
    Port.command(port, Jason.encode!(payload) <> "\n")
    :ok
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp put_params(payload, params) when params == %{}, do: payload
  defp put_params(payload, params), do: Map.put(payload, :params, params)

  defp normalize_tools(tools) when is_list(tools), do: Enum.filter(tools, &is_map/1)
  defp normalize_tools(_tools), do: []

  defp mark_connected(server) do
    MCP.update_server(server, %{
      last_status: "connected",
      last_error: nil,
      last_connected_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp bounded_stderr(stderr, text) do
    [stderr, text]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> String.slice(0, @stderr_limit)
  end

  defp stderr_text(state), do: state.stderr || ""
  defp deadline(timeout), do: monotonic_ms() + timeout
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp close_port(%{port: port}) do
    if Port.info(port), do: Port.close(port)
  catch
    :error, _reason -> :ok
  end
end
