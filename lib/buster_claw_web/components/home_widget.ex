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
            {"clock", "Clock"},
            {"weather", "Weather"}
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
          <div class={["h-full", @tab != "clock" && "hidden"]}>
            <.clock_panel />
          </div>
          <div class={["h-full", @tab != "weather" && "hidden"]}>
            <.weather_panel weather={@weather} form={@weather_form} />
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

  # An analog dial the Clock hook drives client-side (per-second updates never
  # cross the LiveView socket). The SVG face is server-rendered once and frozen
  # with phx-update="ignore"; the hook rotates the hand groups and fills the
  # digital readout from the machine's own clock.
  defp clock_panel(assigns) do
    ~H"""
    <section
      id="home-clock"
      phx-hook="Clock"
      phx-update="ignore"
      class="flex h-full flex-col items-center justify-center gap-3 p-4"
    >
      <svg
        viewBox="0 0 200 200"
        class="max-h-full w-full max-w-56 min-h-0 flex-1"
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

      <div class="shrink-0 text-center">
        <div data-clock-digital class="font-mono text-2xl font-bold tabular-nums tracking-wide">
          --:--:--
        </div>
        <div data-clock-date class="font-mono text-xs uppercase tracking-widest text-base-content/55">
          &nbsp;
        </div>
      </div>
    </section>
    """
  end

  attr :weather, :any, required: true
  attr :form, :boolean, required: true

  # Current conditions from BusterClaw.Weather (Open-Meteo, keyless). The parent
  # owns the events: `set_weather_location` (form submit) and
  # `edit_weather_location` (the change affordance).
  defp weather_panel(assigns) do
    ~H"""
    <section class="flex h-full flex-col p-4">
      <form
        :if={@form}
        phx-submit="set_weather_location"
        class="m-auto flex w-full max-w-64 flex-col gap-2"
      >
        <label class="font-mono text-[0.625rem] font-bold uppercase tracking-widest text-base-content/55">
          Where are you?
        </label>
        <input
          type="text"
          name="query"
          required
          placeholder="City, e.g. Portland"
          autocomplete="off"
          class="border-2 border-base-content/25 bg-base-100 px-2 py-1.5 font-mono text-sm"
        />
        <button
          type="submit"
          class="border-2 border-primary px-3 py-1.5 font-display text-xs font-bold uppercase tracking-wide text-primary transition hover:bg-primary hover:text-primary-content"
        >
          Set location
        </button>
        <p :if={@weather == {:error, :not_found}} class="font-mono text-xs text-primary">
          No place by that name — try adding a state or country.
        </p>
      </form>

      <div
        :if={!@form and @weather == :loading}
        class="m-auto font-mono text-xs uppercase tracking-widest text-base-content/50"
      >
        Checking the sky…
      </div>

      <div
        :if={!@form and match?({:error, _}, @weather)}
        class="m-auto flex flex-col items-center gap-2"
      >
        <p class="font-mono text-xs uppercase tracking-widest text-base-content/55">
          Weather unavailable
        </p>
        <button
          type="button"
          phx-click="edit_weather_location"
          class="font-mono text-xs uppercase tracking-wide text-primary underline underline-offset-4"
        >
          Set location
        </button>
      </div>

      <div :if={!@form and is_map(@weather)} class="flex h-full flex-col">
        <div class="flex items-baseline justify-between gap-2">
          <span class="truncate font-display text-xs font-bold uppercase tracking-widest text-base-content/60">
            {@weather.location}
          </span>
          <button
            type="button"
            phx-click="edit_weather_location"
            aria-label="Change location"
            class="shrink-0 font-mono text-[0.625rem] uppercase tracking-wide text-base-content/45 transition hover:text-primary"
          >
            Change
          </button>
        </div>

        <div class="flex min-h-0 flex-1 flex-col items-center justify-center gap-1">
          <div class="font-display text-6xl font-black tabular-nums leading-none">
            {@weather.temp_f}°
          </div>
          <div class="font-mono text-sm text-base-content/75">{@weather.label}</div>
          <div class="font-mono text-xs text-base-content/55">
            feels like {@weather.feels_like_f}°
          </div>
        </div>

        <div class="grid shrink-0 grid-cols-3 gap-1 border-t border-base-content/15 pt-2 text-center">
          <div>
            <div class="font-mono text-[0.625rem] uppercase tracking-widest text-base-content/45">
              Hi/Lo
            </div>
            <div class="font-mono text-sm tabular-nums">{@weather.high_f}°/{@weather.low_f}°</div>
          </div>
          <div>
            <div class="font-mono text-[0.625rem] uppercase tracking-widest text-base-content/45">
              Wind
            </div>
            <div class="font-mono text-sm tabular-nums">{@weather.wind_mph} mph</div>
          </div>
          <div>
            <div class="font-mono text-[0.625rem] uppercase tracking-widest text-base-content/45">
              Humidity
            </div>
            <div class="font-mono text-sm tabular-nums">{@weather.humidity}%</div>
          </div>
        </div>
      </div>
    </section>
    """
  end
end
