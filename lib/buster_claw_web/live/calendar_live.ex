defmodule BusterClawWeb.CalendarLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Calendar
  alias BusterClaw.Calendar.Event

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Calendar")
     |> assign(:editing_event, nil)
     |> assign(:result, nil)
     |> assign_form(Event.changeset(%Event{}, default_attrs()))
     |> load_events()}
  end

  @impl true
  def handle_event("validate", %{"event" => params}, socket) do
    event = socket.assigns.editing_event || %Event{}

    changeset =
      event
      |> Event.changeset(normalize_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"event" => params}, socket) do
    params = normalize_params(params)

    result =
      case socket.assigns.editing_event do
        nil -> Calendar.create_event(ensure_event_id(params))
        event -> Calendar.update_event(event, params)
      end

    case result do
      {:ok, _event} ->
        {:noreply,
         socket
         |> assign(:editing_event, nil)
         |> assign(:result, "Event saved.")
         |> assign_form(Event.changeset(%Event{}, default_attrs()))
         |> load_events()}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    event = Calendar.get_event!(id)

    {:noreply,
     socket
     |> assign(:editing_event, event)
     |> assign(:result, nil)
     |> assign_form(Event.changeset(event, %{}))}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_event, nil)
     |> assign(:result, nil)
     |> assign_form(Event.changeset(%Event{}, default_attrs()))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    event = Calendar.get_event!(id)
    {:ok, _event} = Calendar.delete_event(event)

    {:noreply,
     socket
     |> assign(:editing_event, nil)
     |> assign(:result, "Event deleted.")
     |> assign_form(Event.changeset(%Event{}, default_attrs()))
     |> load_events()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              Planning
            </p>
            <h1 class="text-4xl font-semibold tracking-normal">Calendar</h1>
            <p class="mt-2 text-base text-base-content/70">
              Durable event records imported from or authored for the local schedule.
            </p>
          </div>
        </div>

        <p :if={@result} class="rounded border border-base-300 bg-base-100 px-4 py-3 text-sm">
          {@result}
        </p>

        <div class="grid gap-6 lg:grid-cols-[380px_minmax(0,1fr)]">
          <.form
            for={@form}
            id="event-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-4 rounded-lg border border-base-300 bg-base-100 p-5"
          >
            <h2 class="text-lg font-semibold">
              {if @editing_event, do: "Edit Event", else: "Add Event"}
            </h2>
            <.input field={@form[:date]} label="Date" type="date" />
            <.input field={@form[:title]} label="Title" />
            <.input field={@form[:notes]} label="Notes" type="textarea" />
            <.input field={@form[:event_id]} label="Event ID" />
            <div class="flex gap-2">
              <button class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100">
                Save
              </button>
              <button
                :if={@editing_event}
                type="button"
                class="rounded border border-base-300 px-4 py-2 text-sm"
                phx-click="cancel"
              >
                Cancel
              </button>
            </div>
          </.form>

          <section class="rounded-lg border border-base-300 bg-base-100">
            <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
              {@events_count} events
            </div>

            <div class="divide-y divide-base-300">
              <div :for={event <- @events} class="px-4 py-4">
                <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                  <div class="min-w-0">
                    <h2 class="text-sm font-semibold">{event.title}</h2>
                    <p class="mt-1 font-mono text-xs text-base-content/60">{event.date}</p>
                    <p :if={event.notes} class="mt-2 whitespace-pre-wrap text-sm text-base-content/70">
                      {event.notes}
                    </p>
                  </div>

                  <div class="flex gap-2">
                    <button
                      class="rounded border border-base-300 px-3 py-2 text-sm"
                      phx-click="edit"
                      phx-value-id={event.id}
                    >
                      Edit
                    </button>
                    <button
                      class="rounded border border-error/40 px-3 py-2 text-sm text-error"
                      phx-click="delete"
                      phx-value-id={event.id}
                    >
                      Delete
                    </button>
                  </div>
                </div>
              </div>

              <div :if={@events == []} class="px-4 py-10 text-center text-sm text-base-content/60">
                No calendar events yet.
              </div>
            </div>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp load_events(socket) do
    events =
      Calendar.list_events()
      |> Enum.sort_by(& &1.date, Date)

    socket
    |> assign(:events, events)
    |> assign(:events_count, length(events))
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  defp default_attrs, do: %{date: Date.utc_today(), event_id: Ecto.UUID.generate()}

  defp normalize_params(params) do
    params
    |> Map.update("date", nil, &parse_date/1)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp ensure_event_id(params) do
    case Map.get(params, "event_id") || Map.get(params, :event_id) do
      value when value in [nil, ""] -> Map.put(params, "event_id", Ecto.UUID.generate())
      _value -> params
    end
  end

  defp parse_date(%Date{} = date), do: date
  defp parse_date(""), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> value
    end
  end

  defp parse_date(value), do: value
end
