defmodule BusterClawWeb.HomeWidget do
  @moduledoc """
  Home header corner widget: the Calendar / Contacts card that fills the header
  gap to the right of the banner. (The Get Started guide moved to a Settings
  sub-tab, `BusterClawWeb.GetStartedLive`.)

  Presentation only — the `select_widget_tab`, `add_contact`, and `remove_contact`
  events are handled by the parent LiveView (`StatusLive`).
  """
  use BusterClawWeb, :html

  alias BusterClawWeb.CalendarColors

  attr :tab, :string, required: true
  attr :entries, :list, required: true
  attr :today, Date, required: true
  attr :days, :list, required: true

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
        class="ic-corner-card ic-panel ic-scanlines flex flex-col overflow-hidden"
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
          <div class={["h-full", @tab != "calendar" && "hidden"]}>
            <.month_calendar today={@today} days={@days} />
          </div>
          <div class={["h-full", @tab != "contacts" && "hidden"]}>
            <BusterClawWeb.TrustedContactsPanel.panel entries={@entries} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :today, Date, required: true
  attr :days, :list, required: true

  # The current month as a Sunday-aligned grid that fills the card both axes.
  # Today is highlighted; days with events carry a dot and a hidden detail block
  # the CalendarPopover hook reveals as a floating popover on hover.
  defp month_calendar(assigns) do
    ~H"""
    <section class="ic-panel flex h-full flex-col">
      <div class="grid shrink-0 grid-cols-7 gap-1.5 border-b border-base-content/15 px-3 pb-2 pt-3">
        <div
          :for={label <- ~w(Sun Mon Tue Wed Thu Fri Sat)}
          class="text-center font-mono text-[0.625rem] font-bold uppercase tracking-wide text-base-content/45"
        >
          {String.first(label)}
        </div>
      </div>

      <div
        id="home-month-grid"
        phx-hook="CalendarPopover"
        class="grid min-h-0 flex-1 grid-cols-7 grid-rows-6 gap-1.5 px-3 py-3"
      >
        <div
          :for={day <- @days}
          data-day
          data-has-events={day.events != [] && "1"}
          class={[
            "relative flex items-center justify-center rounded-xs font-mono text-xs transition",
            day_cell_class(day, @today)
          ]}
        >
          {day.date.day}

          <div :if={day.events != []} data-day-detail hidden>
            <p class="mb-1 font-mono text-[0.625rem] font-bold uppercase tracking-wide text-base-content/60">
              {Elixir.Calendar.strftime(day.date, "%a · %b %-d")}
            </p>
            <ul class="space-y-0.5">
              <li
                :for={event <- day.events}
                class={[
                  "flex items-baseline gap-1.5 font-mono text-[0.6875rem]",
                  CalendarColors.text(event.color)
                ]}
              >
                <span class="shrink-0 text-current">{event_time_label(event)}</span>
                <span class="truncate text-base-content">{event.title}</span>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # Today wins (solid primary fill); then days with events take a translucent
  # fill of the first event's category color so the whole cell reads as "busy" at
  # a glance (the hover popover lists them). Out-of-month empty days are dimmed.
  defp day_cell_class(day, today) do
    cond do
      day.date == today -> "bg-primary font-bold text-primary-content"
      day.events != [] -> CalendarColors.cell_fill(hd(day.events).color) <> " text-base-content"
      not day.in_month? -> "text-base-content/35 hover:bg-base-content/5"
      true -> "text-base-content hover:bg-base-content/5"
    end
  end

  defp event_time_label(%{start_time: nil}), do: "All day"

  defp event_time_label(%{start_time: %Time{} = time}),
    do: Elixir.Calendar.strftime(time, "%H:%M")
end
