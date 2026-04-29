import { For, Show } from "solid-js";
import { hostnameFromUrl } from "../../lib/urls";
import type { DocumentInfo, JobState, PendingFile, QueueEntry, ReportMeta } from "../../wails.d";
import { AnalogClock } from "./AnalogClock";
import { WeeklyPlanCalendar } from "./WeeklyPlanCalendar";

type HomeViewProps = {
  visible: boolean;
  jobs: JobState[];
  reports: ReportMeta[];
  documents: DocumentInfo[];
  analysisQueue: QueueEntry[];
  pendingFiles: PendingFile[];
  onOpenReport: (report: ReportMeta) => void;
};

export function HomeView(props: HomeViewProps) {
  return (
    <div class="view-panel home-view" classList={{ hidden: !props.visible }}>
      <div class="newspaper-container">
        <main class="newspaper-grid">
          <div class="main-column">
            <AnalogClock />
            <WeeklyPlanCalendar jobs={props.jobs} />
            <h2 class="section-title">Latest Analysis</h2>
            <Show when={props.reports.length > 0} fallback={<p class="empty-story">No recent analysis available. The newsroom is quiet.</p>}>
              <div class="featured-story">
                <div class="story-list">
                  <For each={props.reports.slice().reverse().slice(0, 5)}>
                    {(report) => (
                      <div class="story-item" onClick={() => props.onOpenReport(report)}>
                        <h4>{report.filename.replace("report-", "").replace(".md", "").replace(/-/g, " ")}</h4>
                        <div class="story-meta">
                          <span>{hostnameFromUrl(report.source_url, report.source_file)}</span>
                          <span>{new Date(report.generated_at).toLocaleDateString()}</span>
                        </div>
                      </div>
                    )}
                  </For>
                </div>
              </div>
            </Show>
          </div>

          <div class="side-column">
            <div class="sidebar-module">
              <h2 class="section-title">Recent Ingestions</h2>
              <ul class="brief-list">
                <Show when={props.documents.length > 0} fallback={<li class="empty-story">No recent ingestions.</li>}>
                  <For each={props.documents.slice().reverse().slice(0, 6)}>
                    {(doc) => (
                      <li>
                        <div class="doc-title">{doc.name || doc.filename.replace(".md", "")}</div>
                        <div class="story-meta">{hostnameFromUrl(doc.sourceUrl)}</div>
                      </li>
                    )}
                  </For>
                </Show>
              </ul>
            </div>

            <div class="sidebar-module" style="margin-top: 24px;">
              <h2 class="section-title">Up Next</h2>
              <ul class="brief-list">
                <Show when={props.analysisQueue.length > 0 || props.pendingFiles.length > 0} fallback={<li class="empty-story">The queue is empty.</li>}>
                  <For each={props.analysisQueue.slice(0, 4)}>
                    {(entry) => (
                      <li>
                        <div class="doc-title">{entry.filename.replace(".md", "")}</div>
                        <div class="queue-status" classList={{ "active": entry.status === "analyzing" }}>{entry.status}</div>
                      </li>
                    )}
                  </For>
                  <Show when={props.pendingFiles.length > 0}>
                    <li class="queue-more text-muted" style="margin-top: 8px; font-size: 0.85em; font-style: italic;">
                      ...and {props.pendingFiles.length} pending items.
                    </li>
                  </Show>
                </Show>
              </ul>
            </div>
          </div>
        </main>
      </div>
    </div>
  );
}
