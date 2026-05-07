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
end
