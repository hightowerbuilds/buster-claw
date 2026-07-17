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
  attr :contacts, :list, required: true
  attr :entries, :list, required: true
  attr :today, Date, required: true
  attr :days, :list, required: true
  attr :weather, :any, required: true
  attr :weather_form, :boolean, required: true
  attr :notifications, :list, required: true
  attr :notify_form, :any, required: true

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
            {"place", "Time & Place"},
            {"notify", "Notify"}
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
            <BusterClawWeb.TrustedContactsPanel.panel contacts={@contacts} entries={@entries} />
          </div>
          <div class={["h-full", @tab != "place" && "hidden"]}>
            <.place_panel weather={@weather} form={@weather_form} />
          </div>
          <div class={["h-full", @tab != "notify" && "hidden"]}>
            <.notify_panel notifications={@notifications} form={@notify_form} />
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

  # Notify: a quick timer form over the list of upcoming notifications. The list
  # shows every armed kind (timers, alarms, reminders — however they were set);
  # the form makes the common case (a countdown timer) a two-field action.
  # `select_widget_tab`, `notify_create`, `notify_snooze`, and `notify_dismiss`
  # are handled by StatusLive. The relative "fires in" label re-renders on every
  # change; the live per-second countdown arrives with the digit shader (Phase 2).
  attr :notifications, :list, required: true
  attr :form, :any, required: true

  defp notify_panel(assigns) do
    ~H"""
    <section class="ic-panel flex h-full flex-col">
      {if @notifications != [], do: notify_hero(%{soonest: hd(@notifications)})}

      <.form
        for={@form}
        id="notify-form"
        phx-submit="notify_create"
        class="flex shrink-0 flex-col gap-1.5 border-b border-base-content/15 px-3 py-3"
      >
        <label class="font-mono text-[0.625rem] font-bold uppercase tracking-widest text-base-content/55">
          New timer
        </label>
        <input
          type="text"
          name="notify[label]"
          value={@form[:label].value}
          required
          placeholder="Label, e.g. Tea"
          autocomplete="off"
          class="min-w-0 border-2 border-base-content/25 bg-base-100 px-2 py-1 font-mono text-xs"
        />
        <div class="flex gap-1.5">
          <input
            type="number"
            name="notify[minutes]"
            value={@form[:minutes].value}
            min="1"
            required
            placeholder="min"
            class="min-w-0 flex-1 border-2 border-base-content/25 bg-base-100 px-2 py-1 font-mono text-xs"
          />
          <button
            type="submit"
            class="shrink-0 border-2 border-primary px-2 py-1 font-display text-[0.625rem] font-bold uppercase tracking-wide text-primary transition hover:bg-primary hover:text-primary-content"
          >
            Set
          </button>
        </div>
        <p :if={@form.errors != []} class="font-mono text-[0.625rem] text-primary">
          {form_error_text(@form)}
        </p>
      </.form>

      <ul class="min-h-0 flex-1 divide-y divide-base-content/10 overflow-auto">
        <li
          :for={notification <- @notifications}
          class="flex items-center justify-between gap-2 px-3 py-2"
        >
          <div class="min-w-0">
            <div class="truncate font-mono text-xs text-base-content">{notification.label}</div>
            <div class="font-mono text-[0.625rem] uppercase tracking-wide text-base-content/55">
              {kind_label(notification.kind)} · {fires_in_label(notification.fire_at)}
            </div>
          </div>
          <div class="flex shrink-0 gap-1">
            <button
              type="button"
              phx-click="notify_snooze"
              phx-value-id={notification.id}
              class="border border-base-content/25 px-1.5 py-0.5 font-mono text-[0.625rem] uppercase text-base-content/70 transition hover:border-base-content"
            >
              Snooze
            </button>
            <button
              type="button"
              phx-click="notify_dismiss"
              phx-value-id={notification.id}
              class="border border-error/40 px-1.5 py-0.5 font-mono text-[0.625rem] uppercase text-error transition hover:border-error"
            >
              Dismiss
            </button>
          </div>
        </li>
        <li
          :if={@notifications == []}
          class="px-3 py-8 text-center font-mono text-[0.625rem] uppercase tracking-widest text-base-content/45"
        >
          No timers or alarms set
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  The fired-notification modal: a big seven-segment `00:00` (the ShaderTimer,
  fed a past `fire_at`, clamps to zero) over the label, with Snooze / Dismiss.
  Rendered by StatusLive from the head of its fired queue; the events
  (`notify_ack`, `notify_ack_snooze`) are handled there.
  """
  attr :notification, :map, required: true

  def notify_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-[120] grid place-items-center bg-black/60 p-4"
      role="alertdialog"
      aria-modal="true"
    >
      <div class="ic-panel w-full max-w-sm border-2 border-base-content bg-base-100 p-5 text-base-content shadow-lg">
        <div class="font-display text-xs font-bold uppercase tracking-widest text-primary">
          {kind_label(@notification.kind)} · time's up
        </div>
        <div class="relative mt-3 h-20 w-full overflow-hidden border border-base-content/20 bg-base-100">
          <div
            id={"notify-modal-#{@notification.id}"}
            phx-hook="ShaderTimer"
            phx-update="ignore"
            data-fire-at={DateTime.to_unix(@notification.fire_at)}
            class="absolute inset-0"
          >
            <canvas data-timer-canvas class="absolute inset-0 h-full w-full"></canvas>
            <div
              data-timer-text
              class="pointer-events-none absolute inset-0 grid place-items-center font-mono text-4xl font-bold tabular-nums tracking-widest text-base-content"
            >
              00:00
            </div>
          </div>
        </div>
        <p class="mt-3 truncate text-center font-mono text-sm">{@notification.label}</p>
        <div class="mt-5 flex justify-end gap-2">
          <button
            type="button"
            phx-click="notify_ack_snooze"
            phx-value-id={@notification.id}
            class="border-2 border-base-content px-3 py-1 font-display text-xs font-bold uppercase tracking-wide transition hover:bg-base-200"
          >
            Snooze 5m
          </button>
          <button
            type="button"
            phx-click="notify_ack"
            phx-value-id={@notification.id}
            class="border-2 border-primary bg-primary px-3 py-1 font-display text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-90"
          >
            Dismiss
          </button>
        </div>
      </div>
    </div>
    """
  end

  # The soonest upcoming notification as a big seven-segment countdown. The shader
  # (ShaderTimer hook) owns the live tick from `data-fire-at`; the text node is the
  # placeholder before boot and the fallback when WebGPU is unavailable. The id
  # carries fire-at, so when the soonest changes the element is replaced and the
  # hook remounts on the new target.
  attr :soonest, :map, required: true

  defp notify_hero(assigns) do
    ~H"""
    <div class="shrink-0 border-b border-base-content/15 px-3 py-3">
      <div
        id={"notify-countdown-#{@soonest.id}-#{DateTime.to_unix(@soonest.fire_at)}"}
        phx-hook="ShaderTimer"
        phx-update="ignore"
        data-fire-at={DateTime.to_unix(@soonest.fire_at)}
        class="relative h-16 w-full overflow-hidden border border-base-content/20 bg-base-100"
      >
        <canvas data-timer-canvas class="absolute inset-0 h-full w-full"></canvas>
        <div
          data-timer-text
          class="pointer-events-none absolute inset-0 grid place-items-center font-mono text-3xl font-bold tabular-nums tracking-widest text-base-content"
        >
          --:--
        </div>
      </div>
      <div class="mt-1 truncate text-center font-mono text-[0.625rem] uppercase tracking-widest text-base-content/60">
        {kind_label(@soonest.kind)} · {@soonest.label}
      </div>
    </div>
    """
  end

  defp kind_label("timer"), do: "Timer"
  defp kind_label("alarm"), do: "Alarm"
  defp kind_label("reminder"), do: "Reminder"
  defp kind_label(other), do: other

  # A coarse, timezone-free "fires in" label. Placeholder for the live shader
  # countdown; re-computed each render, so it tracks reloads/changes, not seconds.
  defp fires_in_label(fire_at) do
    seconds = DateTime.diff(fire_at, DateTime.utc_now())

    cond do
      seconds <= 0 -> "now"
      seconds < 60 -> "in #{seconds}s"
      seconds < 3600 -> "in #{div(seconds, 60)}m"
      seconds < 86_400 -> "in #{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"
      true -> "in #{div(seconds, 86_400)}d"
    end
  end

  defp form_error_text(form) do
    Enum.map_join(form.errors, "; ", fn {_field, {message, _opts}} -> message end)
  end

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
