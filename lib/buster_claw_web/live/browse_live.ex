defmodule BusterClawWeb.BrowseLive do
  @moduledoc """
  In-app browser. Fetches pages through `BusterClaw.Browser` (sidecar or HTTP,
  SSRF-guarded) and renders them as a safe reader view. Links inside a page
  re-fetch in place so the user never leaves the app; the app-nav sidebar in
  `Layouts.app` (with its bumper) is always present to return to the rest of
  the app.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Browser
  alias BusterClaw.Browser.Reader
  alias BusterClawWeb.ErrorFormatter

  @impl true
  def mount(params, session, socket) do
    socket =
      socket
      |> assign(:page_title, "Browse")
      |> assign(:address, "")
      |> assign(:current_url, nil)
      |> assign(:title, nil)
      |> assign(:tokens, [])
      |> assign(:status, :idle)
      |> assign(:error, nil)
      |> assign(:back, [])
      |> assign(:forward, [])

    # Deep link (e.g. /browse?url=...) loads on mount. Handled here rather than
    # in handle_params so BrowseLive can also be embedded as a split pane
    # (nested live_render children may not define handle_params/3). A new
    # browser tab (/browse?t=...) carries no url and opens blank. When embedded
    # as a split pane, SplitLive passes the page url via session["url"] instead
    # (params may be :not_mounted_at_router for nested children).
    url =
      case params do
        %{"url" => url} when is_binary(url) and url != "" -> url
        _ -> session["url"]
      end

    socket =
      case url do
        url when is_binary(url) and url != "" -> open(socket, url)
        _ -> socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("navigate", %{"url" => url}, socket) do
    {:noreply, open(socket, url)}
  end

  def handle_event("browse_link", %{"url" => url}, socket) do
    {:noreply, open(socket, url)}
  end

  def handle_event("back", _params, socket) do
    case socket.assigns.back do
      [] ->
        {:noreply, socket}

      [previous | rest] ->
        forward = push_current(socket.assigns.forward, socket.assigns.current_url)
        {:noreply, socket |> assign(back: rest, forward: forward) |> fetch_into(previous)}
    end
  end

  def handle_event("forward", _params, socket) do
    case socket.assigns.forward do
      [] ->
        {:noreply, socket}

      [next | rest] ->
        back = push_current(socket.assigns.back, socket.assigns.current_url)
        {:noreply, socket |> assign(forward: rest, back: back) |> fetch_into(next)}
    end
  end

  def handle_event("reload", _params, socket) do
    case socket.assigns.current_url do
      nil -> {:noreply, socket}
      url -> {:noreply, fetch_into(socket, url)}
    end
  end

  # Navigate to a brand-new destination (address bar or in-page link): the
  # current page is pushed onto the back stack and the forward stack is cleared.
  defp open(socket, raw_url) do
    case normalize(raw_url) do
      nil ->
        assign(socket, status: :error, error: "Enter a URL to browse.")

      url ->
        back = push_current(socket.assigns.back, socket.assigns.current_url)
        socket |> assign(back: back, forward: []) |> fetch_into(url)
    end
  end

  # Fetch `url` and render it, or record an error. Does not touch the history
  # stacks (callers manage those).
  defp fetch_into(socket, url) do
    case Browser.fetch(url) do
      {:ok, page} ->
        socket
        |> assign(:status, :ok)
        |> assign(:error, nil)
        |> assign(:current_url, page.url)
        |> assign(:address, page.url)
        |> assign(:title, page.title)
        |> assign(:tokens, Reader.to_tokens(page.html, page.url))
        |> push_event("bc:tab_meta", %{title: page.title, url: page.url})

      {:error, {:blocked_url, _reason}} ->
        assign(socket,
          status: :error,
          error: "That address is blocked for safety (loopback or private network)."
        )

      {:error, reason} ->
        assign(socket,
          status: :error,
          error: "Couldn't load #{url}: #{ErrorFormatter.format(reason)}"
        )
    end
  end

  defp push_current(stack, nil), do: stack
  defp push_current(stack, url), do: [url | stack]

  defp normalize(url) do
    case String.trim(to_string(url)) do
      "" -> nil
      trimmed -> if String.contains?(trimmed, "://"), do: trimmed, else: "https://" <> trimmed
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-4">
        <div>
          <p class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Browser
          </p>
          <h1 class="text-4xl font-semibold tracking-normal">Browse</h1>
          <p class="mt-2 text-base text-base-content/70">
            Fetch and read pages in-app. Links stay inside Buster Claw — use the
            sidebar bumper on the left to return to the rest of the app.
          </p>
        </div>

        <div class="flex items-center gap-2 rounded-lg border border-base-300 bg-base-100 p-2 shadow-sm">
          <div class="flex items-center gap-1">
            <button
              type="button"
              title="Back"
              aria-label="Back"
              phx-click="back"
              disabled={@back == []}
              class="grid size-9 place-items-center rounded border border-base-300 transition hover:bg-base-200 disabled:opacity-40"
            >
              <.icon name="hero-arrow-left" class="size-4" />
            </button>
            <button
              type="button"
              title="Forward"
              aria-label="Forward"
              phx-click="forward"
              disabled={@forward == []}
              class="grid size-9 place-items-center rounded border border-base-300 transition hover:bg-base-200 disabled:opacity-40"
            >
              <.icon name="hero-arrow-right" class="size-4" />
            </button>
            <button
              type="button"
              title="Reload"
              aria-label="Reload"
              phx-click="reload"
              disabled={is_nil(@current_url)}
              class="grid size-9 place-items-center rounded border border-base-300 transition hover:bg-base-200 disabled:opacity-40"
            >
              <.icon name="hero-arrow-path" class="size-4" />
            </button>
          </div>

          <form phx-submit="navigate" class="flex flex-1 items-center gap-2">
            <input
              type="text"
              name="url"
              value={@address}
              autocomplete="off"
              spellcheck="false"
              placeholder="Enter a URL, e.g. example.com"
              class="min-w-0 flex-1 rounded border border-base-300 bg-base-100 px-3 py-2 font-mono text-sm focus:border-base-content/40 focus:outline-none"
            />
            <button
              type="submit"
              class="shrink-0 rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100 transition hover:opacity-90"
            >
              Go
            </button>
          </form>
        </div>

        <div
          :if={@error}
          class="rounded-lg border border-error/40 bg-error/10 px-4 py-3 text-sm text-error"
        >
          {@error}
        </div>

        <article
          :if={@status == :ok}
          class="min-h-[60vh] rounded-lg border border-base-300 bg-base-100 p-6 shadow-sm"
        >
          <header class="mb-4 border-b border-base-300 pb-4">
            <h2 class="text-2xl font-semibold tracking-normal">{@title}</h2>
            <p class="mt-1 break-words font-mono text-xs text-base-content/60">{@current_url}</p>
          </header>

          <div class="max-w-none leading-7 text-base-content/90">
            <%= for token <- @tokens do %>
              <span :if={elem(token, 0) == :text} class="whitespace-pre-wrap">{elem(token, 1)}</span><button
                :if={elem(token, 0) == :link}
                type="button"
                phx-click="browse_link"
                phx-value-url={elem(token, 2)}
                title={elem(token, 2)}
                class="text-info underline decoration-dotted underline-offset-2 transition hover:decoration-solid"
              >{elem(token, 1)}</button>
            <% end %>
          </div>
        </article>

        <div
          :if={@status != :ok && is_nil(@error)}
          class="grid min-h-[40vh] place-items-center rounded-lg border border-dashed border-base-300 p-8 text-center text-sm text-base-content/60"
        >
          <div>
            <.icon name="hero-globe-alt" class="mx-auto size-10 text-base-content/30" />
            <h2 class="mt-3 text-base font-semibold text-base-content">Nothing loaded yet</h2>
            <p class="mt-2">Enter a URL above to start browsing inside the app.</p>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
