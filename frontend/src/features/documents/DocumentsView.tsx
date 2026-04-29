import { For, Show } from "solid-js";
import type { DocumentInfo } from "../../wails.d";

type DocumentsViewProps = {
  visible: boolean;
  documents: DocumentInfo[];
  onDeleteDocument: (path: string) => void;
};

export function DocumentsView(props: DocumentsViewProps) {
  return (
    <div class="view-panel" classList={{ hidden: !props.visible }}>
      <div class="view-panel-content">
        <div class="view-header">
          <h2>Documents</h2>
          <span class="source-count">{props.documents.length} ingested</span>
        </div>

        <div class="doc-list">
          <For each={props.documents} fallback={<div class="empty-list">No documents ingested yet. Go to Ingestion to fetch sources.</div>}>
            {(doc) => (
              <div class="doc-item">
                <div class="doc-item-info">
                  <div class="doc-item-title">{doc.name || doc.filename}</div>
                  <div class="doc-item-meta">
                    <span class="doc-item-date">{doc.date}</span>
                    <Show when={doc.sourceUrl}>
                      <span class="doc-item-url">{doc.sourceUrl}</span>
                    </Show>
                  </div>
                </div>
                <button class="doc-delete-btn" onClick={() => props.onDeleteDocument(doc.path)} title="Delete document">Delete</button>
              </div>
            )}
          </For>
        </div>
      </div>
    </div>
  );
}
