defmodule BusterClaw.BrowserControl.RunSupervisor do
  @moduledoc """
  DynamicSupervisor for `AgentMode` runs started from the command surface. A
  run must outlive the command call that started it (`AgentMode.start_link`
  links to its caller, and a command process returns immediately), and a
  crashed run is data for the trajectory, not something to retry — so children
  are `restart: :temporary`.
  """
  use DynamicSupervisor

  alias BusterClaw.BrowserControl.AgentMode

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Start one supervised run; returns `{:ok, pid}` or an error."
  def start_run(opts) do
    DynamicSupervisor.start_child(__MODULE__, %{
      id: AgentMode,
      start: {AgentMode, :start_link, [opts]},
      restart: :temporary
    })
  end
end
