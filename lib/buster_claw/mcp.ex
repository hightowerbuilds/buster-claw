defmodule BusterClaw.MCP do
  @moduledoc "MCP server configuration and visible runtime status."

  alias BusterClaw.Automation
  alias BusterClaw.Automation.MCPServer

  def list_servers, do: Automation.list_mcp_servers()
  def get_server!(id), do: Automation.get_mcp_server!(id)

  def create_server(attrs) do
    attrs
    |> normalize_map_fields()
    |> Automation.create_mcp_server()
    |> broadcast_change()
  end

  def update_server(%MCPServer{} = server, attrs) do
    attrs
    |> normalize_map_fields()
    |> then(&Automation.update_mcp_server(server, &1))
    |> broadcast_change()
  end

  def delete_server(%MCPServer{} = server) do
    BusterClaw.MCP.Supervisor.stop_server(server)

    server
    |> Automation.delete_mcp_server()
    |> broadcast_change()
  end

  def start_enabled_servers, do: BusterClaw.MCP.Supervisor.start_enabled_servers()

  def connect_server(id) when is_binary(id) or is_integer(id) do
    id
    |> get_server!()
    |> connect_server()
  end

  def connect_server(%MCPServer{} = server), do: BusterClaw.MCP.Supervisor.start_server(server)

  def discover_tools(id) when is_binary(id) or is_integer(id) do
    id
    |> get_server!()
    |> discover_tools()
  end

  def discover_tools(%MCPServer{} = server), do: BusterClaw.MCP.Supervisor.discover_tools(server)

  def mark_unavailable(%MCPServer{} = server, reason) do
    update_server(server, %{
      last_status: "unavailable",
      last_error: inspect(reason),
      last_connected_at: nil
    })
  end

  def tool_summary do
    case list_servers() do
      [] ->
        "No MCP servers configured."

      servers ->
        servers
        |> Enum.map_join("\n", fn server ->
          status = server.last_status || if(server.enabled, do: "configured", else: "disabled")
          tools = tool_count(server)
          "- #{server.name}: #{status}#{tools} (`#{server.command}`)"
        end)
    end
  end

  def topic, do: "mcp"

  defp normalize_map_fields(attrs) do
    attrs
    |> normalize_json_map(:args)
    |> normalize_json_map("args")
    |> normalize_json_map(:env)
    |> normalize_json_map("env")
  end

  defp normalize_json_map(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        Map.put(attrs, key, decode_json_map(value))

      _ ->
        attrs
    end
  end

  defp decode_json_map(""), do: %{}

  defp decode_json_map(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp broadcast_change({:ok, result} = ok) do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, topic(), {:mcp_changed, result})
    ok
  end

  defp broadcast_change(other), do: other

  defp tool_count(server) do
    case BusterClaw.MCP.Supervisor.cached_tools(server) do
      {:ok, tools} -> " (#{length(tools)} tools)"
      _other -> ""
    end
  end
end
