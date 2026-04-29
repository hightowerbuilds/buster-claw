import { For, Show } from "solid-js";
import type { Webhook } from "../../wails.d";

type WebhookForm = {
  name: string;
  action: string;
  customCmd: string;
  deliverTo: string;
};

type WebhooksViewProps = {
  visible: boolean;
  webhooks: Webhook[];
  form: WebhookForm;
  onFormChange: (field: keyof WebhookForm, value: string) => void;
  onAddWebhook: (webhook: WebhookForm) => void;
  onToggleWebhook: (name: string, enabled: boolean) => void;
  onDeleteWebhook: (name: string) => void;
};

export function WebhooksView(props: WebhooksViewProps) {
  const addWebhook = () => {
    if (!props.form.name) return;
    props.onAddWebhook(props.form);
  };

  return (
    <div class="view-panel" classList={{ hidden: !props.visible }}>
      <div class="view-panel-content">
        <div class="view-header">
          <h2>Webhooks</h2>
          <p>External events can trigger research tasks. Base URL: <code>http://localhost:9090/hooks/</code></p>
        </div>

        <div class="action-bar">
          <input type="text" class="search-input" placeholder="Hook Name" value={props.form.name} onInput={(event) => props.onFormChange("name", event.currentTarget.value)} />
          <select class="search-input" value={props.form.action} onChange={(event) => props.onFormChange("action", event.currentTarget.value)}>
            <option value="ingest">Ingest All</option>
            <option value="analyze">Analyze Queue</option>
            <option value="full">Full Pipeline</option>
            <option value="command">Custom Command</option>
          </select>
          <Show when={props.form.action === "command"}>
            <input type="text" class="search-input" placeholder="/search AI news" value={props.form.customCmd} onInput={(event) => props.onFormChange("customCmd", event.currentTarget.value)} />
          </Show>
          <button class="btn btn-primary" onClick={addWebhook}>Add Hook</button>
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
      </div>
    </div>
  );
}
