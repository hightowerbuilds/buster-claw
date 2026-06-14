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
        dispatch_projector_child(),
        BusterClaw.TerminalWorkspace,
        BusterClaw.Sentinel.Pending,
        browser_sidecar_child(),
        orchestrator_child(),
        uptime_child(),
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
        # Install the bundled HTML pages (Manual, Financial Informant) into
        # <workspace>/pages/ (best-effort).
        BusterClaw.Pages.ensure()
        # Install the DataZone-local CLI launcher used by terminal role commands.
        BusterClaw.WorkspaceCLI.ensure()
        # Seed job descriptions + the trusted-sender policy template (best-effort).
        BusterClaw.Jobs.ensure()
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

  defp dispatch_projector_child do
    if Application.get_env(:buster_claw, :dispatch_projector_enabled, true) do
      BusterClaw.DispatchProjector
    end
  end

  defp browser_sidecar_child do
    if Application.get_env(:buster_claw, :browser_sidecar_enabled, false) do
      BusterClaw.Browser.Sidecar
    end
  end

  defp orchestrator_child do
    if Application.get_env(:buster_claw, :orchestrator_enabled, true) do
      BusterClaw.Orchestrator
    end
  end

  defp uptime_child do
    if Application.get_env(:buster_claw, :orchestrator_enabled, true) do
      BusterClaw.Orchestration.Uptime
    end
  end
end
