defmodule BusterClawWeb.McpControllerTest do
  use BusterClawWeb.ConnCase

  @token "test-token-loopback-only"

  describe "auth" do
    test "rejects unauthenticated", %{conn: conn} do
      conn = post(conn, ~p"/mcp", initialize_request())
      assert json_response(conn, 401)
    end
  end

  describe "initialize" do
    test "returns server info and protocol version", %{conn: conn} do
      conn = authed(conn) |> post(~p"/mcp", initialize_request())
      assert %{"jsonrpc" => "2.0", "id" => 1, "result" => result} = json_response(conn, 200)
      assert result["serverInfo"]["name"] == "buster-claw"
      assert is_binary(result["protocolVersion"])
      assert %{"tools" => _} = result["capabilities"]
    end
  end

  describe "tools/list" do
    test "returns the full catalog as MCP tools", %{conn: conn} do
      req = %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 2}
      conn = authed(conn) |> post(~p"/mcp", req)

      assert %{"jsonrpc" => "2.0", "id" => 2, "result" => %{"tools" => tools}} =
               json_response(conn, 200)

      assert length(tools) >= 70

      first = Enum.find(tools, &(&1["name"] == "source_list"))
      assert first
      assert first["description"]
      assert first["inputSchema"]["type"] == "object"
    end

    test "tools with required args expose them in inputSchema.required", %{conn: conn} do
      req = %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 3}
      conn = authed(conn) |> post(~p"/mcp", req)
      %{"result" => %{"tools" => tools}} = json_response(conn, 200)

      tool = Enum.find(tools, &(&1["name"] == "source_create"))
      assert "url" in tool["inputSchema"]["required"]
      assert "type" in tool["inputSchema"]["required"]
    end
  end

  describe "tools/call" do
    test "invokes a command and returns text content", %{conn: conn} do
      req = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 4,
        "params" => %{"name" => "source_list", "arguments" => %{}}
      }

      conn = authed(conn) |> post(~p"/mcp", req)
      assert %{"jsonrpc" => "2.0", "id" => 4, "result" => result} = json_response(conn, 200)
      assert result["isError"] == false
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert {:ok, []} = Jason.decode(text)
    end

    test "returns isError: true on command failure", %{conn: conn} do
      req = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 5,
        "params" => %{"name" => "source_get", "arguments" => %{"id" => 99_999}}
      }

      conn = authed(conn) |> post(~p"/mcp", req)
      %{"result" => result} = json_response(conn, 200)
      assert result["isError"] == true
    end
  end

  describe "errors" do
    test "unknown method returns JSON-RPC error -32601", %{conn: conn} do
      req = %{"jsonrpc" => "2.0", "method" => "no_such_method", "id" => 99}
      conn = authed(conn) |> post(~p"/mcp", req)
      assert %{"error" => %{"code" => -32_601}} = json_response(conn, 200)
    end

    test "notifications return 202 with no body", %{conn: conn} do
      req = %{"jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => %{}}
      conn = authed(conn) |> post(~p"/mcp", req)
      assert response(conn, 202) == ""
    end
  end

  defp initialize_request do
    %{
      "jsonrpc" => "2.0",
      "method" => "initialize",
      "id" => 1,
      "params" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test-client", "version" => "1.0"}
      }
    }
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")
end
