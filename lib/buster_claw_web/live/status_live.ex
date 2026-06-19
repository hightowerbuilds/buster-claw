defmodule BusterClawWeb.StatusLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.ActivityReport
  alias BusterClaw.Calendar, as: AppCalendar
  alias BusterClaw.Dispatch
  alias BusterClaw.LocalTime
  alias BusterClaw.Orchestration
  alias BusterClaw.Runtime.Status
  alias BusterClaw.Setup
  alias BusterClaw.TrustedSenders

  @impl true
  def mount(_params, _session, socket) do
    today = LocalTime.today()

    if connected?(socket) do
      Orchestration.subscribe()
      Dispatch.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(status: Status.snapshot())
     |> assign(:today, today)
     |> assign(:setup_status, Setup.status())
     |> assign(:trusted_contacts, TrustedSenders.list_entries())
     |> assign_shift()
     |> assign_report()
     |> load_daily_events()}
  end

  defp assign_shift(socket) do
    socket
    |> assign(:shift, Orchestration.active_shift())
    |> assign(:kill_switch, Orchestration.kill_switch_engaged?())
  end

  defp assign_report(socket), do: assign(socket, :report, ActivityReport.summary())

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

  def handle_event("start_unattended_shift", _params, socket) do
    case Orchestration.start_shift(unattended: true, job_key: "dispatcher") do
      {:ok, _shift} ->
        {:noreply,
         socket
         |> put_flash(:info, "Unattended shift started — the Dispatcher will work the queue.")
         |> assign_shift()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not start the shift.")}
    end
  end

  def handle_event("stop_shift", _params, socket) do
    Orchestration.stop_shift("stopped from home")
    {:noreply, socket |> put_flash(:info, "Shift stopped.") |> assign_shift()}
  end

  def handle_event("engage_kill_switch", _params, socket) do
    Orchestration.engage_kill_switch()

    {:noreply,
     socket
     |> put_flash(:info, "Kill switch engaged — the active shift will halt.")
     |> assign_shift()}
  end

  def handle_event("clear_kill_switch", _params, socket) do
    Orchestration.clear_kill_switch()
    {:noreply, assign_shift(socket)}
  end

  @impl true
  def handle_info({:orchestration, _event}, socket),
    do: {:noreply, socket |> assign_shift() |> assign_report()}

  def handle_info({:dispatch, _event, _item}, socket), do: {:noreply, assign_report(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="ic-home relative isolate flex flex-1 flex-col">
        <div class="ic-home-bg" aria-hidden="true"></div>
        <div class="relative z-10 flex min-h-0 flex-1 flex-col space-y-8">
          <div class="space-y-4 border-b-2 border-base-content/20 pb-5">
            <div
              id="bc-heading"
              phx-hook="CrtAberration"
              class="ic-scanlines block w-full max-w-[28rem]"
            >
              <img
                src={~p"/images/brand/buster-claw-heading.png"}
                alt="Buster Claw"
                class="block h-auto w-full"
              />
              <img
                src={~p"/images/brand/buster-claw-heading.png"}
                alt=""
                aria-hidden="true"
                class="ic-crt-focus h-auto w-full"
              />
            </div>
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
              <.shift_panel shift={@shift} kill_switch={@kill_switch} />
              <.this_week_panel report={@report} />
              <.featured_pages_panel />
              <BusterClawWeb.TrustedContactsPanel.panel entries={@trusted_contacts} />
            </div>

            <.daily_calendar_panel today={@today} events={@daily_events} />
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp get_started_panel(assigns) do
    ~H"""
    <details
      id="home-get-started"
      open
      class="ic-panel group flex min-h-0 flex-col overflow-hidden open:min-h-64 open:flex-1"
    >
      <summary class="flex cursor-pointer list-none items-start justify-between gap-3 border-base-content/20 px-5 py-4 transition group-open:border-b-2 hover:text-primary">
        <div class="min-w-0">
          <p class="ic-eyebrow">Get Started</p>
          <h2 class="font-display text-2xl font-black uppercase tracking-tight">
            Get Started
          </h2>
          <p class="mt-1 text-sm text-base-content/65">
            Three steps to put Buster Claw on email duty (Google Workspace already connected).
          </p>
        </div>
        <.icon
          name="hero-chevron-right"
          class="mt-1 size-5 shrink-0 transition group-open:rotate-90"
        />
      </summary>

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
              Open the
              <.link
                navigate={~p"/terminal"}
                class="font-semibold text-primary hover:underline"
              >
                Terminal
              </.link>
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
    </details>
    """
  end

  attr :shift, :any, required: true
  attr :kill_switch, :boolean, required: true

  defp shift_panel(assigns) do
    ~H"""
    <section id="home-shift" class="ic-panel">
      <header class="border-b-2 border-base-content/20 px-5 py-4">
        <p class="ic-eyebrow">Unattended Shift</p>
        <h2 class="font-display text-2xl font-black uppercase tracking-tight">
          Unattended Shift
        </h2>
        <p class="mt-1 text-sm text-base-content/65">
          Let Buster Claw work the queue with headless agent runs — no terminal to babysit.
        </p>
      </header>

      <div class="flex flex-col gap-4 p-5">
        <%= if @shift do %>
          <div class="flex items-center gap-2">
            <span class={[
              "inline-block size-2.5 shrink-0 rounded-full",
              if(@shift.unattended, do: "bg-primary", else: "bg-base-content/40")
            ]}>
            </span>
            <span class="font-mono text-sm">
              {if @shift.unattended, do: "Unattended", else: "Attended"} shift · {@shift.job_name}
            </span>
          </div>

          <dl class="grid grid-cols-3 gap-2">
            <.shift_stat label="Runs" value={@shift.dispatched_count} />
            <.shift_stat label="Done" value={@shift.done_count} />
            <.shift_stat label="Failed" value={@shift.failed_count} />
          </dl>

          <button
            type="button"
            phx-click="stop_shift"
            class="inline-flex items-center justify-center gap-2 rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold uppercase tracking-wide transition hover:border-primary hover:text-primary"
          >
            <.icon name="hero-stop" class="size-4" /> Stop shift
          </button>
        <% else %>
          <p class="text-sm text-base-content/60">No shift running.</p>
          <button
            type="button"
            phx-click="start_unattended_shift"
            class="inline-flex items-center justify-center gap-2 rounded bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"
          >
            <.icon name="hero-bolt" class="size-4" /> Start unattended shift
          </button>
        <% end %>

        <div class="flex items-center justify-between gap-3 border-t-2 border-base-content/15 pt-3">
          <div class="min-w-0">
            <p class="ic-eyebrow">Kill switch</p>
            <p class={[
              "font-mono text-sm",
              @kill_switch && "text-primary"
            ]}>
              {if @kill_switch, do: "ENGAGED", else: "clear"}
            </p>
          </div>
          <button
            :if={not @kill_switch}
            type="button"
            phx-click="engage_kill_switch"
            class="rounded-sm border-2 border-base-content/30 px-3 py-1.5 text-xs font-semibold uppercase tracking-wide transition hover:border-primary hover:text-primary"
          >
            Engage
          </button>
          <button
            :if={@kill_switch}
            type="button"
            phx-click="clear_kill_switch"
            class="rounded-sm border-2 border-primary px-3 py-1.5 text-xs font-semibold uppercase tracking-wide text-primary transition hover:opacity-85"
          >
            Clear
          </button>
        </div>
      </div>
    </section>
    """
  end

  attr :report, :map, required: true

  defp this_week_panel(assigns) do
    ~H"""
    <section id="home-activity" class="ic-panel">
      <header class="border-b-2 border-base-content/20 px-5 py-4">
        <p class="ic-eyebrow">Last {@report.days} Days</p>
        <h2 class="font-display text-2xl font-black uppercase tracking-tight">
          This Week
        </h2>
        <p class="mt-1 text-sm text-base-content/65">
          What Buster Claw handled for you.
        </p>
      </header>

      <div class="p-5">
        <dl class="grid grid-cols-4 gap-2">
          <.shift_stat label="Handled" value={@report.handled} />
          <.shift_stat label="Open" value={@report.open} />
          <.shift_stat label="Blocked" value={@report.blocked} />
          <.shift_stat label="Runs" value={@report.runs} />
        </dl>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp shift_stat(assigns) do
    ~H"""
    <div class="rounded-sm border-2 border-base-content/20 px-2 py-2 text-center">
      <p class="font-display text-2xl font-black tabular-nums leading-none">{@value}</p>
      <p class="mt-1 text-[0.62rem] font-semibold uppercase tracking-wide text-base-content/55">
        {@label}
      </p>
    </div>
    """
  end

  defp featured_pages_panel(assigns) do
    ~H"""
    <section id="home-featured-pages" class="ic-panel">
      <header class="border-b-2 border-base-content/20 px-5 py-4">
        <p class="ic-eyebrow">Featured Pages</p>
        <h2 class="font-display text-2xl font-black uppercase tracking-tight">
          Featured Pages
        </h2>
      </header>

      <div class="flex flex-col gap-3 p-5">
        <.featured_page_link
          href={~p"/browse?#{[url: "/pages/MANUAL.html"]}"}
          icon="hero-book-open"
          title="Manual"
          blurb="Open the Buster Claw manual in the browser"
        />
        <.featured_page_link
          href={~p"/browse?#{[url: "/pages/financial-informant.html"]}"}
          icon="hero-chart-bar"
          title="Financial Informant"
          blurb="Look up a ticker — quote, fundamentals, filings, news"
        />
      </div>
    </section>
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :blurb, :string, required: true

  defp featured_page_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="group flex items-center gap-3 rounded-sm border-2 border-base-content/25 px-3 py-2.5 transition hover:border-primary hover:text-primary"
    >
      <.icon name={@icon} class="size-5 shrink-0 text-base-content/60" />
      <span class="min-w-0">
        <span class="block font-semibold">{@title}</span>
        <span class="block text-xs text-base-content/60">{@blurb}</span>
      </span>
      <.icon name="hero-chevron-right" class="ml-auto size-4 shrink-0 text-base-content/40" />
    </.link>
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
    <section id="home-daily-calendar" class="ic-panel self-start">
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
