defmodule BusterClawWeb.Calendar.Views do
  @moduledoc """
  The calendar's markup: the three grid views, the day cell they share, and the
  event form modal.

  Pure function components over what `BusterClawWeb.CalendarComponent` already
  decided. Nothing here loads an event, shifts an anchor or holds a form — the
  component hands over finished `grid_days` and a finished `@form`, and this
  turns them into a grid.

  ## Why these are plain function components and not nested live_components

  The calendar is hosted behind `:if` on the Home tab, and a `:if` that goes
  false does not hide a `live_component` — it DISCARDS it, along with every
  assign it was holding. A nested live_component here would therefore lose the
  operator's view, anchor and half-typed form on every tab switch, silently, in
  a way no test that stays on one tab would ever notice. Function components
  hold nothing, so there is nothing to lose: all state lives in the one
  component, and all fourteen `handle_event` clauses stay there with it.

  ## Threading `phx-target`

  Every binding names its target explicitly rather than leaning on an ancestor's
  `phx-target`. An ancestor is enough in the browser (`closest/1` finds it), but
  `LiveViewTest` resolves the target per element, so a chip inside a cell inside
  a grid has to carry it. That is what the `target`/`myself` attrs are for — they
  are the owning LiveComponent's `@myself`, passed down.
  """
  use BusterClawWeb, :html

  import BusterClaw.Calendar.Grid, only: [format_time: 1]

  alias BusterClawWeb.CalendarColors

  attr :grid_days, :list, required: true
  attr :weekday_labels, :list, required: true
  attr :today, Date, required: true
  attr :target, :any, required: true

  @doc "The six-week month grid, out-of-month days dimmed."
  def month_view(assigns) do
    ~H"""
    <div class="grid grid-cols-7 text-right font-mono text-[0.5625rem] font-semibold uppercase tracking-[0.12em] text-base-content/40">
      <div :for={label <- @weekday_labels} class="px-1.5 py-1">{label}</div>
    </div>

    <div class="grid flex-1 auto-rows-fr grid-cols-7 border-t border-base-content/10">
      <.day_cell
        :for={day <- @grid_days}
        day={day}
        today={@today}
        target={@target}
        dim_other_month={true}
        min_height="min-h-20"
      />
    </div>
    """
  end

  attr :grid_days, :list, required: true
  attr :weekday_labels, :list, required: true
  attr :today, Date, required: true
  attr :target, :any, required: true

  @doc "Seven taller cells, each headed with its own date."
  def week_view(assigns) do
    ~H"""
    <div class="grid grid-cols-7 text-right font-mono text-[0.5625rem] font-semibold uppercase tracking-[0.12em] text-base-content/40">
      <div :for={label <- @weekday_labels} class="px-1.5 py-1">{label}</div>
    </div>

    <div class="grid flex-1 grid-cols-7 border-t border-base-content/10">
      <.day_cell
        :for={day <- @grid_days}
        day={day}
        today={@today}
        target={@target}
        dim_other_month={false}
        min_height="min-h-64"
      />
    </div>
    """
  end

  attr :day, :map, required: true
  attr :target, :any, required: true

  @doc """
  One day as a list rather than a cell.

  Takes no `today`: the single day on screen is already named in full in its own
  header, so there is nothing here for a "today" treatment to distinguish.
  """
  def day_view(assigns) do
    ~H"""
    <div class="py-1.5 font-mono text-xs">
      <span class="font-semibold">{Elixir.Calendar.strftime(@day.date, "%A")}</span>
      <span class="ml-2 text-base-content/50">
        {Elixir.Calendar.strftime(@day.date, "%B %-d, %Y")}
      </span>
    </div>
    <div class="border-t border-base-content/10 py-2 font-mono">
      <ul :if={@day.events != []} class="space-y-1">
        <li
          :for={event <- @day.events}
          phx-click="inspect"
          phx-value-id={event.id}
          phx-target={@target}
          class={[
            "flex cursor-pointer items-baseline gap-3 border-l-2 px-2 py-0.5 text-xs transition hover:bg-base-content/5",
            CalendarColors.bar(event.color)
          ]}
        >
          <span :if={event.start_time} class="w-24 shrink-0 text-base-content/50">
            {format_time(event.start_time)}<span :if={event.end_time}>–{format_time(event.end_time)}</span>
          </span>
          <span :if={!event.start_time} class="w-24 shrink-0 text-base-content/50">all day</span>
          <span class="truncate">{event.title}</span>
          <span
            :if={event.frequency}
            class="ml-auto text-[0.625rem] uppercase tracking-[0.08em] text-base-content/45"
          >
            {event.frequency}
          </span>
        </li>
      </ul>
      <p :if={@day.events == []} class="px-2 text-xs text-base-content/45">
        <span class="text-primary">&gt;</span> Nothing on the schedule.
      </p>
    </div>
    """
  end

  attr :day, :map, required: true
  attr :today, Date, required: true
  attr :target, :any, required: true
  attr :dim_other_month, :boolean, required: true
  attr :min_height, :string, default: "min-h-28"

  @doc "A single grid cell: the date, its chips, and the drop target for a drag."
  def day_cell(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_date"
      phx-value-date={Date.to_iso8601(@day.date)}
      phx-target={@target}
      data-drop-date={Date.to_iso8601(@day.date)}
      class={[
        "relative flex flex-col items-stretch border-b border-r border-base-content/10 p-1 text-left font-mono text-xs transition last:border-r-0 hover:bg-base-content/5 [&:nth-child(7n)]:border-r-0",
        @min_height,
        cell_treatment(@day, @today)
      ]}
    >
      <span class={[
        "self-end px-0.5 text-[0.6875rem]",
        cond do
          @day.date == @today -> "border-b border-primary font-semibold text-primary"
          @dim_other_month and not @day.in_month? -> "text-base-content/30"
          true -> "text-base-content/60"
        end
      ]}>
        {@day.date.day}
      </span>

      <ul class="mt-0.5 flex flex-col gap-0.5">
        <li
          :for={event <- @day.events}
          phx-click="inspect"
          phx-value-id={event.id}
          phx-target={@target}
          draggable="true"
          data-event-id={event.id}
          class={[
            "flex cursor-grab items-baseline gap-1 truncate border-l-2 pl-1 text-[0.625rem] text-base-content/80 transition hover:text-base-content active:cursor-grabbing",
            CalendarColors.bar(event.color)
          ]}
          title={event.title}
        >
          <span :if={event.start_time} class="text-base-content/45">
            {format_time(event.start_time)}
          </span>
          <span class="truncate">{event.title}</span>
        </li>
      </ul>
    </button>
    """
  end

  attr :form_open, :boolean, required: true
  attr :form, :any, required: true
  attr :editing_event, :any, required: true
  attr :color_options, :list, required: true
  attr :frequency_options, :list, required: true

  attr :myself, :any,
    required: true,
    doc: "the owning LiveComponent's @myself — every binding in here targets it"

  @doc "Add/Edit Event, in a modal. Renders nothing unless `form_open`."
  def event_form_modal(assigns) do
    ~H"""
    <%!-- The event form, in a modal (was pinned to the bottom of the tab).
          Same idiom as the chat SVG viewer: backdrop button closes, the
          panel sits above it, Escape closes via phx-window-keydown. The
          form itself is unchanged — Repeat + Repeat until is what makes an
          event recurring, so one simple form covers single and recurring. --%>
    <div
      :if={@form_open}
      class="fixed inset-0 z-50"
      phx-window-keydown="close_form"
      phx-key="escape"
      phx-target={@myself}
    >
      <button
        type="button"
        phx-click="close_form"
        phx-target={@myself}
        aria-label="Close event form"
        class="absolute inset-0 h-full w-full bg-black/70 backdrop-blur-sm"
      >
      </button>
      <div class="pointer-events-none absolute inset-0 grid place-items-center overflow-y-auto p-4">
        <div class="pointer-events-auto w-full max-w-xl border border-base-content/30 bg-base-100 font-mono shadow-2xl">
          <header class="flex items-center justify-between border-b border-base-content/15 px-4 py-2">
            <h3 class="text-sm">
              <span class="font-mono font-semibold tracking-normal">
                {if @editing_event, do: "Edit event", else: "Add event"}
              </span>
            </h3>
            <button
              type="button"
              phx-click="close_form"
              phx-target={@myself}
              aria-label="Close event form"
              class="px-1.5 text-base text-base-content/50 transition hover:text-primary"
            >
              ×
            </button>
          </header>

          <.form
            for={@form}
            id="event-form"
            phx-change="validate"
            phx-submit="save"
            phx-target={@myself}
            class="grid gap-3 p-4 sm:grid-cols-2"
          >
            <div class="sm:col-span-2">
              <.input field={@form[:title]} label="Title" />
            </div>
            <.input field={@form[:date]} label="Date" type="date" />
            <.input field={@form[:color]} label="Color" type="select" options={@color_options} />
            <.input field={@form[:start_time]} label="Start" type="time" />
            <.input field={@form[:end_time]} label="End" type="time" />
            <.input
              field={@form[:frequency]}
              label="Repeat"
              type="select"
              options={@frequency_options}
            />
            <.input field={@form[:recur_until]} label="Repeat until" type="date" />
            <div class="sm:col-span-2">
              <.input field={@form[:notes]} label="Notes" type="textarea" />
            </div>
            <div class="flex flex-wrap gap-2 sm:col-span-2">
              <button class="border border-primary px-3 py-1 text-[0.6875rem] font-semibold uppercase tracking-[0.08em] text-primary transition hover:bg-primary hover:text-primary-content">
                {if @editing_event, do: "Update", else: "Add"}
              </button>
              <button
                type="button"
                class="border border-base-content/25 px-3 py-1 text-[0.6875rem] font-semibold uppercase tracking-[0.08em] text-base-content/70 transition hover:border-primary hover:text-primary"
                phx-click="close_form"
                phx-target={@myself}
              >
                Cancel
              </button>
              <button
                :if={@editing_event}
                type="button"
                class="border border-error/50 px-3 py-1 text-[0.6875rem] font-semibold uppercase tracking-[0.08em] text-error transition hover:bg-error/10"
                phx-click="delete"
                phx-value-id={@editing_event.id}
                phx-target={@myself}
                data-claw-confirm={"Delete \"#{@editing_event.title}\"?"}
              >
                Delete
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  # Treatment for a month/week day cell. Minimal (10-17): no scanlines and no
  # per-event washes — the events' own left bars carry the colour, and today is
  # its underlined date over the faintest primary tint.
  defp cell_treatment(day, today) do
    if day.date == today, do: "bg-primary/5", else: nil
  end
end
