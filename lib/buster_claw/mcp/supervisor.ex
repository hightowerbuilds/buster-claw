defmodule BusterClaw.MCP.Supervisor do
  @moduledoc "Dynamic supervisor for configured MCP stdio clients."

  use DynamicSupervisor

  alias BusterClaw.Automation.MCPServer
  alias BusterClaw.MCP
  alias BusterClaw.MCP.Client

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_enabled_servers do
    MCP.list_servers()
    |> Enum.filter(& &1.enabled)
    |> Enum.map(&start_server/1)
  end

  def start_server(%MCPServer{enabled: false}), do: {:error, :disabled}

  def start_server(%MCPServer{} = server) do
    case lookup(server) do
      {:ok, pid} -> {:ok, pid}
      :error -> DynamicSupervisor.start_child(__MODULE__, {Client, server})
    end
  end

  def stop_server(%MCPServer{} = server) do
    with {:ok, pid} <- lookup(server) do
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  def discover_tools(%MCPServer{} = server) do
    with {:ok, pid} <- start_server(server) do
      Client.tools(pid)
    end
  end

  def cached_tools(%MCPServer{} = server) do
    with {:ok, pid} <- lookup(server) do
      {:ok, Client.cached_tools(pid)}
    end
  catch
    :exit, _reason -> :error
  end

  def lookup(%MCPServer{id: id}) do
    case Registry.lookup(BusterClaw.MCP.Registry, id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end
end
