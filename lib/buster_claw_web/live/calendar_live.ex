defmodule BusterClawWeb.CalendarLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Calendar
  alias BusterClaw.Calendar.Event
  alias BusterClaw.LocalTime
  alias BusterClawWeb.CalendarColors

  @weekday_labels ~w(Sun Mon Tue Wed Thu Fri Sat)

  @color_options [
    {"Neutral", "neutral"},
    {"Work", "work"},
    {"Personal", "personal"},
    {"Social", "social"},
    {"Travel", "travel"},
    {"Health", "health"},
    {"Holiday", "holiday"}
  ]

  @frequency_options [
    {"Does not repeat", ""},
    {"Daily", "daily"},
    {"Weekly", "weekly"},
    {"Monthly", "monthly"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    today = LocalTime.today()

    {:ok,
     socket
     |> assign(:page_title, "Calendar")
     |> assign(:editing_event, nil)
     |> assign(:viewing_event, nil)
     |> assign(:result, nil)
     |> assign(:today, today)
     |> assign(:view, :month)
     |> assign(:anchor, today)
     |> assign(:weekday_labels, @weekday_labels)
     |> assign(:color_options, @color_options)
     |> assign(:frequency_options, @frequency_options)
     |> assign_form(Event.changeset(%Event{}, default_attrs(today)))
     |> rebuild_view()}
  end

  @impl true
  def handle_event("validate", %{"event" => params}, socket) do
    event = socket.assigns.editing_event || %Event{}

    changeset =
      event
      |> Event.changeset(normalize_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"event" => params}, socket) do
    params = normalize_params(params)

    result =
      case socket.assigns.editing_event do
        nil -> Calendar.create_event(ensure_event_id(params))
        event -> Calendar.update_event(event, params)
      end

    case result do
      {:ok, _event} ->
        {:noreply,
         socket
         |> assign(:editing_event, nil)
         |> assign(:viewing_event, nil)
         |> assign(:result, "Event saved.")
         |> assign_form(Event.changeset(%Event{}, default_attrs(socket.assigns.today)))
         |> rebuild_view()}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("inspect", %{"id" => id}, socket) do
    case safe_get_event(id) do
      nil -> {:noreply, socket}
      event -> {:noreply, assign(socket, viewing_event: event, result: nil)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case safe_get_event(id) do
      nil ->
        {:noreply, socket}

      event ->
        {:noreply,
         socket
         |> assign(:editing_event, event)
         |> assign(:viewing_event, nil)
         |> assign(:result, nil)
         |> assign_form(Event.changeset(event, %{}))}
    end
  end

  def handle_event("close_inspect", _params, socket) do
    {:noreply, assign(socket, :viewing_event, nil)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_event, nil)
     |> assign(:result, nil)
     |> assign_form(Event.changeset(%Event{}, default_attrs(socket.assigns.today)))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case safe_get_event(id) do
      nil ->
        {:noreply, socket}

      event ->
        {:ok, _event} = Calendar.delete_event(event)

        {:noreply,
         socket
         |> assign(:editing_event, nil)
         |> assign(:viewing_event, nil)
         |> assign(:result, "Event deleted.")
         |> assign_form(Event.changeset(%Event{}, default_attrs(socket.assigns.today)))
         |> rebuild_view()}
    end
  end

  def handle_event("set_view", %{"view" => view}, socket) when view in ~w(month week day) do
    {:noreply,
     socket
     |> assign(:view, view_atom(view))
     |> rebuild_view()}
  end

  def handle_event("prev", _params, socket) do
    {:noreply,
     socket
     |> assign(:anchor, shift_anchor(socket.assigns.view, socket.assigns.anchor, -1))
     |> rebuild_view()}
  end

  def handle_event("next", _params, socket) do
    {:noreply,
     socket
     |> assign(:anchor, shift_anchor(socket.assigns.view, socket.assigns.anchor, 1))
     |> rebuild_view()}
  end

  def handle_event("today", _params, socket) do
    {:noreply,
     socket
     |> assign(:anchor, socket.assigns.today)
     |> rebuild_view()}
  end

  def handle_event("select_date", %{"date" => date_str}, socket) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        changeset =
          Event.changeset(%Event{}, %{
            date: date,
            color: "neutral",
            event_id: Ecto.UUID.generate()
          })

        {:noreply,
         socket
         |> assign(:editing_event, nil)
         |> assign(:viewing_event, nil)
         |> assign(:result, nil)
         |> assign_form(changeset)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("move_event", %{"id" => id, "date" => date_str}, socket) do
    with {:ok, new_date} <- Date.from_iso8601(date_str),
         event when not is_nil(event) <- safe_get_event(id),
         true <- new_date != event.date,
         {:ok, _} <- Calendar.update_event(event, %{date: new_date}) do
      {:noreply,
       socket
       |> assign(
         :result,
         "Moved \"#{event.title}\" to #{Elixir.Calendar.strftime(new_date, "%b %-d, %Y")}."
       )
       |> rebuild_view()}
    else
      _ -> {:noreply, socket}
    end
  end

  defp safe_get_event(id) do
    Calendar.get_event!(id)
  rescue
    Ecto.NoResultsError -> nil
    Ecto.Query.CastError -> nil
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} wide>
      <section class="space-y-6">
        <p :if={@result} class="ic-panel px-4 py-3 text-sm">
          {@result}
        </p>

        <section
          id="calendar-grid"
          phx-hook="CalendarDrag"
          class="ic-panel overflow-hidden"
        >
          <header class="ic-scanlines relative flex flex-wrap items-center justify-between gap-3 border-b-2 border-base-content/20 px-4 py-3">
            <div class="relative z-[2]">
              <p class="ic-eyebrow">Calendar</p>
              <h2 class="font-display text-xl font-black uppercase tracking-tight">
                {header_label(@view, @anchor)}
              </h2>
            </div>
            <div class="relative z-[2] flex gap-2">
              <div class="flex gap-0.5 border-2 border-base-content/20 p-0.5">
                <button
                  :for={view <- [:month, :week, :day]}
                  type="button"
                  phx-click="set_view"
                  phx-value-view={Atom.to_string(view)}
                  class={[
                    "rounded-xs px-3 py-1 font-mono text-xs font-bold uppercase tracking-wide transition",
                    if(@view == view,
                      do: "bg-primary text-primary-content",
                      else: "text-base-content/60 hover:bg-base-content/10"
                    )
                  ]}
                >
                  {view}
                </button>
              </div>
              <div class="flex gap-1">
                <button
                  type="button"
                  class="border-2 border-base-content/20 px-3 py-1.5 font-mono text-sm transition hover:border-primary hover:text-primary"
                  phx-click="prev"
                >
                  ←
                </button>
                <button
                  type="button"
                  class="border-2 border-base-content/20 px-3 py-1.5 font-mono text-xs font-bold uppercase tracking-wide transition hover:border-primary hover:text-primary"
                  phx-click="today"
                >
                  Today
                </button>
                <button
                  type="button"
                  class="border-2 border-base-content/20 px-3 py-1.5 font-mono text-sm transition hover:border-primary hover:text-primary"
                  phx-click="next"
                >
                  →
                </button>
              </div>
            </div>
          </header>

          <.month_view
            :if={@view == :month}
            grid_days={@grid_days}
            weekday_labels={@weekday_labels}
            today={@today}
          />
          <.week_view
            :if={@view == :week}
            grid_days={@grid_days}
            weekday_labels={@weekday_labels}
            today={@today}
          />
          <.day_view :if={@view == :day} day={hd(@grid_days)} today={@today} />
        </section>

        <div
          :if={@viewing_event}
          class="ic-panel p-5"
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="min-w-0 space-y-1">
              <div class="flex items-center gap-2">
                <span class={[
                  "inline-block size-3 rounded-xs",
                  CalendarColors.swatch(@viewing_event.color)
                ]} />
                <h3 class="text-lg font-semibold">{@viewing_event.title}</h3>
                <span
                  :if={@viewing_event.frequency}
                  class="rounded-full bg-base-200 px-2 py-0.5 text-xs font-semibold text-base-content/70"
                >
                  Repeats {@viewing_event.frequency}
                </span>
              </div>
              <p class="text-sm text-base-content/70">
                {format_event_when(@viewing_event)}
              </p>
              <p
                :if={@viewing_event.notes && @viewing_event.notes != ""}
                class="mt-2 whitespace-pre-wrap text-sm"
              >
                {@viewing_event.notes}
              </p>
            </div>
            <div class="flex gap-2">
              <button
                type="button"
                class="rounded-xs border-2 border-base-content/20 px-3 py-1.5 font-mono text-sm transition hover:border-primary hover:text-primary"
                phx-click="edit"
                phx-value-id={@viewing_event.id}
              >
                Edit
              </button>
              <button
                type="button"
                class="rounded-xs border-2 border-error/40 px-3 py-1.5 font-mono text-sm text-error transition hover:border-error"
                phx-click="delete"
                phx-value-id={@viewing_event.id}
                data-claw-confirm={"Delete \"#{@viewing_event.title}\"?"}
              >
                Delete
              </button>
              <button
                type="button"
                class="rounded-xs px-3 py-1.5 font-mono text-sm text-base-content/60 transition hover:bg-base-content/10"
                phx-click="close_inspect"
              >
                Close
              </button>
            </div>
          </div>
        </div>

        <.form
          for={@form}
          id="event-form"
          phx-change="validate"
          phx-submit="save"
          class="ic-panel grid gap-3 p-5 sm:grid-cols-2 lg:grid-cols-[1.2fr_2fr_1fr_1fr_1fr_auto] lg:items-end"
        >
          <.input field={@form[:date]} label="Date" type="date" />
          <.input field={@form[:title]} label="Title" />
          <.input field={@form[:start_time]} label="Start" type="time" />
          <.input field={@form[:end_time]} label="End" type="time" />
          <.input field={@form[:color]} label="Color" type="select" options={@color_options} />
          <div class="flex flex-wrap gap-2">
            <button class="rounded-xs bg-primary px-4 py-2 font-display text-sm font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85">
              {if @editing_event, do: "Update", else: "Add"}
            </button>
            <button
              :if={@editing_event}
              type="button"
              class="rounded-xs border-2 border-base-content/20 px-4 py-2 font-mono text-sm transition hover:border-base-content/40"
              phx-click="cancel"
            >
              Cancel
            </button>
            <button
              :if={@editing_event}
              type="button"
              class="rounded-xs border-2 border-error/40 px-4 py-2 font-mono text-sm text-error transition hover:border-error"
              phx-click="delete"
              phx-value-id={@editing_event.id}
              data-claw-confirm={"Delete \"#{@editing_event.title}\"?"}
            >
              Delete
            </button>
          </div>
          <.input
            field={@form[:frequency]}
            label="Repeat"
            type="select"
            options={@frequency_options}
          />
          <.input field={@form[:recur_until]} label="Repeat until" type="date" />
          <div class="lg:col-span-4">
            <.input field={@form[:notes]} label="Notes" type="textarea" />
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  # ---- View components ----

  attr :grid_days, :list, required: true
  attr :weekday_labels, :list, required: true
  attr :today, Date, required: true

  defp month_view(assigns) do
    ~H"""
    <div class="grid grid-cols-7 border-b border-base-content/15 text-center font-mono text-[0.625rem] font-bold uppercase tracking-wide text-base-content/45">
      <div :for={label <- @weekday_labels} class="px-2 py-2">{label}</div>
    </div>

    <div class="grid grid-cols-7 border-l border-t border-base-content/10">
      <.day_cell
        :for={day <- @grid_days}
        day={day}
        today={@today}
        dim_other_month={true}
        min_height="min-h-28"
      />
    </div>
    """
  end

  attr :grid_days, :list, required: true
  attr :weekday_labels, :list, required: true
  attr :today, Date, required: true

  defp week_view(assigns) do
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
        dim_other_month={false}
        min_height="min-h-64"
      />
    </div>
    """
  end

  attr :day, :map, required: true
  attr :today, Date, required: true

  defp day_view(assigns) do
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
  attr :dim_other_month, :boolean, required: true
  attr :min_height, :string, default: "min-h-28"

  defp day_cell(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_date"
      phx-value-date={Date.to_iso8601(@day.date)}
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

  # ---- View rebuild + range helpers ----

  defp rebuild_view(socket) do
    {range_start, range_end} = view_range(socket.assigns.view, socket.assigns.anchor)
    events = Calendar.events_in_range(range_start, range_end)

    grid_days =
      build_grid_days(socket.assigns.view, socket.assigns.anchor, events, range_start, range_end)

    assign(socket, :grid_days, grid_days)
  end

  defp view_range(:month, anchor) do
    first = Date.beginning_of_month(anchor)
    grid_start = Date.add(first, -(Date.day_of_week(first, :sunday) - 1))
    grid_end = Date.add(grid_start, 41)
    {grid_start, grid_end}
  end

  defp view_range(:week, anchor) do
    start = Date.add(anchor, -(Date.day_of_week(anchor, :sunday) - 1))
    {start, Date.add(start, 6)}
  end

  defp view_range(:day, anchor), do: {anchor, anchor}

  defp build_grid_days(:month, anchor, events, range_start, range_end) do
    month = anchor.month
    by_date = group_by_date(events)

    Enum.map(0..Date.diff(range_end, range_start), fn offset ->
      date = Date.add(range_start, offset)

      %{
        date: date,
        in_month?: date.month == month,
        events: Map.get(by_date, date, [])
      }
    end)
  end

  defp build_grid_days(:week, _anchor, events, range_start, range_end) do
    by_date = group_by_date(events)

    Enum.map(0..Date.diff(range_end, range_start), fn offset ->
      date = Date.add(range_start, offset)
      %{date: date, in_month?: true, events: Map.get(by_date, date, [])}
    end)
  end

  defp build_grid_days(:day, _anchor, events, range_start, _range_end) do
    by_date = group_by_date(events)
    [%{date: range_start, in_month?: true, events: Map.get(by_date, range_start, [])}]
  end

  defp group_by_date(events) do
    events
    |> Enum.group_by(& &1.date)
    |> Map.new(fn {date, items} -> {date, Enum.sort_by(items, &sort_key/1)} end)
  end

  defp sort_key(%Event{start_time: nil}), do: {0, ~T[00:00:00]}
  defp sort_key(%Event{start_time: time}), do: {1, time}

  # ---- Header / labels ----

  defp header_label(:month, anchor), do: Elixir.Calendar.strftime(anchor, "%B %Y")

  defp header_label(:week, anchor) do
    start = Date.add(anchor, -(Date.day_of_week(anchor, :sunday) - 1))
    finish = Date.add(start, 6)

    "#{Elixir.Calendar.strftime(start, "%b %-d")} – #{Elixir.Calendar.strftime(finish, "%b %-d, %Y")}"
  end

  defp header_label(:day, anchor),
    do: Elixir.Calendar.strftime(anchor, "%A, %B %-d, %Y")

  # Param-derived input must never mint atoms (the atom table is not GC'd), so
  # the view name maps through explicit clauses instead of String.to_atom/1.
  defp view_atom("month"), do: :month
  defp view_atom("week"), do: :week
  defp view_atom("day"), do: :day

  # ---- Anchor shifts ----

  defp shift_anchor(:month, anchor, delta), do: shift_month(anchor, delta)
  defp shift_anchor(:week, anchor, delta), do: Date.add(anchor, 7 * delta)
  defp shift_anchor(:day, anchor, delta), do: Date.add(anchor, delta)

  defp shift_month(date, delta) do
    months = date.year * 12 + date.month - 1 + delta
    year = div(months, 12)
    month = rem(months, 12) + 1
    day = min(date.day, Date.days_in_month(Date.new!(year, month, 1)))
    Date.new!(year, month, day)
  end

  # ---- Formatting / colors ----

  defp format_time(%Time{} = time), do: Elixir.Calendar.strftime(time, "%H:%M")
  defp format_time(_), do: ""

  defp format_event_when(%Event{} = event) do
    parts = [Elixir.Calendar.strftime(event.date, "%a, %b %-d, %Y")]

    parts =
      cond do
        event.start_time && event.end_time ->
          parts ++ ["#{format_time(event.start_time)}–#{format_time(event.end_time)}"]

        event.start_time ->
          parts ++ [format_time(event.start_time)]

        true ->
          parts ++ ["All day"]
      end

    Enum.join(parts, " · ")
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

  # ---- Form helpers ----

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  defp default_attrs(today),
    do: %{date: today, event_id: Ecto.UUID.generate(), color: "neutral"}

  defp normalize_params(params) do
    params
    |> Map.update("date", nil, &parse_date/1)
    |> Map.update("recur_until", nil, &parse_date/1)
    |> Map.update("start_time", nil, &parse_time/1)
    |> Map.update("end_time", nil, &parse_time/1)
    |> Map.update("frequency", nil, &blank_to_nil/1)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp ensure_event_id(params) do
    case Map.get(params, "event_id") || Map.get(params, :event_id) do
      value when value in [nil, ""] -> Map.put(params, "event_id", Ecto.UUID.generate())
      _value -> params
    end
  end

  defp parse_date(%Date{} = date), do: date
  defp parse_date(""), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> value
    end
  end

  defp parse_date(value), do: value

  defp parse_time(%Time{} = time), do: time
  defp parse_time(""), do: nil
  defp parse_time(nil), do: nil

  defp parse_time(value) when is_binary(value) do
    case Time.from_iso8601(value <> ":00") do
      {:ok, time} ->
        time

      _ ->
        case Time.from_iso8601(value) do
          {:ok, time} -> time
          _ -> value
        end
    end
  end

  defp parse_time(value), do: value

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
