import { For } from "solid-js";
import { navigationItems, type View } from "../app/navigation";
import type { OrchestratorStatus } from "../wails.d";

type SidebarProps = {
  activeView: View;
  status: OrchestratorStatus;
  onSwitchView: (view: View) => void;
  onClearChat: () => void;
};

export function Sidebar(props: SidebarProps) {
  const activeWorkerCount = () => props.status.activeJobs.length > 1 ? props.status.activeJobs.length : (props.status.activeJob ? 1 : 0);

  return (
    <div class="sidebar">
      <div class="sidebar-section">
        <h3>Navigate</h3>
        <For each={navigationItems}>
          {(item) => (
            <button
              class="sidebar-btn"
              classList={{ "sidebar-btn-active": props.activeView === item.view }}
              onClick={() => props.onSwitchView(item.view)}
            >
              {item.label}
            </button>
          )}
        </For>
      </div>

      <div class="sidebar-section">
        <h3>Status</h3>
        <div class="status-card">
          <div class="label">Phase</div>
          <div class="value" classList={{ active: props.status.phase !== "idle" }}>{props.status.phase || "idle"}</div>
        </div>
        <div class="status-card" style="margin-top: 6px">
          <div class="label">Completed / Failed</div>
          <div class="value">{props.status.completedJobs} / {props.status.failedJobs}</div>
        </div>
        <div class="status-card" style="margin-top: 6px">
          <div class="label">Parallel Workers</div>
          <div class="value">{activeWorkerCount()} active</div>
        </div>
        <For each={props.status.activeJobs}>
          {(job) => (
            <div class="status-card" style="margin-top: 6px">
              <div class="label">Active</div>
              <div class="value active">{job}</div>
            </div>
          )}
        </For>
      </div>

      <div class="sidebar-section">
        <h3>Actions</h3>
        <button class="sidebar-btn" onClick={props.onClearChat}>Clear Chat</button>
      </div>
    </div>
  );
}
