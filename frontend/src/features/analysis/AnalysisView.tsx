import { For, Show } from "solid-js";
import { renderMarkdown } from "../../lib/markdown";
import type { ReportMeta } from "../../wails.d";

type AnalysisViewProps = {
  visible: boolean;
  reports: ReportMeta[];
  selectedReport: ReportMeta | null;
  reportContent: string;
  onOpenReport: (report: ReportMeta) => void;
  onCloseReport: () => void;
};

export function AnalysisView(props: AnalysisViewProps) {
  const selectedReport = () => props.selectedReport;

  return (
    <div class="view-panel" classList={{ hidden: !props.visible }}>
      <Show when={!selectedReport()}>
        <div class="view-panel-content">
          <div class="view-header">
            <h2>Analysis</h2>
            <span class="source-count">{props.reports.length} reports</span>
          </div>

          <div class="report-list">
            <For each={props.reports} fallback={<div class="empty-list">No analysis reports yet. Add documents to the queue from Documents, then run the queue.</div>}>
              {(report) => (
                <div class="report-item" onClick={() => props.onOpenReport(report)}>
                  <div class="report-item-title">{report.filename}</div>
                  <div class="report-item-meta">
                    <span class="report-item-date">{report.generated_at?.split("T")[0]}</span>
                    <span class="report-item-model">{report.model}</span>
                    <Show when={report.source_url}>
                      <span class="report-item-source">{report.source_url}</span>
                    </Show>
                  </div>
                  <Show when={report.tags && report.tags.length > 0}>
                    <div class="report-item-tags">
                      <For each={report.tags!}>{(tag) => <span class="source-item-tag">{tag}</span>}</For>
                    </div>
                  </Show>
                </div>
              )}
            </For>
          </div>
        </div>
      </Show>

      <Show when={selectedReport()}>
        <div class="report-reader">
          <div class="report-reader-header">
            <button class="report-back-btn" onClick={props.onCloseReport}>Back to Reports</button>
            <div class="report-reader-meta">
              <span>{selectedReport()!.generated_at?.split("T")[0]}</span>
              <span class="report-reader-model">{selectedReport()!.model}</span>
            </div>
          </div>
          <article class="report-article" innerHTML={renderMarkdown(props.reportContent)} />
        </div>
      </Show>
    </div>
  );
}
