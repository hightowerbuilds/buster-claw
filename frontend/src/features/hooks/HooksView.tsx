import { For, Show } from "solid-js";
import type { Hook } from "../../wails.d";

type HookForm = {
  name: string;
  event: string;
  type: string;
  target: string;
  async: boolean;
};

type HooksViewProps = {
  visible: boolean;
  hooks: Hook[];
  form: HookForm;
  onFormChange: (field: keyof HookForm, value: string | boolean) => void;
  onAddHook: (hook: HookForm) => void;
  onDeleteHook: (name: string) => void;
};

export function HooksView(props: HooksViewProps) {
  const addHook = () => {
    if (!props.form.name || !props.form.target) return;
    props.onAddHook(props.form);
  };

  return (
    <div class="view-panel" classList={{ hidden: !props.visible }}>
      <div class="view-panel-content">
        <div class="view-header">
          <h2>Reactive Hooks</h2>
          <p>Execute shell commands or webhooks at specific points in the pipeline.</p>
        </div>

        <div class="provider-add">
          <h4>Add Hook</h4>
          <div class="provider-add-fields">
            <div class="provider-add-row">
              <input type="text" placeholder="Hook Name" value={props.form.name} onInput={(event) => props.onFormChange("name", event.currentTarget.value)} />
              <select value={props.form.event} onChange={(event) => props.onFormChange("event", event.currentTarget.value)}>
                <option value="pre_ingest">Pre Ingest</option>
                <option value="post_ingest">Post Ingest</option>
                <option value="pre_analysis">Pre Analysis</option>
                <option value="post_analysis">Post Analysis</option>
                <option value="pre_report">Pre Report</option>
                <option value="post_report">Post Report</option>
                <option value="on_error">On Error</option>
              </select>
            </div>
            <div class="provider-add-row">
              <select value={props.form.type} onChange={(event) => props.onFormChange("type", event.currentTarget.value)}>
                <option value="shell">Shell Command</option>
                <option value="webhook">Webhook (POST)</option>
              </select>
              <label style="display: flex; align-items: center; gap: 8px; font-size: 0.9em;">
                <input type="checkbox" checked={props.form.async} onChange={(event) => props.onFormChange("async", event.currentTarget.checked)} />
                Async
              </label>
            </div>
            <input type="text" placeholder={props.form.type === "shell" ? "bash command (e.g. echo 'done' >> log.txt)" : "Webhook URL"} value={props.form.target} onInput={(event) => props.onFormChange("target", event.currentTarget.value)} />
            <button class="action-btn" onClick={addHook}>Add Hook</button>
          </div>
        </div>

        <div class="provider-list" style="margin-top: 24px;">
          <For each={props.hooks} fallback={<div class="empty-list">No reactive hooks configured.</div>}>
            {(hook) => (
              <div class="provider-item" classList={{ "provider-active": hook.enabled }}>
                <div class="provider-item-info">
                  <div class="provider-item-name">{hook.name} <span class="text-muted" style="font-size: 0.7em;">({hook.event})</span></div>
                  <div class="provider-item-meta">
                    <span class="source-item-type">{hook.type}</span>
                    <span class="provider-item-url">{hook.target.substring(0, 50)}{hook.target.length > 50 ? "..." : ""}</span>
                    <Show when={hook.async}><span>(async)</span></Show>
                  </div>
                </div>
                <div class="provider-item-actions">
                  <button class="source-delete-btn" onClick={() => props.onDeleteHook(hook.name)}>Remove</button>
                </div>
              </div>
            )}
          </For>
        </div>
      </div>
    </div>
  );
}
