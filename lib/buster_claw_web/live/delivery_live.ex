defmodule BusterClawWeb.DeliveryLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Automation.DeliveryDestination
  alias BusterClaw.Delivery

  @impl true
  def mount(_params, _session, socket) do
    changeset =
      Delivery.change_destination(%DeliveryDestination{}, %{type: "slack", enabled: true})

    {:ok,
     socket
     |> assign(:page_title, "Delivery")
     |> assign(:form, to_form(changeset))
     |> assign(:result, nil)
     |> load_destinations()}
  end

  @impl true
  def handle_event("validate", %{"delivery_destination" => params}, socket) do
    changeset =
      %DeliveryDestination{}
      |> Delivery.change_destination(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"delivery_destination" => params}, socket) do
    case Delivery.create_destination(params) do
      {:ok, _destination} ->
        {:noreply,
         socket
         |> assign(
           :form,
           to_form(Delivery.change_destination(%DeliveryDestination{}, %{type: "slack"}))
         )
         |> assign(:result, "Delivery destination saved.")
         |> load_destinations()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("test", %{"id" => id}, socket) do
    result =
      id
      |> Delivery.get_destination!()
      |> Delivery.test_destination()
      |> format_attempt()

    {:noreply, assign(socket, :result, result)}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    destination = Delivery.get_destination!(id)

    {:ok, _destination} =
      Delivery.update_destination(destination, %{enabled: !destination.enabled})

    {:noreply, load_destinations(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    id |> Delivery.get_destination!() |> Delivery.delete_destination()
    {:noreply, socket |> assign(:result, "Delivery destination deleted.") |> load_destinations()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <BusterClawWeb.AdvancedTabs.tabs active={:delivery} />

        <section class="space-y-6">
          <p :if={@result} class="rounded border border-base-300 bg-base-100 px-4 py-3 text-sm">
            {@result}
          </p>

          <div class="grid gap-6 lg:grid-cols-[380px_minmax(0,1fr)]">
            <.form
              for={@form}
              id="delivery-destination-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4 rounded-lg border border-base-300 bg-base-100 p-5"
            >
              <h2 class="text-lg font-semibold">New Destination</h2>
              <.input field={@form[:name]} label="Name" />
              <.input
                field={@form[:type]}
                label="Type"
                type="select"
                options={[
                  {"Slack", "slack"},
                  {"Discord", "discord"},
                  {"Telegram", "telegram"},
                  {"Email", "email"}
                ]}
              />
              <.input field={@form[:url]} label="URL" />
              <.input field={@form[:token]} label="Token" />
              <.input field={@form[:chat_id]} label="Chat ID" />
              <.input field={@form[:enabled]} label="Enabled" type="checkbox" />
              <button class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100">
                Save Destination
              </button>
            </.form>

            <section class="rounded-lg border border-base-300 bg-base-100">
              <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
                {@destinations_count} destinations
              </div>
              <div class="divide-y divide-base-300">
                <div
                  :for={destination <- @destinations}
                  class="flex flex-col gap-4 px-4 py-4 sm:flex-row sm:items-center sm:justify-between"
                >
                  <div class="min-w-0">
                    <h2 class="truncate text-sm font-semibold">{destination.name}</h2>
                    <p class="mt-1 truncate font-mono text-xs text-base-content/60">
                      {destination.url || "No URL configured"}
                    </p>
                    <div class="mt-2 flex flex-wrap gap-2 text-xs">
                      <span class="rounded border border-base-300 px-2 py-1">{destination.type}</span>
                      <span class="rounded border border-base-300 px-2 py-1">
                        {if destination.enabled, do: "enabled", else: "disabled"}
                      </span>
                    </div>
                  </div>

                  <div class="flex flex-wrap gap-2">
                    <button
                      class="rounded border border-base-300 px-3 py-2 text-sm"
                      phx-click="test"
                      phx-value-id={destination.id}
                    >
                      Test
                    </button>
                    <button
                      class="rounded border border-base-300 px-3 py-2 text-sm"
                      phx-click="toggle"
                      phx-value-id={destination.id}
                    >
                      Toggle
                    </button>
                    <button
                      class="rounded border border-error/40 px-3 py-2 text-sm text-error"
                      phx-click="delete"
                      phx-value-id={destination.id}
                    >
                      Delete
                    </button>
                  </div>
                </div>
                <div
                  :if={@destinations == []}
                  class="px-4 py-10 text-center text-sm text-base-content/60"
                >
                  No delivery destinations configured yet.
                </div>
              </div>
            </section>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp load_destinations(socket) do
    destinations = Delivery.list_destinations()

    socket
    |> assign(:destinations, destinations)
    |> assign(:destinations_count, length(destinations))
  end

  defp format_attempt({:ok, attempt}) do
    if attempt.status == "sent",
      do: "Delivery test sent.",
      else: "Delivery test failed: #{attempt.error}"
  end
end
