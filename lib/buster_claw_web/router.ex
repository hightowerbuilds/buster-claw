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

  # The in-app browser's own pages. Secure headers and CSP, and deliberately
  # NOT the rest of the `:browser` pipeline:
  #
  #   * no `:accepts, ["html"]` — the same scope carries JSON/no-content POSTs
  #     (history, tabs, bookmarks, screenshot, command),
  #   * no `fetch_session` / `protect_from_forgery` — these pages are plain
  #     controller HTML posting to loopback with no session, and adding CSRF
  #     would break every form without adding a boundary the loopback-only
  #     binding doesn't already give.
  #
  # It exists because until 08-08 this scope had no pipeline at all, so it
  # received no CSP and no `nosniff` — the one part of the app that
  # `ContentSecurityPolicy`'s `script-src 'self'` did not reach, on the surface
  # that renders the most outside-shaped content. Applying it required first
  # moving four inline <script> blocks and two inline `onsubmit=` handlers into
  # `assets/js/browser_pages.js`; the header would otherwise have broken all
  # four pages in prod (where CSP is enforced) and nowhere else.
  pipeline :browser_page do
    plug :put_secure_browser_headers
    plug BusterClawWeb.ContentSecurityPolicy
  end

  # Raw workspace bytes — a user's upload or an agent's output. One header, and
  # deliberately ONLY that header: these scopes stay free of `accepts` (they answer
  # media-element and CSS `url()` requests, not a single format), of
  # `fetch_session`, and of `protect_from_forgery`, all for the reasons written on
  # each scope below.
  #
  # It is a pipeline rather than a `put_resp_header` per controller because there
  # are nine such routes and fixing them individually is exactly how four of them
  # ended up uncovered — `X-Content-Type-Options` appeared nowhere in the codebase
  # until `RangeResponse` began sending it for audio. A scope missing
  # `pipe_through :media` is now visible in this file beside eight that have it.
  # See `BusterClawWeb.NoSniff` for what it defends and what it does not.
  pipeline :media do
    plug BusterClawWeb.NoSniff
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_authenticated do
    plug :accepts, ["json"]
    plug BusterClawWeb.ApiAuth
  end

  # The Clinch's management routes. `ApiAuth` establishes *which* token is
  # calling; `RequireTrusted` insists it be the full one. Credential management
  # has no per-command tier to fall back on, so the floor is set at the router
  # where it can be read.
  pipeline :api_trusted do
    plug :accepts, ["json"]
    plug BusterClawWeb.ApiAuth
    plug BusterClawWeb.RequireTrusted
  end

  scope "/", BusterClawWeb do
    pipe_through :browser

    live_session :default, on_mount: [BusterClawWeb.RequireOnboarding] do
      live "/", StatusLive, :home
      live "/browse", BrowseLive, :index
      live "/split", SplitLive, :index
      live "/terminal", TerminalLive, :index
      live "/calendar", CalendarLive, :index
      live "/integrations", IntegrationsLive, :index
      live "/security", SecurityLive, :index
      live "/settings", SettingsLive, :index
      live "/cmd-list", CmdListLive, :index
      live "/appearance", AppearanceLive, :index
      live "/voice", VoiceLive, :index
      live "/notify-settings", NotifySettingsLive, :index
      live "/phone", PhoneLive, :index
      live "/sketch", SketchLive, :index
      # NO DOCK TAB as of 09-02-26 — the Studio is being spun out into its own
      # project, and the Sketch Pad (the one surface here worth keeping) took the
      # tab. The route stays: it is the only way to reach Mix and the Voice
      # Library, and roughly thirty tests still exercise them through it. Deleting
      # the route is the spin-off's job, together with those tests. An unreachable
      # route is untidy; a route deleted out from under its own test suite is an
      # afternoon of guessing which failures were intentional.
      live "/studio", StudioLive, :index
      live "/workspace", WorkspaceLive, :index
      live "/manual", UserGuideLive, :index
      live "/setup", SetupLive, :index
    end

    get "/google/oauth/callback", GoogleOAuthController, :callback
  end

  # Uploaded appearance asset served from the writable workspace dir. Only `:media`
  # (nosniff) — no `accepts`, so it isn't constrained to a single format (the webview
  # requests it as an image via CSS `url()`); loopback-only and non-sensitive. One shared
  # image pool backs both the homepage and the terminal, so the slot is the whole
  # address — there is no per-surface route.
  scope "/appearance", BusterClawWeb do
    pipe_through :media

    get "/image/:slot", AppearanceController, :image
  end

  # Voicemail audio for the Message Machine panel's <audio> player. Only `:media`
  # (media element requests, not HTML, so no `accepts`); path-guarded to the Library root and
  # audio extensions only; loopback-only.
  scope "/phone", BusterClawWeb do
    pipe_through :media

    get "/recording", TelephonyRecordingController, :show
  end

  # Music library audio for the dock player. Only `:media` (media element
  # requests, not HTML); the name is resolved by Music.path_for/1 against the
  # library listing, never joined from raw input; loopback-only. Unlike the
  # routes around it this one honors byte ranges — a track is long enough to
  # seek through. See BusterClawWeb.RangeResponse.
  scope "/music", BusterClawWeb do
    pipe_through :media

    get "/track/:name", MusicController, :show
  end

  # Studio working files (<workspace>/studio/) for the Studio tab's waveform and
  # preview. Only `:media`; the name is resolved by SoundStudio.path_for/1 against
  # the real listing, never joined from raw input. Byte ranges (and nosniff) via
  # RangeResponse — imported material can be long enough to scrub.
  scope "/studio", BusterClawWeb do
    pipe_through :media

    get "/file/:name", StudioFileController, :show
  end

  # Workspace notification sounds, played by the NotifySound hook when a
  # notification fires and auditioned from Settings → Notify. `:show` is the
  # fixed-path fallback chime; `:named` only resolves names that are real
  # library entries (Sound.path_for), so no traversal surface.
  scope "/notify", BusterClawWeb do
    pipe_through :media

    get "/sound", NotifySoundController, :show
    get "/sound/:name", NotifySoundController, :named
  end

  # Renders a workspace file (Markdown → HTML, .html as-is) for the in-app browser.
  # Only `:media`: returns a raw HTML document, not a LiveView page, so no root layout
  # and no CSRF. Path-guarded to the workspace by FileManager; loopback-only.
  #
  # NOTE: `nosniff` does not protect `:show`. It serves workspace `.html` as
  # `text/html` deliberately (docs/LOCAL_TRUST.md), so nothing is being sniffed —
  # that route's exposure is the MISSING CSP, which is still open. `:image` is the
  # one here nosniff actually covers.
  scope "/ws", BusterClawWeb do
    pipe_through :media

    get "/file", WorkspaceFileController, :show
    get "/image", WorkspaceFileController, :image
  end

  # One file out of one Pocket. Only `:media`: these are raw asset bytes, not an
  # HTML page. Every read is fenced by `Pockets.resolve/2` — a bare filename,
  # canonicalized inside the Pocket, `lstat`-ed so a planted symlink is refused.
  # This is the single route a mounted Pocket's bytes will reach the app through.
  scope "/pockets", BusterClawWeb do
    pipe_through :media

    get "/:pocket/:file", PocketAssetController, :show
  end

  # One image out of one sketch's sidecar. Only `:media` — these are raw image
  # bytes for an `<image>` inside the drawing, not an HTML page. Every read is
  # fenced by `Sketch.Assets.resolve/2`, whose names are content hashes with a
  # known extension and nothing else; the controller adds no path handling of its
  # own. Loopback-only.
  scope "/sketches", BusterClawWeb do
    pipe_through :media

    get "/:sketch/:file", SketchAssetController, :show
  end

  # The Agent Mode mirror: an MJPEG stream of a run's viewport, rendered by an
  # <img> in the browse tab (Phase 7). Only `:media` — this is a long-lived chunked
  # media response, not an HTML page, so `accepts` would be wrong. Loopback-only; the frames show a page the
  # user is already watching in a window on their own machine.
  scope "/browser", BusterClawWeb do
    pipe_through :media

    get "/agent-view/:run_id", AgentViewController, :show
  end

  # Raw WGSL for a custom homepage shader, fetched by the SmokeBackground hook and
  # compiled live in the webview. Only `:media`; name guarded by Shaders.read/1;
  # loopback-only. Raw WGSL is text/plain, so nosniff is what keeps a browser from
  # deciding a shader is markup.
  scope "/shaders", BusterClawWeb do
    pipe_through :media

    get "/:name", ShaderController, :show
  end

  # Native chrome (toolbar) for the embedded browser's `browser-chrome` webview.
  # Raw HTML; loopback-only; drives the sibling content webview via Tauri commands.
  scope "/browser", BusterClawWeb do
    pipe_through :browser_page

    get "/chrome", BrowserChromeController, :show
    get "/home", BrowserHomeController, :show
    get "/pages", BrowserPagesController, :show
    get "/workspace", BrowserWorkspaceController, :show
    get "/history", BrowserHistoryPageController, :show
    post "/history", BrowserHistoryController, :create
    post "/history/clear", BrowserHistoryPageController, :clear
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

  # Loopback JSON for finance pages in the in-app browser (its sandboxed
  # content webview can't carry the API token). Read-only, safe-tier
  # finance reads only; no auth — same posture as the /browser and /ws scopes.
  scope "/finance/api", BusterClawWeb do
    pipe_through :api

    get "/search", FinanceApiController, :search
    get "/lookup", FinanceApiController, :lookup
  end

  scope "/", BusterClawWeb do
    pipe_through :api

    get "/_health", HealthController, :show

    # Public by necessity: external senders (GitHub) can't carry our API
    # token. Authentication is per-adapter webhook-signature verification, which
    # fails CLOSED when no secret is configured (see Integrations.*.verify_webhook).
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

  # Credential management. The only write path into the Clinch, and reachable
  # only by the full token — which is why the desktop shell, the one thing that
  # holds it and can be invoked from the UI, is load-bearing rather than
  # decorative. There is deliberately no GET: nothing returns a value.
  scope "/api", BusterClawWeb do
    pipe_through :api_trusted

    post "/clinch", ClinchController, :put
    delete "/clinch", ClinchController, :delete

    # Rotating the master key is credential MANAGEMENT, so it sits behind the
    # same trusted-token floor as storing one — never on the command catalog,
    # where an agent could reach it.
    post "/clinch/rotate", ClinchController, :rotate
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

      # STUDIO_ROADMAP V.4a. Measures what getUserMedia does in THIS shell
      # before V.5 adds the usage description and the audio-input entitlement,
      # because both are signing-affecting and the read that prompted them
      # found Info.plist's safety claim to be stale — see
      # BusterClawWeb.DevMicProbeController for what wry 0.55.1 actually does.
      # Inside `dev_routes`, so it cannot exist in a release.
      get "/mic-probe", BusterClawWeb.DevMicProbeController, :show
    end
  end
end
