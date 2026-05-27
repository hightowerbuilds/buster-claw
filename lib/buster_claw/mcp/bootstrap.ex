defmodule BusterClaw.MCP.Bootstrap do
  @moduledoc "Starts enabled MCP stdio clients after the application boots."

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :start_enabled_servers)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:start_enabled_servers, state) do
    BusterClaw.MCP.start_enabled_servers()
    {:noreply, state}
  end
end
