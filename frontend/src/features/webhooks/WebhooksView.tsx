import { For, Show } from "solid-js";
import type { Hook, Webhook } from "../../wails.d";

type WebhookForm = {
  name: string;
  action: string;
  customCmd: string;
  deliverTo: string;
};

type HookForm = {
  name: string;
  event: string;
  type: string;
  target: string;
  async: boolean;
};

type WebhooksViewProps = {
  visible: boolean;
  webhooks: Webhook[];
  webhookForm: WebhookForm;
  hooks: Hook[];
  hookForm: HookForm;
  onWebhookFormChange: (field: keyof WebhookForm, value: string) => void;
  onHookFormChange: (field: keyof HookForm, value: string | boolean) => void;
  onAddWebhook: (webhook: WebhookForm) => void;
  onToggleWebhook: (name: string, enabled: boolean) => void;
  onDeleteWebhook: (name: string) => void;
  onAddHook: (hook: HookForm) => void;
  onDeleteHook: (name: string) => void;
};

export function WebhooksView(props: WebhooksViewProps) {
  const addWebhook = () => {
    if (!props.webhookForm.name) return;
    props.onAddWebhook(props.webhookForm);
  };

  const addHook = () => {
    if (!props.hookForm.name || !props.hookForm.target) return;
    props.onAddHook(props.hookForm);
  };

  return (
    <div class="view-panel" classList={{ hidden: !props.visible }}>
      <div class="view-panel-content">
        <div class="view-header">
          <div>
            <h2>Webhooks / Hooks</h2>
            <p>External webhooks trigger research tasks. Reactive hooks run when pipeline events happen.</p>
          </div>
        </div>

        <section class="automation-section">
          <div class="automation-section-header">
            <h3>External Webhooks</h3>
            <p>Base URL: <code>http://localhost:9090/hooks/</code></p>
          </div>

        <div class="action-bar">
          <input type="text" class="search-input" placeholder="Webhook Name" value={props.webhookForm.name} onInput={(event) => props.onWebhookFormChange("name", event.currentTarget.value)} />
          <select class="search-input" value={props.webhookForm.action} onChange={(event) => props.onWebhookFormChange("action", event.currentTarget.value)}>
            <option value="ingest">Ingest All</option>
            <option value="analyze">Analyze Queue</option>
            <option value="full">Full Pipeline</option>
            <option value="command">Custom Command</option>
          </select>
          <Show when={props.webhookForm.action === "command"}>
            <input type="text" class="search-input" placeholder="/search AI news" value={props.webhookForm.customCmd} onInput={(event) => props.onWebhookFormChange("customCmd", event.currentTarget.value)} />
          </Show>
          <button class="btn btn-primary" onClick={addWebhook}>Add Webhook</button>
        </div>

        <table class="data-table">
          <thead>
            <tr>
              <th>Name</th>
              <th>Action</th>
              <th>Endpoint</th>
              <th>Status</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <Show when={props.webhooks.length === 0}>
              <tr><td colspan="5" class="empty-state">No webhooks configured.</td></tr>
            </Show>
            <For each={props.webhooks}>
              {(webhook) => (
                <tr>
                  <td class="primary-col">{webhook.name}</td>
                  <td>{webhook.action}{webhook.customCmd ? ` (${webhook.customCmd})` : ""}</td>
                  <td class="mono" style="font-size: 0.85em;">/hooks/{webhook.name}</td>
                  <td>
                    <button
                      class="status-badge"
                      classList={{ "success": webhook.enabled, "failed": !webhook.enabled }}
                      onClick={() => props.onToggleWebhook(webhook.name, !webhook.enabled)}
                    >
                      {webhook.enabled ? "Active" : "Paused"}
                    </button>
                  </td>
                  <td class="actions-col">
                    <button class="icon-btn" title="Copy URL" onClick={() => navigator.clipboard.writeText(`http://localhost:9090/hooks/${webhook.name}`)}>📋</button>
                    <button class="icon-btn text-error" title="Delete" onClick={() => props.onDeleteWebhook(webhook.name)}>🗑️</button>
                  </td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
        </section>

        <section class="automation-section">
          <div class="automation-section-header">
            <h3>Reactive Hooks</h3>
            <p>Execute shell commands or POST webhooks at specific points in the pipeline.</p>
          </div>

          <div class="provider-add">
            <h4>Add Reactive Hook</h4>
            <div class="provider-add-fields">
              <div class="provider-add-row">
                <input type="text" placeholder="Hook Name" value={props.hookForm.name} onInput={(event) => props.onHookFormChange("name", event.currentTarget.value)} />
                <select value={props.hookForm.event} onChange={(event) => props.onHookFormChange("event", event.currentTarget.value)}>
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
                <select value={props.hookForm.type} onChange={(event) => props.onHookFormChange("type", event.currentTarget.value)}>
                  <option value="shell">Shell Command</option>
                  <option value="webhook">Webhook POST</option>
                </select>
                <label class="checkbox-row">
                  <input type="checkbox" checked={props.hookForm.async} onChange={(event) => props.onHookFormChange("async", event.currentTarget.checked)} />
                  Async
                </label>
              </div>
              <input
                type="text"
                placeholder={props.hookForm.type === "shell" ? "bash command (e.g. echo 'done' >> log.txt)" : "Webhook URL"}
                value={props.hookForm.target}
                onInput={(event) => props.onHookFormChange("target", event.currentTarget.value)}
              />
              <button class="action-btn" onClick={addHook}>Add Reactive Hook</button>
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
        </section>
      </div>
    </div>
  );
}
