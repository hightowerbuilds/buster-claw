defmodule BusterClawWeb.McpController do
  @moduledoc """
  MCP (Model Context Protocol) server endpoint, implementing the Streamable
  HTTP transport's JSON-response form. External TUI agents (Claude Code, Codex)
  configure Buster Claw as a remote MCP server at this URL with a Bearer token.

  Supports the methods needed for tool discovery and invocation:
  - `initialize` — handshake, returns server capabilities + info
  - `tools/list` — returns the catalog from `BusterClaw.Commands.list_commands/0`
  - `tools/call` — invokes a command via `BusterClaw.Commands.call/2`
  - `ping` — keep-alive
  - `notifications/*` — accepted, no response body

  Auth: Bearer token via `BusterClawWeb.ApiAuth`.
  """

  use BusterClawWeb, :controller

  alias BusterClaw.Commands
  alias BusterClaw.Commands.{Result, Schema}

  @protocol_version "2024-11-05"
  @server_name "buster-claw"
  @server_version "0.1.0"

  def handle(conn, params) do
    case process_request(params) do
      nil ->
        # notifications expect 202 with no body
        send_resp(conn, 202, "")

      response ->
        json(conn, response)
    end
  end

  # ---- Method dispatch ----

  defp process_request(%{"jsonrpc" => "2.0", "method" => "initialize", "id" => id}) do
    %{
      jsonrpc: "2.0",
      id: id,
      result: %{
        protocolVersion: @protocol_version,
        capabilities: %{tools: %{listChanged: false}},
        serverInfo: %{name: @server_name, version: @server_version}
      }
    }
  end

  defp process_request(%{"jsonrpc" => "2.0", "method" => "ping", "id" => id}) do
    %{jsonrpc: "2.0", id: id, result: %{}}
  end

  defp process_request(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => id}) do
    tools = Commands.list_commands() |> Enum.map(&command_to_tool/1)
    %{jsonrpc: "2.0", id: id, result: %{tools: tools}}
  end

  defp process_request(%{
         "jsonrpc" => "2.0",
         "method" => "tools/call",
         "id" => id,
         "params" => %{"name" => name} = params
       }) do
    args = Map.get(params, "arguments", %{})

    case Commands.call(name, args) do
      {:ok, value} ->
        text = format_value(value)

        %{
          jsonrpc: "2.0",
          id: id,
          result: %{
            content: [%{type: "text", text: text}],
            isError: false
          }
        }

      {:error, reason} ->
        %{
          jsonrpc: "2.0",
          id: id,
          result: %{
            content: [%{type: "text", text: format_error(reason)}],
            isError: true
          }
        }
    end
  end

  defp process_request(%{"jsonrpc" => "2.0", "method" => "notifications/" <> _}) do
    nil
  end

  defp process_request(%{"jsonrpc" => "2.0", "method" => method, "id" => id}) do
    %{
      jsonrpc: "2.0",
      id: id,
      error: %{code: -32_601, message: "Method not found: #{method}"}
    }
  end

  defp process_request(%{"jsonrpc" => "2.0", "id" => id}) do
    %{
      jsonrpc: "2.0",
      id: id,
      error: %{code: -32_600, message: "Invalid Request"}
    }
  end

  defp process_request(_) do
    %{
      jsonrpc: "2.0",
      id: nil,
      error: %{code: -32_700, message: "Parse error"}
    }
  end

  # ---- Catalog → MCP tool ----

  defp command_to_tool(%{name: name, description: description, args: args}) do
    %{
      name: name,
      description: description,
      inputSchema: Schema.to_json_schema(args)
    }
  end

  # ---- Result formatting ----

  defp format_value(value) do
    value
    |> Result.to_json()
    |> Jason.encode!(pretty: true)
  end

  defp format_error(%Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    Jason.encode!(%{error: "validation", errors: errors}, pretty: true)
  end

  defp format_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
