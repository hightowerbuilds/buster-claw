defmodule BusterClawWeb.StatusLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Calendar, as: AppCalendar
  alias BusterClaw.LocalTime
  alias BusterClaw.Runtime.Status
  alias BusterClaw.Setup
  alias BusterClaw.TrustedSenders

  @impl true
  def mount(_params, _session, socket) do
    today = LocalTime.today()

    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(status: Status.snapshot())
     |> assign(:today, today)
     |> assign(:setup_status, Setup.status())
     |> assign(:trusted_contacts, TrustedSenders.list_entries())
     |> load_daily_events()}
  end

  @impl true
  def handle_event("add_contact", %{"entry" => entry}, socket) do
    case TrustedSenders.add_entry(entry) do
      {:ok, _value} ->
        {:noreply, assign(socket, :trusted_contacts, TrustedSenders.list_entries())}

      {:error, :invalid_entry} ->
        {:noreply,
         put_flash(socket, :error, "Enter a full email address or a *@domain wildcard.")}
    end
  end

  def handle_event("remove_contact", %{"entry" => entry}, socket) do
    TrustedSenders.remove_entry(entry)
    {:noreply, assign(socket, :trusted_contacts, TrustedSenders.list_entries())}
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
          <div class="flex min-h-0 flex-col gap-6">
            <.get_started_panel />
            <BusterClawWeb.TrustedContactsPanel.panel entries={@trusted_contacts} />
          </div>

          <.daily_calendar_panel today={@today} events={@daily_events} />
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp get_started_panel(assigns) do
    ~H"""
    <section id="home-get-started" class="ic-panel flex min-h-64 flex-1 flex-col">
      <header class="border-b-2 border-base-content/20 px-5 py-4">
        <p class="ic-eyebrow">Get Started</p>
        <h2 class="font-display text-2xl font-black uppercase tracking-tight">
          Get Started
        </h2>
        <p class="mt-1 text-sm text-base-content/65">
          Three steps to put Buster Claw on email duty (Google Workspace already connected).
        </p>
      </header>

      <ol class="flex min-h-0 flex-1 flex-col gap-4 overflow-auto p-5">
        <li class="flex gap-3">
          <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
            1
          </span>
          <div class="min-w-0">
            <h3 class="font-semibold">Add your trusted contacts</h3>
            <p class="mt-0.5 text-sm text-base-content/65">
              In the panel below, list the senders the agent may read and reply to.
              Mail from anyone else is ignored.
            </p>
          </div>
        </li>

        <li class="flex gap-3">
          <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
            2
          </span>
          <div class="min-w-0">
            <h3 class="font-semibold">Start the agent</h3>
            <p class="mt-0.5 text-sm text-base-content/65">
              Open the <.link
                navigate={~p"/terminal"}
                class="font-semibold text-primary hover:underline"
              >Terminal</.link>
              and start a Claude Code session on the <span class="font-mono">mail-triage</span>
              job. That's the worker that reads queued mail and writes the replies.
            </p>
          </div>
        </li>

        <li class="flex gap-3">
          <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
            3
          </span>
          <div class="min-w-0">
            <h3 class="font-semibold">Go on duty</h3>
            <p class="mt-0.5 text-sm text-base-content/65">
              In a terminal, run <.copy_command command="./buster-claw shift run" />. It starts a
              shift and polls your trusted mail until you stop it (Ctrl-C, then
              <.copy_command command="./buster-claw shift stop" />).
            </p>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  attr :command, :string, required: true

  defp copy_command(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 align-middle">
      <code class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-[0.8rem]">{@command}</code>
      <button
        type="button"
        data-terminal-command-copy={@command}
        aria-label={"Copy command: #{@command}"}
        title="Copy"
        class="inline-flex shrink-0 items-center gap-1 rounded-sm border border-base-content/20 px-1.5 py-0.5 font-mono text-[0.62rem] font-semibold uppercase tracking-wide text-base-content/60 transition hover:border-primary hover:text-primary"
      >
        <.icon name="hero-clipboard-document" class="size-3" />
        <span data-terminal-command-copy-label>Copy</span>
      </button>
    </span>
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
