defmodule BusterClawWeb.MCPLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.MCP

  @empty_form %{
    "name" => "",
    "command" => "",
    "args" => "{}",
    "env" => "{}",
    "enabled" => "true"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, MCP.topic())

    {:ok,
     socket
     |> assign(:page_title, "MCP")
     |> assign(:form, @empty_form)
     |> assign(:servers, MCP.list_servers())}
  end

  @impl true
  def handle_event("save", %{"server" => attrs}, socket) do
    attrs = Map.update(attrs, "enabled", false, &(&1 in ["true", "on"]))

    socket =
      case MCP.create_server(attrs) do
        {:ok, _server} ->
          socket
          |> put_flash(:info, "MCP server saved.")
          |> assign(:form, @empty_form)
          |> assign(:servers, MCP.list_servers())

        {:error, changeset} ->
          put_flash(socket, :error, error_text(changeset))
      end

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    MCP.get_server!(id) |> MCP.delete_server()
    {:noreply, assign(socket, :servers, MCP.list_servers())}
  end

  def handle_event("connect", %{"id" => id}, socket) do
    socket =
      id
      |> MCP.get_server!()
      |> MCP.discover_tools()
      |> case do
        {:ok, tools} ->
          socket
          |> put_flash(:info, "MCP server connected with #{length(tools)} tools.")
          |> assign(:servers, MCP.list_servers())

        {:error, reason} ->
          socket
          |> put_flash(:error, BusterClawWeb.ErrorFormatter.format(reason))
          |> assign(:servers, MCP.list_servers())
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:mcp_changed, _server}, socket) do
    {:noreply, assign(socket, :servers, MCP.list_servers())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <BusterClawWeb.AdvancedTabs.tabs active={:mcp} />

        <section class="space-y-6">
          <form
            phx-submit="save"
            class="grid gap-3 rounded-lg border border-base-300 p-4 md:grid-cols-2"
          >
            <input
              name="server[name]"
              value={@form["name"]}
              placeholder="Name"
              class="rounded border border-base-300 bg-base-100 px-3 py-2 text-sm"
            />
            <input
              name="server[command]"
              value={@form["command"]}
              placeholder="Command"
              class="rounded border border-base-300 bg-base-100 px-3 py-2 text-sm"
            />
            <textarea
              name="server[args]"
              class="min-h-20 rounded border border-base-300 bg-base-100 px-3 py-2 text-sm"
            >{@form["args"]}</textarea>
            <textarea
              name="server[env]"
              class="min-h-20 rounded border border-base-300 bg-base-100 px-3 py-2 text-sm"
            >{@form["env"]}</textarea>
            <label class="flex items-center gap-2 text-sm">
              <input type="checkbox" name="server[enabled]" value="true" checked /> Enabled
            </label>
            <button class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100">
              Save Server
            </button>
          </form>

          <section class="space-y-3">
            <div :for={server <- @servers} class="rounded-lg border border-base-300 p-4">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <h2 class="text-lg font-semibold">{server.name}</h2>
                  <p class="text-sm text-base-content/70">{server.command}</p>
                </div>
                <button
                  phx-click="delete"
                  phx-value-id={server.id}
                  class="rounded border border-base-300 px-3 py-2 text-sm"
                >
                  Delete
                </button>
                <button
                  phx-click="connect"
                  phx-value-id={server.id}
                  disabled={!server.enabled}
                  class="rounded bg-base-content px-3 py-2 text-sm font-semibold text-base-100 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  Connect
                </button>
              </div>
              <div class="mt-3 grid gap-2 text-sm md:grid-cols-3">
                <div>Status: {server.last_status || "configured"}</div>
                <div>Enabled: {if server.enabled, do: "yes", else: "no"}</div>
                <div>Error: {server.last_error || "none"}</div>
              </div>
            </div>

            <div
              :if={@servers == []}
              class="rounded-lg border border-dashed border-base-300 p-6 text-sm text-base-content/60"
            >
              No MCP servers configured.
            </div>
          </section>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp error_text(changeset) do
    changeset.errors
    |> Enum.map_join(", ", fn {field, {message, _}} -> "#{field} #{message}" end)
  end
end
