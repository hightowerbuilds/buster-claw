import { For, Show } from "solid-js";
import type { PendingFile, QueueEntry } from "../../wails.d";

type OrchestrationViewProps = {
  visible: boolean;
  busy: boolean;
  streaming: boolean;
  analysisQueue: QueueEntry[];
  pendingFiles: PendingFile[];
  onRunQueue: () => void;
  onRemoveFromQueue: (path: string) => void;
  onQueueDocument: (path: string) => void;
};

export function OrchestrationView(props: OrchestrationViewProps) {
  const queuedCount = () => props.analysisQueue.filter((entry) => entry.status === "queued").length;

  return (
    <div class="view-panel" classList={{ hidden: !props.visible }}>
      <div class="view-panel-content">
        <div class="view-header">
          <h2>Orchestration</h2>
          <div class="view-header-actions">
            <button class="action-btn" onClick={props.onRunQueue} disabled={props.busy || props.streaming || queuedCount() === 0}>
              Run Queue
            </button>
          </div>
        </div>

        <div class="orch-section">
          <h3>Analysis Queue</h3>
          <div class="orch-queue">
            <For each={props.analysisQueue} fallback={<div class="empty-list">No documents queued. Select documents below to add them.</div>}>
              {(entry) => (
                <div
                  class="orch-queue-item"
                  classList={{
                    "orch-analyzing": entry.status === "analyzing",
                    "orch-done": entry.status === "done",
                    "orch-failed": entry.status === "failed",
                  }}
                >
                  <div class="orch-queue-item-fill" />
                  <div class="orch-queue-item-content">
                    <div class="orch-queue-item-name">{entry.filename}</div>
                    <div class="orch-queue-item-status">{entry.status}</div>
                  </div>
                  <Show when={entry.status === "failed" || entry.status === "queued"}>
                    <button class="queue-remove-btn" onClick={() => props.onRemoveFromQueue(entry.path)}>Remove</button>
                  </Show>
                </div>
              )}
            </For>
          </div>
        </div>

        <div class="orch-section">
          <h3>Unanalyzed Documents <span class="source-count">({props.pendingFiles.length})</span></h3>
          <div class="orch-pending">
            <For each={props.pendingFiles} fallback={<div class="empty-list">All documents have been analyzed or queued.</div>}>
              {(file) => (
                <div class="orch-pending-item">
                  <div class="orch-pending-info">
                    <div class="orch-pending-name">{file.filename}</div>
                    <div class="orch-pending-date">{file.date}</div>
                  </div>
                  <button class="source-ingest-btn" onClick={() => props.onQueueDocument(file.path)}>Queue</button>
                </div>
              )}
            </For>
          </div>
        </div>
      </div>
    </div>
  );
}
