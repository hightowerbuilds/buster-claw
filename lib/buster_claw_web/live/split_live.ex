defmodule BusterClawWeb.SplitLive do
  @moduledoc """
  Renders two views side-by-side in one tab. Reached at
  `/split?left=<path>&right=<path>` when a user joins two tabs. Each pane is a
  nested `live_render` of the target view, mounted with `embedded: true` so its
  shell (tab strip / dock) is suppressed — see `BusterClawWeb.ChromeHook`.
  """
  use BusterClawWeb, :live_view

  # Views that are safe to embed in a split pane (mount without route params).
  # Every workspace tab is joinable; chrome is suppressed centrally by
  # `BusterClawWeb.ChromeHook` + `Layouts.app`. Excluded: Home (StatusLive uses
  # handle_params, not allowed in an embedded child), /split itself, and /setup.
  @panes %{
    "/orchestration" => {BusterClawWeb.OrchestrationLive, "Orchestration"},
    "/browse" => {BusterClawWeb.BrowseLive, "Browser"},
    "/calendar" => {BusterClawWeb.CalendarLive, "Calendar"},
    "/gws" => {BusterClawWeb.GWSLive, "GWS"},
    "/memory" => {BusterClawWeb.MemoryLive, "Memory"},
    "/scheduler" => {BusterClawWeb.SchedulerLive, "Scheduler"},
    "/terminal" => {BusterClawWeb.TerminalLive, "Terminal"},
    "/workspace" => {BusterClawWeb.WorkspaceLive, "Workspace"},
    "/integrations" => {BusterClawWeb.IntegrationsLive, "Integrations"},
    "/mcp" => {BusterClawWeb.MCPLive, "MCP"},
    "/webhooks" => {BusterClawWeb.WebhooksLive, "Webhooks"},
    "/hooks" => {BusterClawWeb.HooksLive, "Hooks"},
    "/delivery" => {BusterClawWeb.DeliveryLive, "Delivery"},
    "/advanced" => {BusterClawWeb.DeliveryLive, "Advanced"},
    "/security" => {BusterClawWeb.SecurityLive, "Security"},
    "/settings" => {BusterClawWeb.SettingsLive, "Settings"},
    "/appearance" => {BusterClawWeb.AppearanceLive, "Appearance"}
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
    ~H"""
    <Layouts.app flash={@flash} full_bleed>
      <div
        class={[
          "grid min-h-0 flex-1 lg:grid-cols-2",
          if(@terminal_background_url, do: "gap-0 p-0 bg-cover bg-center", else: "gap-3 p-3")
        ]}
        style={split_background_style(@terminal_background_url)}
      >
        <.pane side="left" pane={@left} socket={@socket} bg_active={@terminal_background_url != nil} />
        <.pane
          side="right"
          pane={@right}
          socket={@socket}
          bg_active={@terminal_background_url != nil}
        />
      </div>
    </Layouts.app>
    """
  end

  # When a terminal background is set, the single image is painted on the shared
  # grid above; the panes go transparent so it reads as one continuous image
  # spanning both, rather than two copies.
  defp split_background_style(nil), do: nil
  defp split_background_style(url), do: "background-image:url('#{url}')"

  attr :side, :string, required: true
  attr :pane, :map, default: nil
  attr :socket, :map, required: true
  attr :bg_active, :boolean, default: false

  defp pane(assigns) do
    ~H"""
    <section class={[
      "flex min-h-0 min-w-0 flex-col overflow-hidden",
      if(@bg_active,
        do: "bg-transparent",
        else: "rounded-lg border border-base-300 bg-base-100 shadow-sm"
      )
    ]}>
      <header class={[
        "flex items-center justify-between gap-2 px-4 py-2",
        unless(@bg_active, do: "border-b border-base-300")
      ]}>
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
