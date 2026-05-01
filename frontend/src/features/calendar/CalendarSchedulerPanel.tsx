import { For, Show } from "solid-js";
import type { JobState } from "../../wails.d";
import type { JobForm } from "./types";

type CalendarSchedulerPanelProps = {
  jobs: JobState[];
  jobForm: JobForm;
  onJobFormChange: (field: keyof JobForm, value: string) => void;
  onAddJob: (job: JobForm) => void;
  onToggleJob: (job: JobState) => void;
  onRunJobNow: (id: string) => void;
  onDeleteJob: (id: string) => void;
};

export function CalendarSchedulerPanel(props: CalendarSchedulerPanelProps) {
  const addJob = () => {
    if (!props.jobForm.id || !props.jobForm.cron) return;
    props.onAddJob(props.jobForm);
  };

  return (
    <section class="calendar-scheduler-section">
      <div class="automation-section-header">
        <h3>Scheduled Cron Jobs</h3>
        <p>Create autonomous jobs here. Their next run appears on the calendar.</p>
      </div>

      <div class="action-bar calendar-scheduler-form">
        <input type="text" class="search-input" placeholder="Job ID" value={props.jobForm.id} onInput={(event) => props.onJobFormChange("id", event.currentTarget.value)} />
        <select class="search-input" value={props.jobForm.type} onChange={(event) => props.onJobFormChange("type", event.currentTarget.value)}>
          <option value="ingest">Ingest</option>
          <option value="analyze">Analyze</option>
          <option value="full">Full Pipeline</option>
          <option value="custom">Custom Command</option>
        </select>
        <input type="text" class="search-input" placeholder="Cron (e.g. 0 7 * * *)" value={props.jobForm.cron} onInput={(event) => props.onJobFormChange("cron", event.currentTarget.value)} />
        <Show when={props.jobForm.type === "custom"}>
          <input type="text" class="search-input" placeholder="/search AI news" value={props.jobForm.customCmd} onInput={(event) => props.onJobFormChange("customCmd", event.currentTarget.value)} />
        </Show>
        <button class="btn btn-primary" onClick={addJob}>Add Job</button>
      </div>

      <table class="data-table">
        <thead>
          <tr>
            <th>ID</th>
            <th>Type</th>
            <th>Schedule</th>
            <th>Status</th>
            <th>Next Run</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          <Show when={props.jobs.length === 0}>
            <tr><td colspan="6" class="empty-state">No scheduled jobs.</td></tr>
          </Show>
          <For each={props.jobs}>
            {(job) => (
              <tr>
                <td class="primary-col">{job.id}</td>
                <td>{job.type}{job.customCmd ? ` (${job.customCmd})` : ""}</td>
                <td class="mono">{job.cron}</td>
                <td>
                  <button
                    class="status-badge"
                    classList={{ success: job.enabled, failed: !job.enabled }}
                    onClick={() => props.onToggleJob(job)}
                  >
                    {job.enabled ? "Active" : "Paused"}
                  </button>
                </td>
                <td class="mono calendar-next-run">
                  {job.nextRun ? new Date(job.nextRun).toLocaleString() : "-"}
                </td>
                <td class="actions-col">
                  <button class="icon-btn" title="Run Now" onClick={() => props.onRunJobNow(job.id)}>Run</button>
                  <button class="icon-btn text-error" title="Delete" onClick={() => props.onDeleteJob(job.id)}>Delete</button>
                </td>
              </tr>
            )}
          </For>
        </tbody>
      </table>
    </section>
  );
}
