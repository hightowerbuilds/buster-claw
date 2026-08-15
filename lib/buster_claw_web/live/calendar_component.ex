defmodule BusterClawWeb.CalendarComponent do
  @moduledoc """
  The full month/week/day calendar with event CRUD, as an embeddable
  `Phoenix.LiveComponent`.

  It renders inline (no layout of its own), so a host page provides the chrome.
  Two hosts use it today: `BusterClawWeb.CalendarLive` (the `/calendar` route and
  the split-pane view) and `BusterClawWeb.StatusLive` (the homepage "Calendar"
  sub-tab). Keeping the behavior in one component means both surfaces stay in
  sync.

  ## Event routing

  Every interactive element carries `phx-target={@myself}` so its event reaches
  this component rather than the host LiveView; the view sub-components take a
  `target` attr and thread the same value onto their own bindings. (An ancestor
  `phx-target` is enough in the browser via `closest/1`, but `LiveViewTest`
  resolves per element, so the bindings are explicit.) The `CalendarDrag` JS hook
  lives on `#calendar-grid`, which also sets `phx-target`, so a drag-drop
  `move_event` pushed with `pushEventTo(this.el, ...)` lands here too.

  ## Assigns

  The host passes `today`; everything else (view, anchor, form, the loaded grid)
  is owned here. Initialization runs once (guarded by `:loaded`) so a host's
  unrelated re-renders — the homepage streams chat, ticks the sky — never reset
  the operator's calendar navigation.

  ## What lives elsewhere

  The markup is `BusterClawWeb.Calendar.Views` and the date arithmetic is
  `BusterClaw.Calendar.Grid`. Both are `import`ed rather than aliased, so the
  call sites here read exactly as they did when both were private to this file.

  Neither is a nested `live_component`, and cannot become one: a host renders
  this behind `:if`, which DISCARDS a live_component's assigns rather than
  hiding them, so any state pushed down into a child would vanish on a tab
  switch. All state, and all fourteen `handle_event` clauses, stay here.
  """
  use BusterClawWeb, :live_component

  import BusterClaw.Calendar.Grid
  import BusterClawWeb.Calendar.Views

  alias BusterClaw.Calendar
  alias BusterClaw.Calendar.Event
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
  def mount(socket) do
    {:ok,
     socket
     |> assign(:editing_event, nil)
     |> assign(:viewing_event, nil)
     |> assign(:result, nil)
     |> assign(:form_open, false)
     |> assign(:view, :month)
     |> assign(:weekday_labels, @weekday_labels)
     |> assign(:color_options, @color_options)
     |> assign(:frequency_options, @frequency_options)
     |> assign(:loaded, false)}
  end

  # The host re-renders us on its own schedule (chat streaming, sky ticks). Merge
  # `today`, but run the one-time init — anchor/form/grid — only once, so those
  # re-renders don't snap the calendar back to today's month.
  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :today, assigns.today)

    socket =
      if socket.assigns.loaded do
        socket
      else
        socket
        |> assign(:anchor, assigns.today)
        |> assign_form(Event.changeset(%Event{}, default_attrs(assigns.today)))
        |> assign(:loaded, true)
        |> rebuild_view()
      end

    {:ok, socket}
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
         |> assign(:form_open, false)
         |> assign(:result, "Event saved.")
         |> assign_form(Event.changeset(%Event{}, default_attrs(socket.assigns.today)))
         |> rebuild_view()}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  # The Add Events button: a fresh form in the modal, anchored to today.
  def handle_event("open_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_event, nil)
     |> assign(:viewing_event, nil)
     |> assign(:result, nil)
     |> assign(:form_open, true)
     |> assign_form(Event.changeset(%Event{}, default_attrs(socket.assigns.today)))}
  end

  # Backdrop, ×, Cancel, and Escape all land here. Closing also abandons an
  # in-progress edit — the form resets so a later open starts clean.
  def handle_event("close_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_event, nil)
     |> assign(:form_open, false)
     |> assign_form(Event.changeset(%Event{}, default_attrs(socket.assigns.today)))}
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
         |> assign(:form_open, true)
         |> assign_form(Event.changeset(event, %{}))}
    end
  end

  def handle_event("close_inspect", _params, socket) do
    {:noreply, assign(socket, :viewing_event, nil)}
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
         |> assign(:form_open, false)
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

  # Clicking a day cell is the "add something on this date" gesture: the modal
  # opens with that date already filled in.
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
         |> assign(:form_open, true)
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
    <div>
      <section class="space-y-6">
        <p :if={@result} class="ic-panel px-4 py-3 text-sm">
          {@result}
        </p>

        <section
          id="calendar-grid"
          phx-hook="CalendarDrag"
          phx-target={@myself}
          class="ic-panel overflow-hidden"
        >
          <header class="ic-scanlines relative flex flex-wrap items-center justify-between gap-3 border-b-2 border-base-content/20 px-4 py-3">
            <div class="relative z-[2]">
              <p class="ic-eyebrow">Calendar</p>
              <h2 class="font-display text-xl font-black uppercase tracking-tight">
                {header_label(@view, @anchor)}
              </h2>
            </div>
            <div class="relative z-[2] flex flex-wrap gap-2">
              <button
                id="calendar-add-events"
                type="button"
                phx-click="open_form"
                phx-target={@myself}
                class="rounded-xs bg-primary px-3 py-1.5 font-display text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
              >
                Add Events
              </button>
              <div class="flex gap-0.5 border-2 border-base-content/20 p-0.5">
                <button
                  :for={view <- [:month, :week, :day]}
                  type="button"
                  phx-click="set_view"
                  phx-value-view={Atom.to_string(view)}
                  phx-target={@myself}
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
                  phx-target={@myself}
                >
                  ←
                </button>
                <button
                  type="button"
                  class="border-2 border-base-content/20 px-3 py-1.5 font-mono text-xs font-bold uppercase tracking-wide transition hover:border-primary hover:text-primary"
                  phx-click="today"
                  phx-target={@myself}
                >
                  Today
                </button>
                <button
                  type="button"
                  class="border-2 border-base-content/20 px-3 py-1.5 font-mono text-sm transition hover:border-primary hover:text-primary"
                  phx-click="next"
                  phx-target={@myself}
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
            target={@myself}
          />
          <.week_view
            :if={@view == :week}
            grid_days={@grid_days}
            weekday_labels={@weekday_labels}
            today={@today}
            target={@myself}
          />
          <.day_view :if={@view == :day} day={hd(@grid_days)} target={@myself} />
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
                phx-target={@myself}
              >
                Edit
              </button>
              <button
                type="button"
                class="rounded-xs border-2 border-error/40 px-3 py-1.5 font-mono text-sm text-error transition hover:border-error"
                phx-click="delete"
                phx-value-id={@viewing_event.id}
                phx-target={@myself}
                data-claw-confirm={"Delete \"#{@viewing_event.title}\"?"}
              >
                Delete
              </button>
              <button
                type="button"
                class="rounded-xs px-3 py-1.5 font-mono text-sm text-base-content/60 transition hover:bg-base-content/10"
                phx-click="close_inspect"
                phx-target={@myself}
              >
                Close
              </button>
            </div>
          </div>
        </div>

        <.event_form_modal
          form_open={@form_open}
          form={@form}
          editing_event={@editing_event}
          color_options={@color_options}
          frequency_options={@frequency_options}
          myself={@myself}
        />
      </section>
    </div>
    """
  end

  # ---- View rebuild ----

  # The one place that reads the socket to ask Grid a question and the context
  # for the events in the answer. Everything it calls is pure.
  defp rebuild_view(socket) do
    {range_start, range_end} = view_range(socket.assigns.view, socket.assigns.anchor)
    events = Calendar.events_in_range(range_start, range_end)

    grid_days =
      build_grid_days(socket.assigns.view, socket.assigns.anchor, events, range_start, range_end)

    assign(socket, :grid_days, grid_days)
  end

  # ---- Form helpers ----
  # The rest of them are pure and live in Grid; this one takes a socket.

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))
end
