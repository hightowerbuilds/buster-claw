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
    <div class="grid grid-cols-7 border-b border-base-content/15 text-center font-mono text-[0.625rem] font-bold uppercase tracking-wide text-base-content/45">
      <div :for={label <- @weekday_labels} class="px-2 py-2">{label}</div>
    </div>

    <div class="grid grid-cols-7 border-l border-t border-base-content/10">
      <.day_cell
        :for={day <- @grid_days}
        day={day}
        today={@today}
        target={@target}
        dim_other_month={true}
        min_height="min-h-28"
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
    <div class="grid grid-cols-7 border-b border-base-content/15 text-center font-mono text-[0.625rem] font-bold uppercase tracking-wide text-base-content/45">
      <div :for={{label, day} <- Enum.zip(@weekday_labels, @grid_days)} class="px-2 py-2">
        <div>{label}</div>
        <div class="mt-1 font-mono text-sm text-base-content/80">{day.date.day}</div>
      </div>
    </div>

    <div class="grid grid-cols-7 border-l border-t border-base-content/10">
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
    <div class="border-b border-base-content/15 px-4 py-3 text-sm">
      <span class="font-semibold">{Elixir.Calendar.strftime(@day.date, "%A")}</span>
      <span class="ml-2 text-base-content/60">
        {Elixir.Calendar.strftime(@day.date, "%B %-d, %Y")}
      </span>
    </div>
    <div class="p-4">
      <ul :if={@day.events != []} class="space-y-2">
        <li
          :for={event <- @day.events}
          phx-click="inspect"
          phx-value-id={event.id}
          phx-target={@target}
          class={[
            "flex cursor-pointer items-baseline gap-3 rounded-xs px-3 py-2 text-sm",
            CalendarColors.chip(event.color)
          ]}
        >
          <span :if={event.start_time} class="w-16 font-mono text-xs opacity-75">
            {format_time(event.start_time)}<span :if={event.end_time}>–{format_time(event.end_time)}</span>
          </span>
          <span :if={!event.start_time} class="w-16 font-mono text-xs opacity-75">All day</span>
          <span class="truncate font-semibold">{event.title}</span>
          <span
            :if={event.frequency}
            class="ml-auto rounded-xs bg-base-100/60 px-2 py-0.5 font-mono text-[0.625rem] uppercase tracking-wide text-base-content/70"
          >
            {event.frequency}
          </span>
        </li>
      </ul>
      <p :if={@day.events == []} class="text-center text-sm text-base-content/60">
        Nothing on the schedule.
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
        "relative flex flex-col items-stretch border-b border-r border-base-content/10 p-2 text-left text-xs transition hover:bg-base-content/5",
        @min_height,
        cell_treatment(@day, @today, @dim_other_month)
      ]}
    >
      <span class={[
        "relative z-[2] self-end font-mono font-semibold",
        @day.date == @today && "rounded-xs bg-primary px-1.5 py-0.5 text-primary-content",
        (@dim_other_month and not @day.in_month?) && @day.date != @today && "text-base-content/40"
      ]}>
        {@day.date.day}
      </span>

      <ul class="relative z-[2] mt-1 flex flex-col gap-1">
        <li
          :for={event <- @day.events}
          phx-click="inspect"
          phx-value-id={event.id}
          phx-target={@target}
          draggable="true"
          data-event-id={event.id}
          class={[
            "flex cursor-grab items-baseline gap-1 truncate rounded-xs px-1.5 py-0.5 font-mono text-[0.625rem] active:cursor-grabbing",
            CalendarColors.chip(event.color)
          ]}
          title={event.title}
        >
          <span :if={event.start_time} class="opacity-75">
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
        <div class="pointer-events-auto w-full max-w-xl border-2 border-base-content/30 bg-base-100 shadow-2xl">
          <header class="ic-scanlines relative flex items-center justify-between border-b-2 border-base-content/20 px-5 py-3">
            <div class="relative z-[2]">
              <p class="ic-eyebrow">Calendar</p>
              <h3 class="font-display text-lg font-black uppercase tracking-tight">
                {if @editing_event, do: "Edit Event", else: "Add Event"}
              </h3>
            </div>
            <button
              type="button"
              phx-click="close_form"
              phx-target={@myself}
              aria-label="Close event form"
              class="relative z-[2] grid size-8 place-items-center border-2 border-base-content/30 text-lg leading-none transition hover:border-primary hover:text-primary"
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
            class="grid gap-3 p-5 sm:grid-cols-2"
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
              <button class="rounded-xs bg-primary px-4 py-2 font-display text-sm font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85">
                {if @editing_event, do: "Update", else: "Add"}
              </button>
              <button
                type="button"
                class="rounded-xs border-2 border-base-content/20 px-4 py-2 font-mono text-sm transition hover:border-base-content/40"
                phx-click="close_form"
                phx-target={@myself}
              >
                Cancel
              </button>
              <button
                :if={@editing_event}
                type="button"
                class="rounded-xs border-2 border-error/40 px-4 py-2 font-mono text-sm text-error transition hover:border-error"
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

  # Treatment for a month/week day cell: today is a primary wash; a day with
  # events gets a faint wash of its first event's color (chips sit on top); empty
  # cells carry the scanline texture (chrome), dimmed when out of month.
  defp cell_treatment(day, today, dim) do
    cond do
      day.date == today -> "bg-primary/10"
      day.events != [] -> CalendarColors.cell_wash(hd(day.events).color)
      dim and not day.in_month? -> "ic-scanlines bg-base-200/20"
      true -> "ic-scanlines"
    end
  end
end
