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
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Split")}

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
      {:ok, {module, label}} -> %{path: path, module: module, label: label, url: url}
      :error -> %{path: path, module: nil, label: pathname, url: url}
    end
  end

  # Pull a `url` query param (if any) out of the pane's path.
  defp pane_url(path) do
    case URI.parse(path).query do
      nil -> nil
      query -> query |> URI.decode_query() |> Map.get("url")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} full_bleed>
      <div class="grid min-h-0 flex-1 gap-3 p-3 lg:grid-cols-2">
        <.pane side="left" pane={@left} socket={@socket} />
        <.pane side="right" pane={@right} socket={@socket} />
      </div>
    </Layouts.app>
    """
  end

  attr :side, :string, required: true
  attr :pane, :map, default: nil
  attr :socket, :map, required: true

  defp pane(assigns) do
    ~H"""
    <section class="flex min-h-0 min-w-0 flex-col overflow-hidden rounded-lg border border-base-300 bg-base-100 shadow-sm">
      <header class="flex items-center justify-between gap-2 border-b border-base-300 px-4 py-2">
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
              id: "split-pane-#{@side}",
              session: %{"embedded" => true, "url" => @pane.url}
            )}
        <% end %>
      </div>
    </section>
    """
  end

  defp pane_label(nil), do: "Empty"
  defp pane_label(%{label: label}), do: label
end
