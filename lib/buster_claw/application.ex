defmodule BusterClaw.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        BusterClawWeb.Telemetry,
        BusterClaw.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:buster_claw, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:buster_claw, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: BusterClaw.PubSub},
        BusterClaw.AgentMode,
        BusterClaw.Sentinel.Pending,
        browser_sidecar_child(),
        {Registry, keys: :unique, name: BusterClaw.MCP.Registry},
        BusterClaw.MCP.Supervisor,
        BusterClaw.MCP.Bootstrap,
        scheduler_child(),
        {Registry, keys: :unique, name: BusterClaw.Chat.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: BusterClaw.Chat.SessionSupervisor},
        # Start to serve requests, typically the last entry
        BusterClawWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BusterClaw.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = ok ->
        # Install the model-facing workspace guide (best-effort).
        BusterClaw.Introduction.ensure()
        ok

      other ->
        other
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BusterClawWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  defp scheduler_child do
    if Application.get_env(:buster_claw, :scheduler_enabled, true) do
      BusterClaw.Scheduler.Runner
    end
  end

  defp browser_sidecar_child do
    if Application.get_env(:buster_claw, :browser_sidecar_enabled, false) do
      BusterClaw.Browser.Sidecar
    end
  end
end
