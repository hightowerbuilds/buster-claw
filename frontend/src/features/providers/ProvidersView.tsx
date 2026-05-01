import { For, Show } from "solid-js";
import type { ProviderInfo } from "../../wails.d";

type ProviderForm = {
  name: string;
  type: string;
  baseUrl: string;
  apiKey: string;
  model: string;
};

type ProvidersViewProps = {
  providers: ProviderInfo[];
  testResult: string;
  form: ProviderForm;
  onFormChange: (field: keyof ProviderForm, value: string) => void;
  onAddProvider: (provider: ProviderForm) => void;
  onActivateProvider: (name: string) => void;
  onRemoveProvider: (name: string) => void;
  onTestProvider: (name: string) => void;
};

export function ProvidersView(props: ProvidersViewProps) {
  const addProvider = () => {
    if (!props.form.name.trim() || !props.form.model.trim()) return;
    props.onAddProvider({
      name: props.form.name.trim(),
      type: props.form.type,
      baseUrl: props.form.baseUrl.trim(),
      apiKey: props.form.apiKey.trim(),
      model: props.form.model.trim(),
    });
  };

  return (
    <div class="advanced-subview">
      <div class="view-header">
        <h2>Providers</h2>
        <span class="source-count">{props.providers.length} configured</span>
      </div>

      <div class="provider-list">
        <For each={props.providers} fallback={<div class="empty-list">No providers configured. Add one below to enable API-backed agentic work.</div>}>
          {(provider) => (
            <div class="provider-item" classList={{ "provider-active": provider.active }}>
              <div class="provider-item-info">
                <div class="provider-item-name">
                  {provider.name}
                  <Show when={provider.active}><span class="model-item-badge">active</span></Show>
                </div>
                <div class="provider-item-meta">
                  <span class="source-item-type">{provider.type}</span>
                  <span>{provider.model}</span>
                  <Show when={provider.hasKey}><span class="provider-key-badge">key set</span></Show>
                </div>
                <Show when={provider.baseUrl}>
                  <div class="provider-item-url">{provider.baseUrl}</div>
                </Show>
              </div>
              <div class="provider-item-actions">
                <Show when={!provider.active}>
                  <button class="source-ingest-btn" onClick={() => props.onActivateProvider(provider.name)}>Activate</button>
                </Show>
                <button class="source-ingest-btn" onClick={() => props.onTestProvider(provider.name)}>Test</button>
                <button class="source-delete-btn" onClick={() => props.onRemoveProvider(provider.name)}>Remove</button>
              </div>
            </div>
          )}
        </For>
      </div>

      <Show when={props.testResult}>
        <div class="provider-test-result">{props.testResult}</div>
      </Show>

      <div class="provider-add">
        <h4>Add Provider</h4>
        <div class="provider-add-fields">
          <div class="provider-add-row">
            <input type="text" placeholder="Name (e.g. openrouter-main)" value={props.form.name} onInput={(event) => props.onFormChange("name", event.currentTarget.value)} />
            <select value={props.form.type} onChange={(event) => props.onFormChange("type", event.currentTarget.value)}>
              <option value="openrouter">OpenRouter</option>
              <option value="openai">OpenAI</option>
              <option value="anthropic">Anthropic</option>
              <option value="custom">Custom (OpenAI-compatible)</option>
            </select>
          </div>
          <input type="text" placeholder="Model (e.g. anthropic/claude-sonnet-4, gpt-4o)" value={props.form.model} onInput={(event) => props.onFormChange("model", event.currentTarget.value)} />
          <input type="password" placeholder="API Key" value={props.form.apiKey} onInput={(event) => props.onFormChange("apiKey", event.currentTarget.value)} />
          <input type="text" placeholder="Base URL (optional - defaults per type)" value={props.form.baseUrl} onInput={(event) => props.onFormChange("baseUrl", event.currentTarget.value)} />
          <button class="action-btn" onClick={addProvider} disabled={!props.form.name.trim() || !props.form.model.trim()}>Add Provider</button>
        </div>
      </div>
    </div>
  );
}
