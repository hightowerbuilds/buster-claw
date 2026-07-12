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
  attr :weather, :any, required: true
  attr :weather_form, :boolean, required: true

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
            {"contacts", "Contacts"},
            {"place", "Time & Place"}
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
          <div class={["h-full", @tab != "place" && "hidden"]}>
            <.place_panel weather={@weather} form={@weather_form} />
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

  # Time & Place: the daycycle shader (sun/moon arc, clouds, wind, birds by
  # day, stars by night — driven by the machine's local clock via u.lens.x)
  # fills the panel; the analog clock and current conditions float above it in
  # glass. The card's ic-scanlines overlay stays on top of everything.
  attr :weather, :any, required: true
  attr :form, :boolean, required: true

  defp place_panel(assigns) do
    ~H"""
    <section class="relative h-full overflow-hidden">
      <div
        id="place-daycycle"
        phx-hook="SmokeBackground"
        phx-update="ignore"
        data-shader="daycycle"
        data-daylight="true"
        class="ic-shader-fill"
        aria-hidden="true"
      >
        <canvas data-smoke-canvas></canvas>
      </div>

      <%!-- Clock and conditions side by side, transparent so the sky reads through. --%>
      <div class="relative z-10 flex h-full gap-2 p-3">
        <%!-- The clock: hook-owned motion, frozen markup. --%>
        <div
          id="home-clock"
          phx-hook="Clock"
          phx-update="ignore"
          class="flex min-h-0 min-w-0 flex-1 flex-col items-center justify-center gap-1 p-1"
        >
          <svg
            viewBox="0 0 200 200"
            class="min-h-0 w-full max-w-36 flex-1"
            role="img"
            aria-label="Analog clock"
          >
            <circle
              cx="100"
              cy="100"
              r="96"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              class="text-base-content/25"
            />
            <%= for tick <- 0..59 do %>
              <line
                x1="100"
                y1={if rem(tick, 5) == 0, do: "12", else: "8"}
                x2="100"
                y2={if rem(tick, 5) == 0, do: "22", else: "14"}
                stroke="currentColor"
                stroke-width={if rem(tick, 5) == 0, do: "3", else: "1"}
                class={if rem(tick, 5) == 0, do: "text-base-content/70", else: "text-base-content/30"}
                transform={"rotate(#{tick * 6} 100 100)"}
              />
            <% end %>
            <g data-hand="hour">
              <line
                x1="100"
                y1="100"
                x2="100"
                y2="52"
                stroke="currentColor"
                stroke-width="5"
                stroke-linecap="round"
                class="text-base-content"
              />
            </g>
            <g data-hand="minute">
              <line
                x1="100"
                y1="100"
                x2="100"
                y2="32"
                stroke="currentColor"
                stroke-width="3"
                stroke-linecap="round"
                class="text-base-content/80"
              />
            </g>
            <g data-hand="second">
              <line
                x1="100"
                y1="112"
                x2="100"
                y2="26"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                class="text-primary"
              />
            </g>
            <circle cx="100" cy="100" r="4" class="fill-primary" />
          </svg>
          <div class="text-center">
            <div data-clock-digital class="font-mono text-lg font-bold tabular-nums tracking-wide">
              --:--:--
            </div>
            <div
              data-clock-date
              class="font-mono text-[0.625rem] uppercase tracking-widest text-base-content/55"
            >
              &nbsp;
            </div>
          </div>
        </div>

        <%!-- The place: current conditions, or the location form. --%>
        <div class="flex min-h-0 min-w-0 flex-1 flex-col justify-center p-1">
          <form :if={@form} phx-submit="set_weather_location" class="flex flex-col gap-1.5">
            <label class="font-mono text-[0.625rem] font-bold uppercase tracking-widest text-base-content/55">
              Where are you?
            </label>
            <div class="flex gap-1.5">
              <input
                type="text"
                name="query"
                required
                placeholder="City, e.g. Portland"
                autocomplete="off"
                class="min-w-0 flex-1 border-2 border-base-content/25 bg-base-100 px-2 py-1 font-mono text-xs"
              />
              <button
                type="submit"
                class="shrink-0 border-2 border-primary px-2 py-1 font-display text-[0.625rem] font-bold uppercase tracking-wide text-primary transition hover:bg-primary hover:text-primary-content"
              >
                Set
              </button>
            </div>
            <p :if={@weather == {:error, :not_found}} class="font-mono text-[0.625rem] text-primary">
              No place by that name — try adding a state or country.
            </p>
          </form>

          <div
            :if={!@form and @weather == :loading}
            class="py-1 text-center font-mono text-[0.625rem] uppercase tracking-widest text-base-content/50"
          >
            Checking the sky…
          </div>

          <div
            :if={!@form and match?({:error, _}, @weather)}
            class="flex items-center justify-between py-1"
          >
            <span class="font-mono text-[0.625rem] uppercase tracking-widest text-base-content/55">
              Weather unavailable
            </span>
            <button
              type="button"
              phx-click="edit_weather_location"
              class="font-mono text-[0.625rem] uppercase tracking-wide text-primary underline underline-offset-2"
            >
              Set location
            </button>
          </div>

          <div :if={!@form and is_map(@weather)} class="flex flex-col items-center gap-1 text-center">
            <span class="max-w-full truncate font-display text-[0.625rem] font-bold uppercase tracking-widest text-base-content/70">
              {@weather.location}
            </span>
            <span class="font-display text-4xl font-black tabular-nums leading-none">
              {@weather.temp_f}°
            </span>
            <span class="font-mono text-xs text-base-content/80">{@weather.label}</span>
            <div class="font-mono text-[0.625rem] tabular-nums text-base-content/70">
              <div>{@weather.high_f}° / {@weather.low_f}° · feels {@weather.feels_like_f}°</div>
              <div>{@weather.wind_mph} mph · {@weather.humidity}%</div>
            </div>
            <button
              type="button"
              phx-click="edit_weather_location"
              aria-label="Change location"
              class="font-mono text-[0.625rem] uppercase tracking-wide text-base-content/45 transition hover:text-primary"
            >
              Change
            </button>
          </div>
        </div>
      </div>
    </section>
    """
  end
end
