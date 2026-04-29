import { For, Show } from "solid-js";
import type { JobState } from "../../wails.d";

type JobForm = {
  id: string;
  type: string;
  cron: string;
  customCmd: string;
  deliverTo: string;
};

type SchedulerViewProps = {
  visible: boolean;
  jobs: JobState[];
  form: JobForm;
  onFormChange: (field: keyof JobForm, value: string) => void;
  onAddJob: (job: JobForm) => void;
  onToggleJob: (job: JobState) => void;
  onRunJobNow: (id: string) => void;
  onDeleteJob: (id: string) => void;
};

export function SchedulerView(props: SchedulerViewProps) {
  const addJob = () => {
    if (!props.form.id || !props.form.cron) return;
    props.onAddJob(props.form);
  };

  return (
    <div class="view-panel" classList={{ hidden: !props.visible }}>
      <div class="view-panel-content">
        <div class="view-header">
          <h2>Scheduler</h2>
          <p>Configure autonomous background jobs.</p>
        </div>

        <div class="action-bar">
          <input type="text" class="search-input" placeholder="Job ID" value={props.form.id} onInput={(event) => props.onFormChange("id", event.currentTarget.value)} />
          <select class="search-input" value={props.form.type} onChange={(event) => props.onFormChange("type", event.currentTarget.value)}>
            <option value="ingest">Ingest</option>
            <option value="analyze">Analyze</option>
            <option value="full">Full Pipeline</option>
            <option value="custom">Custom Command</option>
          </select>
          <input type="text" class="search-input" placeholder="Cron (e.g. 0 7 * * *)" value={props.form.cron} onInput={(event) => props.onFormChange("cron", event.currentTarget.value)} />

          <Show when={props.form.type === "custom"}>
            <input type="text" class="search-input" placeholder="/search AI news" value={props.form.customCmd} onInput={(event) => props.onFormChange("customCmd", event.currentTarget.value)} />
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
              <th>Last Run</th>
              <th>Next Run</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <Show when={props.jobs.length === 0}>
              <tr><td colspan="7" class="empty-state">No scheduled jobs.</td></tr>
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
                      classList={{ "success": job.enabled, "failed": !job.enabled }}
                      onClick={() => props.onToggleJob(job)}
                    >
                      {job.enabled ? "Active" : "Paused"}
                    </button>
                  </td>
                  <td class="mono" style="font-size: 0.85em;">
                    {job.lastRun ? new Date(job.lastRun).toLocaleString() : "Never"}
                    <Show when={job.lastError}>
                      <div class="text-error" style="margin-top: 4px">{job.lastError}</div>
                    </Show>
                  </td>
                  <td class="mono" style="font-size: 0.85em;">
                    {job.nextRun ? new Date(job.nextRun).toLocaleString() : "-"}
                  </td>
                  <td class="actions-col">
                    <button class="icon-btn" title="Run Now" onClick={() => props.onRunJobNow(job.id)}>▶️</button>
                    <button class="icon-btn text-error" title="Delete" onClick={() => props.onDeleteJob(job.id)}>🗑️</button>
                  </td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>
    </div>
  );
}
