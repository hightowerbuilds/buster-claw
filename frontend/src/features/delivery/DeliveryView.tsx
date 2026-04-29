import { For, Show } from "solid-js";
import type { DeliveryDestination } from "../../wails.d";

type DeliveryForm = {
  name: string;
  type: string;
  url: string;
  token: string;
  chatId: string;
};

type DeliveryViewProps = {
  visible: boolean;
  destinations: DeliveryDestination[];
  form: DeliveryForm;
  onFormChange: (field: keyof DeliveryForm, value: string) => void;
  onAddDestination: (destination: DeliveryForm) => void;
  onTestDestination: (name: string) => void;
  onDeleteDestination: (name: string) => void;
};

export function DeliveryView(props: DeliveryViewProps) {
  const addDestination = () => {
    if (!props.form.name) return;
    props.onAddDestination(props.form);
  };

  return (
    <div class="view-panel" classList={{ hidden: !props.visible }}>
      <div class="view-panel-content">
        <div class="view-header">
          <h2>Delivery</h2>
          <p>Configure where reports are sent after analysis.</p>
        </div>

        <div class="provider-add">
          <h4>Add Destination</h4>
          <div class="provider-add-fields">
            <div class="provider-add-row">
              <input type="text" placeholder="Name (e.g. My Slack)" value={props.form.name} onInput={(event) => props.onFormChange("name", event.currentTarget.value)} />
              <select value={props.form.type} onChange={(event) => props.onFormChange("type", event.currentTarget.value)}>
                <option value="slack">Slack (Webhook)</option>
                <option value="discord">Discord (Webhook)</option>
                <option value="telegram">Telegram (Bot)</option>
              </select>
            </div>
            <Show when={props.form.type === "slack" || props.form.type === "discord"}>
              <input type="text" placeholder="Webhook URL" value={props.form.url} onInput={(event) => props.onFormChange("url", event.currentTarget.value)} />
            </Show>
            <Show when={props.form.type === "telegram"}>
              <div class="provider-add-row">
                <input type="text" placeholder="Bot Token" value={props.form.token} onInput={(event) => props.onFormChange("token", event.currentTarget.value)} />
                <input type="text" placeholder="Chat ID" value={props.form.chatId} onInput={(event) => props.onFormChange("chatId", event.currentTarget.value)} />
              </div>
            </Show>
            <button class="action-btn" onClick={addDestination}>Add Destination</button>
          </div>
        </div>

        <div class="provider-list" style="margin-top: 24px;">
          <For each={props.destinations} fallback={<div class="empty-list">No delivery destinations configured.</div>}>
            {(destination) => (
              <div class="provider-item" classList={{ "provider-active": destination.enabled }}>
                <div class="provider-item-info">
                  <div class="provider-item-name">{destination.name}</div>
                  <div class="provider-item-meta">
                    <span class="source-item-type">{destination.type}</span>
                    <Show when={destination.url}><span class="provider-item-url">{destination.url!.substring(0, 40)}...</span></Show>
                    <Show when={destination.chatId}><span>Chat: {destination.chatId}</span></Show>
                  </div>
                </div>
                <div class="provider-item-actions">
                  <button class="source-ingest-btn" onClick={() => props.onTestDestination(destination.name)}>Test</button>
                  <button class="source-delete-btn" onClick={() => props.onDeleteDestination(destination.name)}>Remove</button>
                </div>
              </div>
            )}
          </For>
        </div>
      </div>
    </div>
  );
}
