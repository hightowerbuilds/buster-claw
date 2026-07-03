defmodule BusterClaw.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # Compiled-in dev/test API tokens (config/dev.exs, config/test.exs). A real
  # release generates tokens per-machine at first run, so none of these should
  # ever be present in a packaged build.
  @dev_token_sentinels [
    "dev-token-loopback-only",
    "dev-mcp-token-safe-tier-only",
    "dev-agent-token-untrusted-provenance",
    "test-token-loopback-only",
    "test-mcp-token-safe-tier-only",
    "test-agent-token-untrusted-provenance"
  ]

  @impl true
  def start(_type, _args) do
    verify_release_token_safety!()

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
        BusterClaw.Browser.Capture,
        BusterClaw.Browser.Bridge,
        BusterClaw.Sentinel.Pending,
        BusterClaw.RateLimiter,
        browser_sidecar_child(),
        browserbase_session_manager_child(),
        orchestrator_child(),
        uptime_child(),
        dispatcher_child(),
        wallet_poller_child(),
        analyzer_child(),
        # Per-conversation chat: a Registry for {:via} lookup by conv_id and a
        # DynamicSupervisor that starts one Chat process per open conversation,
        # lazily on the first message. Always on (cheap; tests use them too).
        {Registry, keys: :unique, name: BusterClaw.Agent.ChatRegistry},
        BusterClaw.Agent.ChatSupervisor,
        # Bounded fan-out for parallel sub-runs (Phase 4). Always on (cheap; an idle
        # Task.Supervisor holds no resources).
        {Task.Supervisor, name: BusterClaw.SwarmTaskSupervisor},
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

  # Refuse to boot a packaged release (RELEASE_NAME is set only for releases)
  # that was mistakenly built with dev/test config and therefore carries a
  # publicly-known API token. Generated per-machine tokens are nil in config at
  # this point, so a correctly-built prod release passes cleanly; this only
  # trips on a misbuilt bundle.
  defp verify_release_token_safety! do
    if System.get_env("RELEASE_NAME") do
      configured =
        [
          Application.get_env(:buster_claw, :api_token),
          Application.get_env(:buster_claw, :mcp_api_token),
          Application.get_env(:buster_claw, :agent_api_token)
        ]
        |> Enum.filter(&is_binary/1)

      if Enum.any?(configured, &(&1 in @dev_token_sentinels)) do
        raise """
        Refusing to boot: this release carries a compiled-in dev/test API token \
        (#{inspect(@dev_token_sentinels)}), which is publicly known. It was built \
        with dev/test config. Rebuild with MIX_ENV=prod (scripts/build_desktop.sh) \
        so tokens are generated per-machine at first run.
        """
      end
    end

    :ok
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

  # Cost guardrail for cloud browser sessions: caps concurrency, reaps idle
  # sessions, releases everything on shutdown. Only runs when Browserbase is
  # configured + enabled.
  defp browserbase_session_manager_child do
    if Application.get_env(:buster_claw, :browserbase_enabled, false) do
      BusterClaw.Browserbase.SessionManager
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

  # The unattended work pump. Gated separately from the orchestrator so it can be
  # disabled on its own; off in tests (they drive a Dispatcher instance directly).
  defp dispatcher_child do
    if Application.get_env(:buster_claw, :dispatcher_enabled, true) do
      BusterClaw.Dispatcher
    end
  end

  # The wallet feed polling pump (market/url/integration feeds + Gmail signals).
  # Off in tests (they drive a WalletPoller instance with injected fetchers).
  defp wallet_poller_child do
    if Application.get_env(:buster_claw, :wallet_poller_enabled, true) do
      BusterClaw.WalletPoller
    end
  end

  # The self-improvement scanner (Phase 3): files skill *suggestions* from repeated
  # command sequences. Off in tests (the Analyzer suite drives scan/1 directly).
  defp analyzer_child do
    if Application.get_env(:buster_claw, :analyzer_enabled, true) do
      BusterClaw.Analyzer.Server
    end
  end
end
