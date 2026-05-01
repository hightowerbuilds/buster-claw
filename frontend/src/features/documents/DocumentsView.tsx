import { For, Show } from "solid-js";
import { MarkdownArticle } from "../../components/MarkdownArticle";
import { hostnameFromUrl } from "../../lib/urls";
import type { DocumentInfo, PendingFile, QueueEntry } from "../../wails.d";

type DocumentsViewProps = {
  visible: boolean;
  busy: boolean;
  streaming: boolean;
  documents: DocumentInfo[];
  analysisQueue: QueueEntry[];
  pendingFiles: PendingFile[];
  selectedDocument: DocumentInfo | null;
  documentContent: string;
  onDeleteDocument: (path: string) => void;
  onRunQueue: () => void;
  onQueueDocument: (path: string) => void;
  onOpenDocument: (doc: DocumentInfo) => void;
  onCloseDocument: () => void;
};

export function DocumentsView(props: DocumentsViewProps) {
  const titleFor = (doc: DocumentInfo) => doc.name || doc.filename.replace(".md", "").replace(/-/g, " ");
  const activeQueueCount = () => props.analysisQueue.filter((entry) => entry.status === "queued" || entry.status === "analyzing").length;
  const queuedCount = () => props.analysisQueue.filter((entry) => entry.status === "queued").length;
  const visibleQueue = () => props.analysisQueue.slice().reverse().slice(0, 5).reverse();
  const queueEntryFor = (path: string) => props.analysisQueue.find((entry) => entry.path === path);
  const isPending = (path: string) => props.pendingFiles.some((file) => file.path === path);
  const progressFor = (entry: QueueEntry) => {
    if (typeof entry.progress === "number") return Math.max(0, Math.min(100, entry.progress));
    if (entry.status === "done" || entry.status === "failed") return 100;
    if (entry.status === "analyzing") return 50;
    return 0;
  };
  const queueStatusLabel = (entry: QueueEntry) => {
    if (entry.status === "queued") return "Queued";
    if (entry.status === "analyzing") return "Analyzing";
    if (entry.status === "done") return "Complete";
    if (entry.status === "failed") return "Error";
    return entry.status;
  };
  const queueLabel = (doc: DocumentInfo) => {
    const entry = queueEntryFor(doc.path);
    if (entry?.status === "queued") return "Queued";
    if (entry?.status === "analyzing") return "Analyzing";
    if (entry?.status === "done") return "Analyzed";
    if (entry?.status === "failed") return "Retry Queue";
    if (activeQueueCount() >= 5) return "Queue Full";
    return isPending(doc.path) ? "Add to Queue" : "Requeue";
  };
  const canQueue = (doc: DocumentInfo) => {
    const status = queueEntryFor(doc.path)?.status;
    if (status === "queued" || status === "analyzing" || status === "done") return false;
    return activeQueueCount() < 5;
  };

  return (
    <div class="view-panel" classList={{ hidden: !props.visible }}>
      <Show when={props.selectedDocument}>
        {(doc) => (
          <div class="document-preview">
            <div class="report-reader-header">
              <button class="report-back-btn" onClick={props.onCloseDocument}>Back to Documents</button>
              <div class="report-reader-meta">
                <span>{doc().date}</span>
                <span>{doc().filename}</span>
              </div>
            </div>
            <MarkdownArticle markdown={props.documentContent} />
          </div>
        )}
      </Show>

      <div class="view-panel-content documents-panel" classList={{ hidden: !!props.selectedDocument }}>
        <div class="view-header">
          <div>
            <h2>Documents</h2>
            <div class="documents-summary">
              <span>{props.documents.length} ingested</span>
              <span>{props.pendingFiles.length} pending analysis</span>
              <span>{activeQueueCount()} / 5 in queue</span>
            </div>
          </div>
          <div class="view-header-actions">
            <button class="action-btn" onClick={props.onRunQueue} disabled={props.busy || props.streaming || queuedCount() === 0}>
              Run Queue
            </button>
          </div>
        </div>

        <Show when={visibleQueue().length > 0}>
          <div class="analysis-queue-strip" aria-label="Analysis queue progress">
            <For each={visibleQueue()}>
              {(entry) => (
                <div class="analysis-queue-chip" classList={{ active: entry.status === "analyzing", complete: entry.status === "done", failed: entry.status === "failed" }}>
                  <div class="analysis-chip-thumb">{entry.filename.slice(0, 2).toUpperCase()}</div>
                  <div class="analysis-chip-main">
                    <div class="analysis-chip-topline">
                      <span class="analysis-chip-title">{entry.filename.replace(".md", "")}</span>
                      <span class="analysis-chip-status">{queueStatusLabel(entry)}</span>
                    </div>
                    <div class="analysis-chip-progress" aria-hidden="true">
                      <div style={{ width: `${progressFor(entry)}%` }} />
                    </div>
                    <Show when={entry.error}>
                      <div class="analysis-chip-error">{entry.error}</div>
                    </Show>
                    <Show when={entry.report && entry.status === "done"}>
                      <div class="analysis-chip-report">{entry.report}</div>
                    </Show>
                    <Show when={entry.model}>
                      <div class="analysis-chip-report">{entry.model}</div>
                    </Show>
                  </div>
                </div>
              )}
            </For>
          </div>
        </Show>

        <div class="doc-list">
          <For each={props.documents} fallback={<div class="empty-list">No documents ingested yet. Go to Ingestion to fetch sources.</div>}>
            {(doc) => (
              <div class="doc-item">
                <div class="doc-thumbnail">
                  <div class="doc-thumbnail-bar">
                    <span>{doc.date}</span>
                    <span>Markdown</span>
                  </div>
                  <div class="doc-thumbnail-title">{titleFor(doc)}</div>
                  <div class="doc-thumbnail-excerpt">{doc.excerpt || "No preview text available."}</div>
                </div>
                <div class="doc-item-info">
                  <div class="doc-item-title">{titleFor(doc)}</div>
                  <div class="doc-item-meta">
                    <span class="doc-item-date">{doc.filename}</span>
                    <Show when={doc.sourceUrl}>
                      <span class="doc-item-url">{hostnameFromUrl(doc.sourceUrl)}</span>
                    </Show>
                  </div>
                </div>
                <div class="doc-actions">
                  <button class="doc-preview-btn" onClick={() => props.onOpenDocument(doc)}>Preview</button>
                  <button class="doc-queue-btn" disabled={!canQueue(doc)} onClick={() => props.onQueueDocument(doc.path)}>
                    {queueLabel(doc)}
                  </button>
                  <button class="doc-delete-btn" onClick={() => props.onDeleteDocument(doc.path)} title="Delete document">Delete</button>
                </div>
              </div>
            )}
          </For>
        </div>
      </div>
    </div>
  );
}
