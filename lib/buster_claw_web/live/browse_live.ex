defmodule BusterClawWeb.BrowseLive do
  @moduledoc """
  In-app browser. In the desktop app a native child webview is overlaid on the
  surface below to render live HTTPS pages (and workspace files served by
  `/ws/file`); the `EmbeddedBrowser` JS hook keeps it glued to the surface and
  drives the `browser_*` Tauri commands. Outside the desktop app there's no
  native webview, so a fallback notice is shown.

  The toolbar (back/forward/reload + address bar) is driven entirely client-side
  by the hook, so navigation never round-trips the server. The address bar
  accepts a URL (`https://…`, scheme optional) or an absolute workspace path
  (`/…`), which the hook routes to `/ws/file`.
  """
  use BusterClawWeb, :live_view

  @impl true
  def mount(params, session, socket) do
    # Deep link (/browse?url=…) or, when embedded as a split pane, session["url"].
    initial_url =
      case params do
        %{"url" => url} when is_binary(url) and url != "" -> url
        _ -> session["url"]
      end

    # Native browser surface id: "main" for the solo /browse, "left"/"right" when
    # embedded as a split pane (set by SplitLive). Keeps two side-by-side browsers
    # independent.
    surface_id = session["surface_id"] || "main"

    {:ok,
     socket
     |> assign(:page_title, "Browse")
     |> assign(:initial_url, initial_url || "")
     |> assign(:surface_id, surface_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id={"browse-shell-" <> @surface_id}
        phx-hook="EmbeddedBrowser"
        data-initial-url={@initial_url}
        data-surface-id={@surface_id}
        class="flex min-h-0 flex-1 flex-col"
      >
        <%!-- The native chrome (toolbar) + content webviews are positioned over
             this whole surface by the hook; the toolbar lives in the chrome
             webview, so there's no HTML toolbar to be covered. --%>
        <div data-browser-surface class="relative min-h-0 flex-1">
          <div
            data-browser-fallback
            class="hidden h-full place-items-center p-8 text-center text-sm text-base-content/60"
          >
            <div>
              <.icon name="hero-globe-alt" class="mx-auto size-10 text-base-content/30" />
              <p class="mt-3 font-semibold text-base-content">
                The in-app browser runs in the Buster Claw desktop app.
              </p>
              <p class="mt-1">
                Launch it with <code class="font-mono">./scripts/dev.sh</code> to browse here.
              </p>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
