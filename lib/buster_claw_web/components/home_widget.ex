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
          <div class={["h-full", @tab != "calendar" && "hidden"]}>
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

  # Vertical channel (px) left below each region so the track separator line
  # stays visible between stacked tracks.
  @lane_gap_px 4

  attr :today, Date, required: true
  attr :events, :list, required: true

  defp daily_calendar_panel(assigns) do
    {all_day, timed} = Enum.split_with(assigns.events, &(&1.start_time == nil))
    assigns = assign(assigns, timeline: build_timeline(timed), all_day: all_day)

    ~H"""
    <section id="home-daily-calendar" class="ic-panel flex h-full flex-col">
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

      <div class="flex min-h-0 flex-1 flex-col gap-3 p-5">
        <%!-- All-day events: full-width rectangle bars above the hour grid. Like
              the timed regions, the label is revealed only on hover. --%>
        <div :if={@all_day != []} class="flex shrink-0 flex-col gap-1">
          <div
            :for={event <- @all_day}
            id={"home-allday-#{event.id}-#{Date.to_iso8601(event.date)}"}
            class={["ic-daygrid-bar flex items-center px-1.5 py-1.5", event_color_class(event.color)]}
            title={"All day · #{event.title}"}
          >
            <span class="truncate font-mono text-[0.625rem] font-bold uppercase leading-none tracking-wide">
              {event.title}
            </span>
          </div>
        </div>

        <%!-- The day as a Pro Tools–style timeline. Fluid: hour columns split the
              full width, tracks split the full remaining height. --%>
        <div :if={@timeline != :empty} class="flex min-h-0 flex-1 select-none flex-col">
          <div class="ic-daygrid-ruler flex shrink-0">
            <div
              :for={hour <- @timeline.hours}
              class="ic-ruler-cell flex-1 pl-1.5 pt-px font-mono text-[0.625rem] font-semibold uppercase leading-none tracking-wide text-base-content/70"
            >
              {hour_label(hour)}
            </div>
          </div>

          <div
            class="ic-daygrid relative min-h-0 flex-1"
            style={"--hour-w: #{@timeline.hour_w}%; --lane-h: #{@timeline.lane_h}%"}
          >
            <div
              :for={block <- @timeline.blocks}
              id={"home-block-#{block.event.id}-#{Date.to_iso8601(block.event.date)}"}
              class={["ic-daygrid-block", event_color_class(block.event.color)]}
              style={block_style(block, @timeline.lane_count)}
              title={"#{block_time_label(block.event)} · #{block.event.title}"}
            >
              <p class="ic-daygrid-head truncate px-1.5 py-0.5 font-mono text-[0.625rem] font-bold uppercase leading-none tracking-wide">
                {block.event.title}
              </p>
              <p class="truncate px-1.5 pt-0.5 font-mono text-[0.625rem] leading-none tracking-wide text-base-content/70">
                {block_time_label(block.event)}
              </p>
            </div>
          </div>
        </div>

        <div
          :if={@timeline == :empty and @all_day == []}
          class="flex flex-1 items-center justify-center rounded border border-dashed border-base-300 px-4 text-center text-sm text-base-content/60"
        >
          Nothing scheduled today.
        </div>
      </div>
    </section>
    """
  end

  # Lay timed events out on the hour grid: clamp the visible window to the span
  # that actually holds events, assign overlapping events to stacked tracks, and
  # express geometry as fractions of the (fluid) grid so it fills the card both
  # axes. Returns `:empty` when nothing is timed. `hour_w`/`lane_h` are the
  # column/row sizes as percentages, fed to the CSS ruling via custom props.
  defp build_timeline([]), do: :empty

  defp build_timeline(events) do
    items = Enum.map(events, &with_minutes/1)

    start_min = items |> Enum.map(& &1.start_min) |> Enum.min() |> floor_hour()
    end_min = items |> Enum.map(& &1.end_min) |> Enum.max() |> ceil_hour()
    span = end_min - start_min

    {blocks, lane_count} = assign_lanes(items)
    first_hour = div(start_min, 60)
    last_hour = div(end_min, 60) - 1
    hours = Enum.to_list(first_hour..last_hour)

    blocks =
      Enum.map(blocks, fn item ->
        Map.merge(item, %{
          left_pct: pct((item.start_min - start_min) / span * 100),
          width_pct: pct((item.end_min - item.start_min) / span * 100)
        })
      end)

    %{
      blocks: blocks,
      hours: hours,
      lane_count: lane_count,
      hour_w: pct(100 / length(hours)),
      lane_h: pct(100 / lane_count)
    }
  end

  # Annotate an event with start/end minutes-from-midnight. A missing end_time
  # defaults to a one-hour block; enforce a 15-minute floor so zero/short spans
  # still render.
  defp with_minutes(event) do
    start_min = minutes(event.start_time)
    end_min = if event.end_time, do: minutes(event.end_time), else: start_min + 60
    %{event: event, start_min: start_min, end_min: max(end_min, start_min + 15)}
  end

  # Greedy interval partition: place each event in the first lane whose previous
  # block has already ended, else open a new lane. Returns {blocks, lane_count}.
  defp assign_lanes(items) do
    items
    |> Enum.sort_by(& &1.start_min)
    |> Enum.reduce({[], []}, fn item, {placed, lane_ends} ->
      case Enum.find_index(lane_ends, &(&1 <= item.start_min)) do
        nil ->
          {[Map.put(item, :lane, length(lane_ends)) | placed], lane_ends ++ [item.end_min]}

        idx ->
          {[Map.put(item, :lane, idx) | placed], List.replace_at(lane_ends, idx, item.end_min)}
      end
    end)
    |> then(fn {placed, lane_ends} -> {Enum.reverse(placed), max(length(lane_ends), 1)} end)
  end

  # Geometry as fractions of the fluid grid: x/width track the event's span,
  # the track row splits the height evenly (less a channel for the separator).
  defp block_style(block, lane_count) do
    top = pct(block.lane / lane_count * 100)

    "left: #{block.left_pct}%; width: #{block.width_pct}%; top: #{top}%; " <>
      "height: calc(100% / #{lane_count} - #{@lane_gap_px}px)"
  end

  defp minutes(%Time{hour: hour, minute: minute}), do: hour * 60 + minute
  defp floor_hour(min), do: div(min, 60) * 60
  defp ceil_hour(min), do: div(min + 59, 60) * 60

  # Round a percentage to 2 decimals for compact, stable inline styles.
  defp pct(value), do: Float.round(value / 1, 2)

  defp hour_label(hour) do
    suffix = if hour < 12, do: "a", else: "p"

    h12 =
      case rem(hour, 12) do
        0 -> 12
        other -> other
      end

    "#{h12}#{suffix}"
  end

  defp block_time_label(%{start_time: start_time, end_time: nil}),
    do: format_event_time(start_time)

  defp block_time_label(%{start_time: start_time, end_time: end_time}),
    do: "#{format_event_time(start_time)}–#{format_event_time(end_time)}"

  defp format_event_time(%Time{} = time), do: Elixir.Calendar.strftime(time, "%H:%M")

  # Sets `color` for a region/bar: the border + label take the hue at full
  # strength while the translucent fill is derived from the same `currentColor`.
  defp event_color_class(color) do
    case color do
      "work" -> "text-info"
      "personal" -> "text-secondary"
      "social" -> "text-accent"
      "travel" -> "text-warning"
      "health" -> "text-success"
      "holiday" -> "text-error"
      _ -> "text-primary"
    end
  end
end
