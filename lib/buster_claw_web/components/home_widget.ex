defmodule BusterClawWeb.HomeWidget do
  @moduledoc """
  Home header corner widget: the Calendar / Contacts card that fills the header
  gap to the right of the banner. (The Get Started guide moved to a Settings
  sub-tab, `BusterClawWeb.GetStartedLive`.)

  Presentation only — the `select_widget_tab`, `add_contact`, and `remove_contact`
  events are handled by the parent LiveView (`StatusLive`).
  """
  use BusterClawWeb, :html

  attr :tab, :string, required: true
  attr :entries, :list, required: true
  attr :today, Date, required: true
  attr :events, :list, required: true

  # Calendar + Contacts as a rectangle filling the header gap to the right of the
  # banner. The card is absolutely positioned to fill the widget box, so its
  # content scrolls instead of growing the header. When the CornerWidget hook
  # finds the header too narrow to fit the widget beside the banner it collapses
  # the widget to a right-edge bumper that pops the card back out on click.
  def corner_widget(assigns) do
    ~H"""
    <div
      id="home-corner-widget"
      phx-hook="CornerWidget"
      data-banner="#bc-heading"
      class="ic-corner-widget relative min-w-0"
    >
      <button
        type="button"
        data-corner-bumper
        aria-label="Show Calendar and Contacts"
        class="ic-corner-bumper"
      >
        <.icon name="hero-chevron-left" class="size-4" />
      </button>

      <div
        data-corner-card
        class="ic-corner-card ic-panel flex flex-col overflow-hidden"
      >
        <div
          role="tablist"
          aria-label="Widget"
          class="flex gap-1 border-b-2 border-base-content/20 px-2 pt-2"
        >
          <%= for {key, text} <- [
            {"calendar", "Calendar"},
            {"contacts", "Contacts"}
          ] do %>
            <button
              type="button"
              role="tab"
              aria-selected={to_string(@tab == key)}
              phx-click="select_widget_tab"
              phx-value-tab={key}
              class={[
                "-mb-0.5 border-b-2 px-3 py-1.5 font-display text-xs font-bold uppercase tracking-wide transition",
                if(@tab == key,
                  do: "border-primary text-primary",
                  else: "border-transparent text-base-content/55 hover:text-base-content"
                )
              ]}
            >
              {text}
            </button>
          <% end %>
        </div>

        <div class="min-h-0 flex-1 overflow-auto">
          <div class={@tab != "calendar" && "hidden"}>
            <.daily_calendar_panel today={@today} events={@events} />
          </div>
          <div class={@tab != "contacts" && "hidden"}>
            <BusterClawWeb.TrustedContactsPanel.panel entries={@entries} />
          </div>
        </div>
      </div>
    </div>
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
end
