defmodule BusterClawWeb.StatusLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Runtime.Status

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, status: Status.snapshot())}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket,
       current_view: socket.assigns.live_action,
       page_title: page_title(socket.assigns.live_action)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-8">
        <div class="space-y-2">
          <p class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            {@status.phase}
          </p>
          <h1 class="text-4xl font-semibold tracking-normal">Buster Claw Rewrite</h1>
          <p class="max-w-3xl text-base leading-7 text-base-content/70">
            Local-first Phoenix runtime for the Elixir parity rebuild.
          </p>
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <.status_card
            title="Library Root"
            value={@status.library_root}
            ok?={@status.library_exists?}
          />
          <.status_card
            title="SQLite Database"
            value={@status.database_path}
            ok?={@status.database_exists?}
          />
          <.status_card title="PubSub" value={@status.pubsub} ok?={true} />
          <.status_card title="Endpoint" value={@status.endpoint} ok?={true} />
        </div>

        <div class="grid gap-6 lg:grid-cols-2">
          <section class="rounded-lg border border-base-300 bg-base-100 p-5">
            <h2 class="text-lg font-semibold">Parity Views</h2>
            <div class="mt-4 grid gap-2 sm:grid-cols-2">
              <div
                :for={view <- @status.views}
                class={[
                  "rounded border px-3 py-2 text-sm",
                  if(view.key == @current_view,
                    do: "border-base-content bg-base-content text-base-100",
                    else: "border-base-300"
                  )
                ]}
              >
                <a href={view.path}>{view.label}</a>
              </div>
            </div>
          </section>

          <section class="rounded-lg border border-base-300 bg-base-100 p-5">
            <h2 class="text-lg font-semibold">Supervised Services</h2>
            <div class="mt-4 grid gap-2 sm:grid-cols-2">
              <div
                :for={service <- @status.services}
                class="rounded border border-base-300 px-3 py-2 text-sm"
              >
                {service}
              </div>
            </div>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp page_title(:home), do: "Runtime Status"

  defp page_title(action) do
    action
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :ok?, :boolean, required: true

  defp status_card(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100 p-5">
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <h2 class="text-sm font-semibold text-base-content/70">{@title}</h2>
          <p class="mt-2 break-words font-mono text-sm">{@value}</p>
        </div>
        <span class={[
          "rounded-full px-2 py-1 text-xs font-semibold",
          if(@ok?, do: "bg-success/15 text-success", else: "bg-warning/15 text-warning")
        ]}>
          {if @ok?, do: "ready", else: "pending"}
        </span>
      </div>
    </section>
    """
  end
end
