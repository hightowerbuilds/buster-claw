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

    live_session :default, on_mount: [BusterClawWeb.RequireOnboarding] do
      live "/", StatusLive, :home
      live "/browse", BrowseLive, :index
      live "/split", SplitLive, :index
      live "/terminal", TerminalLive, :index
      live "/calendar", CalendarLive, :index
      live "/finance", FinanceLive, :index
      live "/gws", GWSLive, :index
      live "/memory", MemoryLive, :index
      live "/integrations", IntegrationsLive, :index
      live "/scheduler", SchedulerLive, :index
      live "/webhooks", WebhooksLive, :index
      live "/hooks", HooksLive, :index
      live "/delivery", DeliveryLive, :index
      live "/advanced", DeliveryLive, :advanced
      live "/security", SecurityLive, :index
      live "/settings", SettingsLive, :index
      live "/appearance", AppearanceLive, :index
      live "/workspace", WorkspaceLive, :index
      live "/manual", UserGuideLive, :index
      live "/setup", SetupLive, :index
    end

    get "/google/oauth/callback", GoogleOAuthController, :callback
  end

  # Uploaded appearance asset served from the writable workspace dir. No pipeline
  # so it isn't constrained to a single `accepts` format (the webview requests it
  # as an image via CSS `url()`); loopback-only and non-sensitive.
  scope "/appearance", BusterClawWeb do
    get "/terminal-background", AppearanceController, :terminal_background
  end

  # Renders a workspace file (Markdown → HTML, .html as-is) for the in-app browser.
  # No pipeline: returns a raw HTML document, not a LiveView page. Path-guarded to
  # the workspace by FileManager; loopback-only.
  scope "/ws", BusterClawWeb do
    get "/file", WorkspaceFileController, :show
  end

  # Native chrome (toolbar) for the embedded browser's `browser-chrome` webview.
  # Raw HTML; loopback-only; drives the sibling content webview via Tauri commands.
  scope "/browser", BusterClawWeb do
    get "/chrome", BrowserChromeController, :show
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

  # Other scopes may use custom stacks.
  # scope "/api", BusterClawWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
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
    end
  end
end
