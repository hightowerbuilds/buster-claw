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
      live "/history", HistoryLive, :index
      live "/split", SplitLive, :index
      live "/terminal", TerminalLive, :index
      live "/calendar", CalendarLive, :index
      live "/wallets", WalletsLive, :index
      live "/gws", GWSLive, :index
      live "/integrations", IntegrationsLive, :index
      live "/security", SecurityLive, :index
      live "/settings", SettingsLive, :index
      live "/appearance", AppearanceLive, :index
      live "/get-started", GetStartedLive, :index
      live "/voice", VoiceLive, :index
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
    get "/terminal-background/:slot", AppearanceController, :terminal_background
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
    get "/home", BrowserHomeController, :show
    get "/workspace", BrowserWorkspaceController, :show
    post "/history", BrowserHistoryController, :create
    post "/download", BrowserDownloadController, :create
    get "/tabs", BrowserTabsController, :show
    post "/tabs", BrowserTabsController, :update
    get "/suggest", BrowserSuggestController, :index
    get "/favicon", BrowserFaviconController, :show
    get "/bookmarks", BrowserBookmarkController, :index
    post "/bookmarks", BrowserBookmarkController, :create
    post "/bookmarks/remove", BrowserBookmarkController, :delete
    post "/screenshot", BrowserScreenshotController, :create
    post "/command", BrowserCommandController, :create
  end

  # Loopback JSON for the in-app browser's financial-informant.html page (its
  # sandboxed content webview can't carry the API token). Read-only, safe-tier
  # finance reads only; no auth — same posture as the /browser and /ws scopes.
  scope "/finance/api", BusterClawWeb do
    pipe_through :api

    get "/search", FinanceApiController, :search
    get "/lookup", FinanceApiController, :lookup
  end

  scope "/", BusterClawWeb do
    pipe_through :api

    get "/_health", HealthController, :show
    post "/integrations/:name/webhook", IntegrationWebhookController, :trigger
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
