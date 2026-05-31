defmodule BusterClawWeb.Router do
  use BusterClawWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BusterClawWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug BusterClawWeb.ContentSecurityPolicy
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_authenticated do
    plug :accepts, ["json"]
    plug BusterClawWeb.ApiAuth
  end

  scope "/", BusterClawWeb do
    pipe_through :browser

    live "/", StatusLive, :home
    live "/chat", ChatLive, :index
    live "/sources", SourcesLive, :index
    live "/documents", DocumentsLive, :index
    live "/browse", BrowseLive, :index
    live "/split", SplitLive, :index
    live "/terminal", TerminalLive, :index
    live "/analysis", AnalysisLive, :index
    live "/calendar", CalendarLive, :index
    live "/gws", GWSLive, :index
    live "/memory", MemoryLive, :index
    live "/integrations", IntegrationsLive, :index
    live "/mcp", MCPLive, :index
    live "/scheduler", SchedulerLive, :index
    live "/webhooks", WebhooksLive, :index
    live "/hooks", HooksLive, :index
    live "/delivery", DeliveryLive, :index
    live "/advanced", DeliveryLive, :advanced
    live "/runtime", RuntimeLive, :index
    live "/security", SecurityLive, :index
    live "/settings", SettingsLive, :index
    live "/appearance", AppearanceLive, :index
    live "/workspace", WorkspaceLive, :index
    live "/setup", SetupLive, :index

    get "/google/oauth/callback", GoogleOAuthController, :callback
  end

  scope "/", BusterClawWeb do
    pipe_through :api

    get "/_health", HealthController, :show
    post "/integrations/:name/webhook", IntegrationWebhookController, :trigger
    post "/hooks/:name", WebhookController, :trigger
  end

  scope "/api", BusterClawWeb do
    pipe_through :api

    get "/commands", ApiController, :commands
  end

  scope "/api", BusterClawWeb do
    pipe_through :api_authenticated

    post "/run", ApiController, :run
  end

  scope "/", BusterClawWeb do
    pipe_through :api_authenticated

    post "/mcp", McpController, :handle
  end

  # Other scopes may use custom stacks.
  # scope "/api", BusterClawWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:buster_claw, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BusterClawWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
