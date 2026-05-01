import { For } from "solid-js";
import type { Source } from "../../wails.d";

type IngestionViewProps = {
  visible: boolean;
  busy: boolean;
  streaming: boolean;
  sources: Source[];
  sourceUrl: string;
  sourceName: string;
  sourceType: string;
  sourceTags: string;
  onSourceUrlChange: (value: string) => void;
  onSourceNameChange: (value: string) => void;
  onSourceTypeChange: (value: string) => void;
  onSourceTagsChange: (value: string) => void;
  onStartIngest: () => void;
  onIngestSingle: (url: string) => void;
  onDeleteSource: (url: string) => void;
  onAddSource: () => void;
};

export function IngestionView(props: IngestionViewProps) {
  return (
    <div class="view-panel" classList={{ hidden: !props.visible }}>
      <div class="view-panel-content">
        <div class="view-header">
          <h2>Sources</h2>
          <div class="view-header-actions">
            <span class="source-count">{props.sources.length} sources</span>
            <button class="action-btn" onClick={props.onStartIngest} disabled={props.busy || props.streaming || props.sources.length === 0}>Ingest All</button>
          </div>
        </div>

        <div class="source-list">
          <For each={props.sources} fallback={<div class="empty-list">No sources configured yet.</div>}>
            {(source) => (
              <div class="source-item">
                <div class="source-item-info">
                  <div class="source-item-name">{source.name || source.url}</div>
                  <div class="source-item-url">{source.url}</div>
                  <div class="source-item-meta">
                    <span class="source-item-type">{source.type}</span>
                    <For each={source.tags || []}>{(tag) => <span class="source-item-tag">{tag}</span>}</For>
                  </div>
                </div>
                <div class="source-item-actions">
                  <button class="source-ingest-btn" onClick={() => props.onIngestSingle(source.url)} disabled={props.busy || props.streaming}>Ingest</button>
                  <button class="source-delete-btn" onClick={() => props.onDeleteSource(source.url)}>Remove</button>
                </div>
              </div>
            )}
          </For>
        </div>

        <div class="source-add">
          <h4>Add Source</h4>
          <div class="source-add-fields">
            <input type="text" placeholder="URL" value={props.sourceUrl} onInput={(event) => props.onSourceUrlChange(event.currentTarget.value)} />
            <input type="text" placeholder="Name (optional)" value={props.sourceName} onInput={(event) => props.onSourceNameChange(event.currentTarget.value)} />
            <div class="source-add-row">
              <select value={props.sourceType} onChange={(event) => props.onSourceTypeChange(event.currentTarget.value)}>
                <option value="rss">RSS</option>
                <option value="article">Article</option>
                <option value="documentation">Documentation</option>
              </select>
              <input type="text" placeholder="Tags (comma separated)" value={props.sourceTags} onInput={(event) => props.onSourceTagsChange(event.currentTarget.value)} />
            </div>
            <button class="action-btn" onClick={props.onAddSource} disabled={!props.sourceUrl.trim()}>Add to Roster</button>
          </div>
        </div>
      </div>
    </div>
  );
}
