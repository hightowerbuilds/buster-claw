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

    {:ok,
     socket
     |> assign(:page_title, "Browse")
     |> assign(:initial_url, initial_url || "")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="browse-shell"
        phx-hook="EmbeddedBrowser"
        data-initial-url={@initial_url}
        class="flex min-h-0 flex-1 flex-col gap-3"
      >
        <div class="flex items-center gap-2">
          <div class="flex items-center gap-1">
            <button
              type="button"
              data-browser-action="back"
              title="Back"
              aria-label="Back"
              class="grid size-9 place-items-center rounded-sm border-2 border-base-content/20 transition hover:border-primary hover:text-primary"
            >
              <.icon name="hero-arrow-left" class="size-4" />
            </button>
            <button
              type="button"
              data-browser-action="forward"
              title="Forward"
              aria-label="Forward"
              class="grid size-9 place-items-center rounded-sm border-2 border-base-content/20 transition hover:border-primary hover:text-primary"
            >
              <.icon name="hero-arrow-right" class="size-4" />
            </button>
            <button
              type="button"
              data-browser-action="reload"
              title="Reload"
              aria-label="Reload"
              class="grid size-9 place-items-center rounded-sm border-2 border-base-content/20 transition hover:border-primary hover:text-primary"
            >
              <.icon name="hero-arrow-path" class="size-4" />
            </button>
          </div>

          <form data-browser-form class="flex flex-1 items-center gap-2">
            <input
              data-browser-address
              type="text"
              value={@initial_url}
              autocomplete="off"
              spellcheck="false"
              placeholder="https://… or /path in your workspace"
              class="input min-w-0 flex-1 font-mono text-sm"
            />
            <button
              type="submit"
              class="shrink-0 rounded bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"
            >
              Go
            </button>
          </form>
        </div>

        <%!-- The native webview is positioned over this surface by the hook. --%>
        <div
          data-browser-surface
          class="relative min-h-0 flex-1 rounded-sm border-2 border-base-content/15"
        >
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
