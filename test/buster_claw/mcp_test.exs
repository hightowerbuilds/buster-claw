defmodule BusterClaw.MCPTest do
  use BusterClaw.DataCase

  alias BusterClaw.MCP

  test "creates configured MCP server and formats tool summary" do
    assert {:ok, server} =
             MCP.create_server(%{
               name: "filesystem",
               command: "npx",
               args: ~s({"items":["-y","@modelcontextprotocol/server-filesystem"]}),
               env: ~s({"ROOT":"/tmp"})
             })

    assert server.args == %{"items" => ["-y", "@modelcontextprotocol/server-filesystem"]}
    assert server.env == %{"ROOT" => "/tmp"}
    assert MCP.tool_summary() =~ "filesystem"
    assert MCP.tool_summary() =~ "configured"
  end

  test "connects a stdio MCP server and discovers tools" do
    assert {:ok, server} =
             MCP.create_server(%{
               name: "fake-stdio",
               command: "/bin/sh",
               args: %{"items" => ["-c", fake_mcp_script()]},
               env: %{}
             })

    on_exit(fn -> BusterClaw.MCP.Supervisor.stop_server(server) end)

    assert {:ok, tools} = MCP.discover_tools(server)

    assert [
             %{
               "name" => "fake_echo",
               "description" => "Echoes text",
               "inputSchema" => %{"type" => "object"}
             }
           ] = tools

    updated = MCP.get_server!(server.id)
    assert updated.last_status == "connected"
    assert updated.last_connected_at
    refute updated.last_error
    assert MCP.tool_summary() =~ "fake-stdio: connected (1 tools)"
  end

  test "marks stdio MCP server unavailable when command cannot start" do
    assert {:ok, server} =
             MCP.create_server(%{
               name: "missing-stdio",
               command: "definitely-not-a-buster-claw-command",
               args: %{},
               env: %{}
             })

    assert {:error, {:command_not_found, "definitely-not-a-buster-claw-command"}} =
             MCP.connect_server(server)

    updated = MCP.get_server!(server.id)
    assert updated.last_status == "unavailable"
    assert updated.last_error =~ "command_not_found"
    refute updated.last_connected_at
  end

  defp fake_mcp_script do
    ~S'''
    while IFS= read -r line
    do
      case "$line" in
        *initialize*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1.0.0"}}}'
          ;;
        *tools/list*)
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"fake_echo","description":"Echoes text","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}}}]}}'
          ;;
      esac
    done
    '''
  end
end
