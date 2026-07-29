defmodule BusterClaw.TradingBroker.MCPClient do
  @moduledoc """
  Direct Streamable HTTP client for Robinhood's Trading MCP.

  The allowlist deliberately stops at reads and broker-side review. Order
  placement and cancellation are not reachable from this client yet.
  """

  alias BusterClaw.TradingBroker
  alias BusterClaw.TradingBroker.Connection
  alias BusterClaw.TradingBroker.OAuth

  @endpoint "https://agent.robinhood.com/mcp/trading"
  @protocol_version "2025-11-25"
  @max_pages 10
  @allowed_tools ~w(
    get_accounts
    get_portfolio
    get_equity_positions
    get_equity_orders
    get_equity_quotes
    review_equity_order
  )

  def endpoint, do: @endpoint

  @doc "Initialize a direct session and return the server's advertised tools."
  def list_tools(opts \\ []) do
    with_access_token(
      fn token ->
        with_session(token, opts, fn session_id ->
          list_tool_pages(token, session_id, nil, [], 0, opts)
        end)
      end,
      opts
    )
  end

  @doc "Call one explicitly allowlisted read/review tool."
  def call_tool(name, arguments, opts \\ [])

  def call_tool(name, arguments, opts)
      when name in @allowed_tools and is_map(arguments) do
    with_access_token(
      fn token ->
        with_session(token, opts, fn session_id ->
          case rpc(
                 token,
                 session_id,
                 "tools/call",
                 %{"name" => name, "arguments" => arguments},
                 opts
               ) do
            {:ok, result} -> normalize_tool_result(result)
            {:error, _reason} = error -> error
          end
        end)
      end,
      opts
    )
  end

  def call_tool(_name, _arguments, _opts), do: {:error, :broker_tool_not_allowed}

  @doc "Fetch and persist opaque account identities directly from Robinhood."
  def sync_accounts(opts \\ []) do
    with %Connection{} = connection <- TradingBroker.connection(),
         {:ok, result} <- call_tool("get_accounts", %{}, opts),
         {:ok, accounts} <- account_list(result),
         {:ok, stored} <- TradingBroker.replace_accounts(connection, accounts),
         {:ok, _connection} <- TradingBroker.mark_checked("connected") do
      {:ok, stored}
    else
      nil -> {:error, :broker_not_connected}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_broker_accounts}
    end
  end

  @doc "Verify authorization, protocol negotiation, tools, and account discovery."
  def health(opts \\ []) do
    with {:ok, tools} <- list_tools(opts),
         :ok <- required_tools_present(tools),
         {:ok, accounts} <- sync_accounts(opts) do
      {:ok,
       %{
         status: :connected,
         tools: Enum.map(tools, &Map.get(&1, "name")),
         accounts: accounts,
         agentic_account: TradingBroker.agentic_account()
       }}
    else
      {:error, :broker_reconnect_required} = error ->
        _ = TradingBroker.mark_checked("reconnect_required", :oauth_refresh_rejected)
        error

      {:error, reason} = error ->
        _ = TradingBroker.mark_checked("error", safe_reason(reason))
        error
    end
  end

  defp with_access_token(fun, opts) do
    with {:ok, token} <- OAuth.access_token(opts) do
      token
      |> fun.()
      |> retry_after_unauthorized(fun, opts)
    end
  end

  defp retry_after_unauthorized({:error, :broker_unauthorized}, fun, opts) do
    case TradingBroker.connection() do
      %Connection{} = connection ->
        with {:ok, refreshed} <- OAuth.refresh(connection, opts) do
          fun.(refreshed)
        end

      nil ->
        {:error, :broker_not_connected}
    end
  end

  defp retry_after_unauthorized(result, _fun, _opts), do: result

  defp with_session(token, opts, fun) do
    params = %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "buster-claw", "version" => app_version()}
    }

    with {:ok, response, session_id} <- raw_rpc(token, nil, "initialize", params, opts),
         {:ok, result} <- json_rpc_result(response),
         :ok <- validate_initialize_result(result),
         :ok <- initialized_notification(token, session_id, opts) do
      fun.(session_id)
    end
  end

  defp initialized_notification(token, session_id, opts) do
    payload = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

    case request(token, session_id, payload, opts) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_mcp_notification_response}
    end
  end

  defp list_tool_pages(_token, _session_id, _cursor, _tools, page, _opts)
       when page >= @max_pages,
       do: {:error, :broker_tool_pagination_limit}

  defp list_tool_pages(token, session_id, cursor, tools, page, opts) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    case rpc(token, session_id, "tools/list", params, opts) do
      {:ok, %{"tools" => page_tools} = result} when is_list(page_tools) ->
        collected = tools ++ Enum.filter(page_tools, &valid_tool?/1)

        case Map.get(result, "nextCursor") do
          next when is_binary(next) and next != "" ->
            list_tool_pages(token, session_id, next, collected, page + 1, opts)

          _other ->
            {:ok, collected}
        end

      {:ok, _result} ->
        {:error, :invalid_broker_tool_list}

      {:error, _reason} = error ->
        error
    end
  end

  defp rpc(token, session_id, method, params, opts) do
    with {:ok, response, _session_id} <- raw_rpc(token, session_id, method, params, opts) do
      json_rpc_result(response)
    end
  end

  defp raw_rpc(token, session_id, method, params, opts) do
    id = System.unique_integer([:positive, :monotonic])

    payload = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    case request(token, session_id, payload, opts) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        with {:ok, decoded} <- decode_response(response.body) do
          response_session =
            Req.Response.get_header(response, "mcp-session-id")
            |> List.first()
            |> then(&(&1 || session_id))

          {:ok, decoded, response_session}
        end

      {:ok, %{status: 401}} ->
        {:error, :broker_unauthorized}

      {:ok, %{status: status}} ->
        {:error, {:broker_mcp_http, status}}

      {:error, _reason} ->
        {:error, :broker_mcp_unreachable}
    end
  end

  defp request(token, session_id, payload, opts) do
    req_options =
      []
      |> Keyword.merge(Application.get_env(:buster_claw, :trading_broker_req_options, []))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    headers =
      [
        {"accept", "application/json, text/event-stream"},
        {"authorization", "Bearer " <> token},
        {"content-type", "application/json"},
        {"mcp-protocol-version", @protocol_version}
      ]
      |> maybe_put_session(session_id)

    [
      method: :post,
      url: @endpoint,
      headers: headers,
      json: payload,
      receive_timeout: 30_000,
      retry: false
    ]
    |> Keyword.merge(req_options)
    |> Req.request()
  end

  defp maybe_put_session(headers, session_id) when is_binary(session_id) and session_id != "",
    do: [{"mcp-session-id", session_id} | headers]

  defp maybe_put_session(headers, _session_id), do: headers

  defp decode_response(body) when is_map(body), do: {:ok, body}

  defp decode_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      _other ->
        decode_sse(body)
    end
  end

  defp decode_response(_body), do: {:error, :invalid_broker_mcp_response}

  defp decode_sse(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(&(&1 |> String.replace_prefix("data:", "") |> String.trim()))
    |> Enum.find_value({:error, :invalid_broker_mcp_response}, fn data ->
      case Jason.decode(data) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        _other -> nil
      end
    end)
  end

  defp json_rpc_result(%{"result" => result}), do: {:ok, result}

  defp json_rpc_result(%{"error" => %{"code" => code}})
       when is_integer(code),
       do: {:error, {:broker_mcp_error, code}}

  defp json_rpc_result(_response), do: {:error, :invalid_broker_mcp_response}

  defp validate_initialize_result(%{
         "protocolVersion" => @protocol_version,
         "capabilities" => capabilities
       })
       when is_map(capabilities),
       do: :ok

  defp validate_initialize_result(_result), do: {:error, :unsupported_broker_mcp_protocol}

  defp normalize_tool_result(%{"isError" => true}),
    do: {:error, :broker_tool_error}

  defp normalize_tool_result(%{"structuredContent" => content})
       when is_map(content) or is_list(content),
       do: {:ok, content}

  defp normalize_tool_result(%{"content" => content}) when is_list(content) do
    content
    |> Enum.find_value(fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, decoded} when is_map(decoded) or is_list(decoded) -> {:ok, decoded}
          _other -> nil
        end

      _other ->
        nil
    end)
    |> case do
      nil -> {:error, :unstructured_broker_tool_result}
      result -> result
    end
  end

  defp normalize_tool_result(_result), do: {:error, :invalid_broker_tool_result}

  defp account_list(accounts) when is_list(accounts), do: {:ok, accounts}
  defp account_list(%{"accounts" => accounts}) when is_list(accounts), do: {:ok, accounts}

  defp account_list(%{"data" => %{"accounts" => accounts}}) when is_list(accounts),
    do: {:ok, accounts}

  defp account_list(_result), do: {:error, :invalid_broker_accounts}

  defp required_tools_present(tools) do
    names = MapSet.new(tools, &Map.get(&1, "name"))

    if MapSet.member?(names, "get_accounts") and
         MapSet.member?(names, "review_equity_order") do
      :ok
    else
      {:error, :required_broker_tools_missing}
    end
  end

  defp valid_tool?(%{"name" => name, "inputSchema" => schema})
       when is_binary(name) and is_map(schema),
       do: true

  defp valid_tool?(_tool), do: false

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({:broker_mcp_http, status}) when is_integer(status), do: "mcp_http_#{status}"
  defp safe_reason({:broker_mcp_error, code}) when is_integer(code), do: "mcp_error_#{code}"
  defp safe_reason(_reason), do: :broker_connection_failed

  defp app_version do
    case Application.spec(:buster_claw, :vsn) do
      value when is_list(value) -> List.to_string(value)
      value when is_binary(value) -> value
      _other -> "0.0.0"
    end
  end
end
