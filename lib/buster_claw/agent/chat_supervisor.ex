defmodule BusterClaw.Agent.ChatSupervisor do
  @moduledoc """
  Dynamic supervisor for per-conversation chat GenServers
  (`BusterClaw.Agent.Chat`). One child process per open conversation, started
  lazily on the first message and looked up via `BusterClaw.Agent.ChatRegistry`.
  Crash-isolated: a failure in one chat can't disturb the others.
  """
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
