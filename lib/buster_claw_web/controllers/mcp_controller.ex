defmodule BusterClawWeb.McpController do
  @moduledoc """
  MCP (Model Context Protocol) server endpoint, implementing the Streamable
  HTTP transport's JSON-response form. External TUI agents (Claude Code, Codex)
  configure Buster Claw as a remote MCP server at this URL with a Bearer token.

  Supports the methods needed for tool discovery and invocation:
  - `initialize` — handshake, returns server capabilities + info
  - `tools/list` — returns ONLY the safe-tier catalog (`Commands.safe_commands/0`)
  - `tools/call` — invokes a command via `BusterClaw.Commands.call/3` tagged with
    the authenticated caller; restricted commands are refused, never executed.
  - `ping` — keep-alive
  - `notifications/*` — accepted, no response body

  Auth: Bearer token via `BusterClawWeb.ApiAuth`, which assigns `:caller`
  (`:trusted` for the full token, `:mcp` for the scoped MCP token). The caller
  is the trust boundary — an agent issued only the MCP token cannot reach
  restricted commands here OR on `/api/run`.
  """

  use BusterClawWeb, :controller

  alias BusterClaw.Commands
  alias BusterClaw.Commands.{Result, Schema}

  @protocol_version "2024-11-05"
  @server_name "buster-claw"
  @server_version "0.1.0"

  def handle(conn, params) do
    caller = Map.get(conn.assigns, :caller, :mcp)

    case process_request(params, caller) do
      nil ->
        # notifications expect 202 with no body
        send_resp(conn, 202, "")

      response ->
        json(conn, response)
    end
  end

  # ---- Method dispatch ----

  defp process_request(%{"jsonrpc" => "2.0", "method" => "initialize", "id" => id}, _caller) do
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

  defp process_request(%{"jsonrpc" => "2.0", "method" => "ping", "id" => id}, _caller) do
    %{jsonrpc: "2.0", id: id, result: %{}}
  end

  defp process_request(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => id}, _caller) do
    # Only advertise safe-tier commands. Restricted commands (deletes, sends,
    # credential changes, shell hooks) are never exposed to MCP clients.
    tools = Commands.safe_commands() |> Enum.map(&command_to_tool/1)
    %{jsonrpc: "2.0", id: id, result: %{tools: tools}}
  end

  defp process_request(
         %{
           "jsonrpc" => "2.0",
           "method" => "tools/call",
           "id" => id,
           "params" => %{"name" => name} = params
         },
         caller
       ) do
    args = Map.get(params, "arguments", %{})

    case Commands.call(name, args, caller: caller) do
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

      {:error, :requires_confirmation} ->
        %{
          jsonrpc: "2.0",
          id: id,
          result: %{
            content: [
              %{
                type: "text",
                text:
                  "This command is restricted and requires human approval in the " <>
                    "Buster Claw app. It was not executed."
              }
            ],
            isError: true
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

  defp process_request(%{"jsonrpc" => "2.0", "method" => "notifications/" <> _}, _caller) do
    nil
  end

  defp process_request(%{"jsonrpc" => "2.0", "method" => method, "id" => id}, _caller) do
    %{
      jsonrpc: "2.0",
      id: id,
      error: %{code: -32_601, message: "Method not found: #{method}"}
    }
  end

  defp process_request(%{"jsonrpc" => "2.0", "id" => id}, _caller) do
    %{
      jsonrpc: "2.0",
      id: id,
      error: %{code: -32_600, message: "Invalid Request"}
    }
  end

  defp process_request(_, _caller) do
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
  defp format_error(reason), do: BusterClawWeb.ErrorFormatter.format(reason)
end
