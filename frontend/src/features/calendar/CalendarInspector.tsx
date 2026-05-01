import { For, Show } from "solid-js";
import type { CalendarEvent, JobState } from "../../wails.d";
import { formatSelectedDate, jobLabel } from "./calendarUtils";
import type { CalendarForm } from "./types";

type CalendarInspectorProps = {
  form: CalendarForm;
  selectedEvents: CalendarEvent[];
  selectedJobs: JobState[];
  onFormChange: (field: "date" | "title" | "notes", value: string) => void;
  onSave: () => void;
  onEdit: (event: CalendarEvent) => void;
  onDelete: (id: string) => void;
};

export function CalendarInspector(props: CalendarInspectorProps) {
  return (
    <aside class="calendar-editor">
      <div class="calendar-editor-section">
        <h3>{props.form.editingId ? "Edit Event" : "Add Event"}</h3>
        <input
          type="date"
          value={props.form.date}
          onInput={(event) => props.onFormChange("date", event.currentTarget.value)}
        />
        <input
          type="text"
          placeholder="Event title"
          value={props.form.title}
          onInput={(event) => props.onFormChange("title", event.currentTarget.value)}
        />
        <textarea
          rows={4}
          placeholder="Notes"
          value={props.form.notes}
          onInput={(event) => props.onFormChange("notes", event.currentTarget.value)}
        />
        <button class="btn btn-primary" disabled={!props.form.date || !props.form.title.trim()} onClick={props.onSave}>
          {props.form.editingId ? "Save Changes" : "Add Event"}
        </button>
      </div>

      <div class="calendar-editor-section">
        <h3>{formatSelectedDate(props.form.date)}</h3>
        <Show when={props.selectedEvents.length > 0} fallback={<p class="calendar-empty">No events for this date.</p>}>
          <div class="calendar-event-list">
            <For each={props.selectedEvents}>
              {(event) => (
                <div class="calendar-event-row">
                  <div>
                    <div class="calendar-event-title">{event.title}</div>
                    <Show when={event.notes}>
                      <div class="calendar-event-notes">{event.notes}</div>
                    </Show>
                  </div>
                  <div class="calendar-event-actions">
                    <button class="btn btn-small" onClick={() => props.onEdit(event)}>Edit</button>
                    <button class="btn btn-small btn-danger" onClick={() => props.onDelete(event.id)}>Delete</button>
                  </div>
                </div>
              )}
            </For>
          </div>
        </Show>
        <Show when={props.selectedJobs.length > 0}>
          <div class="calendar-selected-jobs">
            <h4>Scheduled Jobs</h4>
            <For each={props.selectedJobs}>
              {(job) => (
                <div class="calendar-job-row">
                  <div>
                    <div class="calendar-event-title">{jobLabel(job)}</div>
                    <div class="calendar-event-notes">
                      {new Date(job.nextRun).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })} · {job.cron}
                    </div>
                  </div>
                </div>
              )}
            </For>
          </div>
        </Show>
      </div>
    </aside>
  );
}
