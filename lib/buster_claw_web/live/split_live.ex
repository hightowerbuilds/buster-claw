defmodule BusterClawWeb.SplitLive do
  @moduledoc """
  Renders two views side-by-side in one tab. Reached at
  `/split?left=<path>&right=<path>` when a user joins two tabs. Each pane is a
  nested `live_render` of the target view, mounted with `embedded: true` so its
  shell (tab strip / dock) is suppressed — see `BusterClawWeb.ChromeHook`.
  """
  use BusterClawWeb, :live_view

  # Views that are safe to embed in a split pane (they render from mount-set
  # assigns, not route params). Every workspace tab — including Home — is
  # joinable; chrome is suppressed centrally by `BusterClawWeb.ChromeHook` +
  # `Layouts.app`. Excluded only: /split itself (no nested splits) and /setup
  # (the first-run wizard).
  @panes %{
    "/" => {BusterClawWeb.StatusLive, "Home"},
    "/browse" => {BusterClawWeb.BrowseLive, "Browser"},
    "/calendar" => {BusterClawWeb.CalendarLive, "Calendar"},
    "/gws" => {BusterClawWeb.GWSLive, "GWS"},
    "/memory" => {BusterClawWeb.MemoryLive, "Memory"},
    "/scheduler" => {BusterClawWeb.SchedulerLive, "Scheduler"},
    "/terminal" => {BusterClawWeb.TerminalLive, "Terminal"},
    "/workspace" => {BusterClawWeb.WorkspaceLive, "Workspace"},
    "/integrations" => {BusterClawWeb.IntegrationsLive, "Integrations"},
    "/webhooks" => {BusterClawWeb.WebhooksLive, "Webhooks"},
    "/hooks" => {BusterClawWeb.HooksLive, "Hooks"},
    "/delivery" => {BusterClawWeb.DeliveryLive, "Delivery"},
    "/advanced" => {BusterClawWeb.DeliveryLive, "Advanced"},
    "/security" => {BusterClawWeb.SecurityLive, "Security"},
    "/settings" => {BusterClawWeb.SettingsLive, "Settings"},
    "/appearance" => {BusterClawWeb.AppearanceLive, "Appearance"},
    "/manual" => {BusterClawWeb.UserGuideLive, "Manual"}
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(BusterClaw.PubSub, BusterClaw.Appearance.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Split")
     |> assign(:terminal_background_url, BusterClaw.Appearance.terminal_background_url())}
  end

  @impl true
  def handle_info({:terminal_background, url}, socket) do
    {:noreply, assign(socket, :terminal_background_url, url)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:left, pane_spec(params["left"]))
     |> assign(:right, pane_spec(params["right"]))}
  end

  defp pane_spec(nil), do: nil

  defp pane_spec(path) when is_binary(path) do
    pathname = path |> String.split("?") |> hd()
    url = pane_url(path)

    case Map.fetch(@panes, pathname) do
      {:ok, {module, label}} ->
        %{
          path: path,
          module: module,
          label: label,
          url: url,
          child_session: pane_child_session(pathname, path, url)
        }

      :error ->
        %{path: path, module: nil, label: pathname, url: url, child_session: %{}}
    end
  end

  # Pull a `url` query param (if any) out of the pane's path.
  defp pane_url(path) do
    case URI.parse(path).query do
      nil -> nil
      query -> query |> URI.decode_query() |> Map.get("url")
    end
  end

  defp pane_params(path) do
    case URI.parse(path).query do
      nil -> %{}
      query -> URI.decode_query(query)
    end
  end

  defp pane_child_session("/terminal", path, _url) do
    params = pane_params(path)

    %{}
    |> maybe_put("terminal_session_key", params["session"])
    |> maybe_put("terminal_label", params["label"])
  end

  defp pane_child_session(_pathname, _path, nil), do: %{}
  defp pane_child_session(_pathname, _path, url), do: %{"url" => url}

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp pane_live_id(side, %{module: BusterClawWeb.TerminalLive, child_session: child_session}) do
    session_key = Map.get(child_session, "terminal_session_key", "main")
    "split-pane-#{side}-terminal-#{dom_id_part(session_key)}"
  end

  defp pane_live_id(side, _pane), do: "split-pane-#{side}"

  defp dom_id_part(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "main"
      id -> id
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :split_terminal_background_url,
        split_terminal_background_url(
          assigns.left,
          assigns.right,
          assigns.terminal_background_url
        )
      )

    ~H"""
    <Layouts.app flash={@flash} full_bleed>
      <div
        id="split-root"
        phx-hook="SplitResizer"
        data-split-terminal-bg-active={to_string(@split_terminal_background_url != nil)}
        data-terminal-bg-active={to_string(@split_terminal_background_url != nil)}
        class={[
          "flex min-h-0 flex-1 flex-col lg:flex-row",
          if(@split_terminal_background_url, do: "bg-cover bg-center", else: nil),
          @split_terminal_background_url && "bc-split-terminal-bg-active"
        ]}
        style={split_background_style(@split_terminal_background_url)}
      >
        <.pane
          side="left"
          class="bc-split-left"
          pane={@left}
          socket={@socket}
          bg_active={terminal_background_active?(@left, @split_terminal_background_url)}
        />
        <.split_divider />
        <.pane
          side="right"
          class="bc-split-right"
          pane={@right}
          socket={@socket}
          bg_active={terminal_background_active?(@right, @split_terminal_background_url)}
        />
      </div>
    </Layouts.app>
    """
  end

  # When a terminal background is set, the single image is painted on the shared
  # grid above only if at least one pane is terminal-backed. Terminal panes then
  # go transparent so terminal/terminal splits read as one continuous image,
  # while non-terminal panes retain their normal application surface.
  defp split_terminal_background_url(_left, _right, nil), do: nil

  defp split_terminal_background_url(left, right, url) do
    if terminal_pane?(left) or terminal_pane?(right), do: url
  end

  defp split_background_style(nil), do: nil
  defp split_background_style(url), do: "background-image:url('#{url}')"

  defp terminal_pane?(%{module: BusterClawWeb.TerminalLive}), do: true
  defp terminal_pane?(_pane), do: false

  defp terminal_background_active?(pane, url), do: terminal_pane?(pane) and not is_nil(url)

  # The draggable partition between the two joined panes. Dragging it resizes the
  # split (SplitResizer hook); the centered button swaps the two sides. Only shown
  # on the side-by-side (lg) layout.
  defp split_divider(assigns) do
    ~H"""
    <div
      data-split-divider
      title="Drag to resize"
      class="group relative hidden shrink-0 cursor-col-resize items-center justify-center lg:flex lg:w-3"
    >
      <span class="h-full w-px bg-base-content/15 transition group-hover:bg-primary"></span>
      <button
        type="button"
        data-split-swap
        title="Swap sides"
        aria-label="Swap sides"
        class="absolute grid size-6 cursor-pointer place-items-center rounded-full border border-base-300 bg-base-100 text-base-content/60 opacity-0 shadow-sm transition group-hover:opacity-100 hover:text-primary"
      >
        <.icon name="hero-arrows-right-left" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :side, :string, required: true
  attr :class, :string, default: nil
  attr :pane, :map, default: nil
  attr :socket, :map, required: true
  attr :bg_active, :boolean, default: false

  defp pane(assigns) do
    ~H"""
    <section
      data-split-pane={@side}
      data-split-pane-terminal={to_string(terminal_pane?(@pane))}
      data-terminal-bg-active={to_string(@bg_active)}
      class={[
        "relative flex min-h-0 min-w-0 flex-col overflow-hidden",
        @class,
        if(@bg_active,
          do: "bg-transparent",
          else: "rounded-lg border border-base-300 bg-base-100 shadow-sm"
        )
      ]}
    >
      <%!-- Close this pane and keep the other side as a solo tab. --%>
      <button
        type="button"
        data-split-close={@side}
        title="Close this pane"
        aria-label="Close this pane"
        class="absolute right-2 top-2 z-20 grid size-6 place-items-center rounded-full border border-base-300 bg-base-100/90 text-base-content/70 shadow-sm transition hover:border-error hover:text-error"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
      <%!-- Terminal panes carry their own toolbar (label + controls), so the
            split-pane header is redundant for them — skip it so the terminal
            toolbar sits flush at the top instead of below an empty header strip. --%>
      <header
        :if={not terminal_pane?(@pane)}
        class={[
          "flex items-center justify-between gap-2 px-4 py-2",
          if(@bg_active, do: "bg-transparent", else: "border-b border-base-300")
        ]}
      >
        <span class="truncate text-sm font-semibold">{pane_label(@pane)}</span>
      </header>
      <div class="min-h-0 flex-1 overflow-auto">
        <%= cond do %>
          <% is_nil(@pane) -> %>
            <p class="p-6 text-sm text-base-content/60">No view selected for this pane.</p>
          <% is_nil(@pane.module) -> %>
            <p class="p-6 text-sm text-base-content/60">
              "{@pane.label}" can't be opened in a split pane yet.
            </p>
          <% true -> %>
            {live_render(@socket, @pane.module,
              id: pane_live_id(@side, @pane),
              session: Map.put(@pane.child_session, "embedded", true)
            )}
        <% end %>
      </div>
    </section>
    """
  end

  defp pane_label(nil), do: "Empty"
  defp pane_label(%{label: label}), do: label
end
