import { For, Show } from "solid-js";

type ModelsViewProps = {
  models: string[];
  currentModel: string;
  onRefresh: () => void;
  onSelectModel: (model: string) => void;
};

export function ModelsView(props: ModelsViewProps) {
  return (
    <div class="advanced-subview">
      <div class="view-header">
        <h2>Models</h2>
        <div class="view-header-actions">
          <span class="source-count">{props.models.length} installed</span>
          <button class="action-btn" onClick={props.onRefresh}>Refresh</button>
        </div>
      </div>

      <div class="model-list">
        <For each={props.models} fallback={<div class="empty-list">No models found. Make sure Ollama is running.</div>}>
          {(model) => (
            <div class="model-item" classList={{ "model-item-active": model === props.currentModel }}>
              <div class="model-item-info">
                <div class="model-item-name">{model}</div>
                <Show when={model === props.currentModel}>
                  <span class="model-item-badge">active</span>
                </Show>
              </div>
              <Show when={model !== props.currentModel}>
                <button class="source-ingest-btn" onClick={() => props.onSelectModel(model)}>Select</button>
              </Show>
            </div>
          )}
        </For>
      </div>
    </div>
  );
}
