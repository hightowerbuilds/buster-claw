defmodule BusterClawWeb.Gws.CalendarSync do
  @moduledoc """
  The Google Calendar sync pane of the Workspace console.

  Named `CalendarSync` rather than `Calendar` so it cannot shadow Elixir's own
  `Calendar`, which the shared formatters call.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Gws.Shared

  attr :accounts, :list, required: true
  attr :calendar_sync_form, :any, required: true
  attr :calendar_sync, :any, default: nil

  def calendar_pane(assigns) do
    ~H"""
    <.tool_pane title="Sync Google Calendar">
      <:form>
        <.form
          for={@calendar_sync_form}
          id="google-calendar-sync-form"
          phx-submit="sync_google_calendar"
          class="space-y-3"
        >
          <.input
            field={@calendar_sync_form[:account_id]}
            id="google-calendar-account-id"
            type="select"
            label="Account"
            options={account_options(@accounts)}
          />
          <.input
            field={@calendar_sync_form[:calendar_id]}
            id="google-calendar-id"
            type="text"
            label="Calendar ID"
          />
          <.input
            field={@calendar_sync_form[:days_ahead]}
            id="google-calendar-days-ahead"
            type="number"
            label="Days Ahead"
            min="1"
            max="365"
          />
          <button
            class="w-full rounded bg-base-content px-3 py-2 text-sm font-semibold text-base-100 transition hover:opacity-85 disabled:opacity-40"
            disabled={@accounts == []}
          >
            Sync Calendar
          </button>
        </.form>
      </:form>

      <div
        :if={@calendar_sync}
        id="google-calendar-sync-results"
        class="rounded border border-base-300"
      >
        <div class="border-b border-base-300 px-3 py-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
          Imported Events
        </div>
        <div class="divide-y divide-base-300">
          <div
            :for={event <- @calendar_sync.events}
            id={"google-calendar-event-#{event.id}"}
            class="px-3 py-3"
          >
            <h3 class="truncate text-sm font-semibold">{event.title}</h3>
            <p class="mt-1 text-xs text-base-content/60">
              {event.date} {event.start_time && Calendar.strftime(event.start_time, "%H:%M")}
            </p>
          </div>

          <div
            :if={@calendar_sync.events == []}
            class="px-3 py-6 text-center text-sm text-base-content/60"
          >
            No Google Calendar events matched the sync window.
          </div>
        </div>
      </div>

      <p :if={is_nil(@calendar_sync)} class="text-sm text-base-content/50">
        Sync a calendar window to import upcoming events here.
      </p>
    </.tool_pane>
    """
  end
end
