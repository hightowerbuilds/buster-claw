defmodule BusterClawWeb.StatusLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Calendar, as: AppCalendar
  alias BusterClaw.LocalTime
  alias BusterClaw.Orchestration
  alias BusterClaw.Runtime.Status
  alias BusterClaw.Setup

  @impl true
  def mount(_params, _session, socket) do
    today = LocalTime.today()

    if connected?(socket) do
      Orchestration.subscribe()
      # Keep time-left/heartbeats fresh even between events.
      :timer.send_interval(30_000, self(), :refresh_orchestration)
    end

    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(status: Status.snapshot())
     |> assign(:today, today)
     |> assign(:setup_status, Setup.status())
     |> assign(:orchestration, Orchestration.snapshot())
     |> load_daily_events()}
  end

  @impl true
  def handle_info({:orchestration, _event}, socket) do
    {:noreply, assign(socket, :orchestration, Orchestration.snapshot())}
  end

  def handle_info(:refresh_orchestration, socket) do
    {:noreply, assign(socket, :orchestration, Orchestration.snapshot())}
  end

  @impl true
  def handle_event("kill_shift", _params, socket) do
    Orchestration.engage_kill_switch()
    Orchestration.stop_shift("kill switch")
    {:noreply, assign(socket, :orchestration, Orchestration.snapshot())}
  end

  def handle_event("delete_task", %{"id" => id}, socket) do
    case Orchestration.get_task(id) do
      nil -> :ok
      task -> Orchestration.delete_task(task)
    end

    {:noreply, assign(socket, :orchestration, Orchestration.snapshot())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="flex flex-1 flex-col space-y-8">
        <div class="space-y-4 border-b-2 border-base-content/20 pb-5">
          <img
            src={~p"/images/busterclaw-logo.png"}
            alt="Buster Claw"
            class="block h-auto w-full max-w-[28rem]"
          />
          <div :if={not @setup_status.complete?} class="pt-1">
            <.link
              navigate={~p"/setup"}
              class="inline-flex items-center gap-2 rounded bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"
            >
              <.icon name="hero-sparkles" class="size-4" />
              <span :if={@setup_status.completed == 0}>Set up Buster Claw</span>
              <span :if={@setup_status.completed > 0}>
                Finish setup · {@setup_status.completed} of {@setup_status.total} complete
              </span>
            </.link>
          </div>
        </div>

        <div class="grid min-h-0 flex-1 gap-6 lg:grid-cols-2">
          <BusterClawWeb.OrchestrationPanel.panel snapshot={@orchestration} />

          <.daily_calendar_panel today={@today} events={@daily_events} />
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :today, Date, required: true
  attr :events, :list, required: true

  defp daily_calendar_panel(assigns) do
    ~H"""
    <section id="home-daily-calendar" class="ic-panel">
      <header class="flex flex-wrap items-center justify-between gap-3 border-b-2 border-base-content/20 px-5 py-4">
        <div>
          <p class="ic-eyebrow">Today's Calendar</p>
          <h2 class="font-display text-2xl font-black uppercase tracking-tight">
            {Elixir.Calendar.strftime(@today, "%A, %B %-d")}
          </h2>
        </div>

        <.link
          navigate={~p"/calendar"}
          class="rounded-sm border-2 border-base-content/25 px-3 py-2 font-mono text-xs uppercase tracking-wide text-base-content/70 transition hover:border-primary hover:text-primary"
        >
          Open Calendar
        </.link>
      </header>

      <div class="p-5">
        <ol :if={@events != []} class="divide-y divide-base-300 rounded border border-base-300">
          <li
            :for={event <- @events}
            id={"home-event-#{event.id}-#{Date.to_iso8601(event.date)}"}
            class="grid gap-3 px-4 py-3 text-sm sm:grid-cols-[7rem_minmax(0,1fr)] sm:items-start"
          >
            <div class="font-mono text-xs font-semibold uppercase tracking-wide text-primary">
              {event_time_label(event)}
            </div>
            <div class="min-w-0">
              <div class="flex min-w-0 items-center gap-2">
                <span class={["size-2.5 shrink-0 rounded-full", event_dot_class(event.color)]} />
                <h3 class="truncate font-semibold">{event.title}</h3>
                <span
                  :if={event.frequency}
                  class="rounded-full bg-base-200 px-2 py-0.5 text-xs font-semibold text-base-content/60"
                >
                  {event.frequency}
                </span>
              </div>
              <p
                :if={event.notes not in [nil, ""]}
                class="mt-1 line-clamp-2 text-sm text-base-content/60"
              >
                {event.notes}
              </p>
            </div>
          </li>
        </ol>

        <div
          :if={@events == []}
          class="rounded border border-dashed border-base-300 px-4 py-10 text-center text-sm text-base-content/60"
        >
          Nothing scheduled today.
        </div>
      </div>
    </section>
    """
  end

  defp event_time_label(%{start_time: nil}), do: "All day"

  defp event_time_label(%{start_time: start_time, end_time: nil}),
    do: format_event_time(start_time)

  defp event_time_label(%{start_time: start_time, end_time: end_time}),
    do: "#{format_event_time(start_time)}-#{format_event_time(end_time)}"

  defp format_event_time(%Time{} = time), do: Elixir.Calendar.strftime(time, "%H:%M")

  defp event_dot_class(color) do
    case color do
      "work" -> "bg-info"
      "personal" -> "bg-secondary"
      "social" -> "bg-accent"
      "travel" -> "bg-warning"
      "health" -> "bg-success"
      "holiday" -> "bg-error"
      _ -> "bg-base-content/40"
    end
  end

  defp load_daily_events(socket) do
    today = socket.assigns.today

    events =
      today
      |> AppCalendar.events_in_range(today)
      |> Enum.sort_by(&daily_event_sort_key/1)

    assign(socket, :daily_events, events)
  end

  defp daily_event_sort_key(%{start_time: nil}), do: {0, ~T[00:00:00]}
  defp daily_event_sort_key(%{start_time: time}), do: {1, time}
end
