defmodule BusterClawWeb.Browser.ActivityGraph do
  @moduledoc "The browser's live graph; its hook owns the bounded SVG projection."
  use BusterClawWeb, :html

  attr :id, :string, required: true

  def graph(assigns) do
    ~H"""
    <section
      id={@id}
      class="ic-activity"
      phx-hook="BrowserActivity"
      phx-update="ignore"
      data-endpoint={~p"/browser/activity/events"}
      aria-label="Agent browser activity graph"
    >
      <header class="ic-activity-header">
        <div>
          <p class="ic-activity-eyebrow">THE AGENT'S PATH</p>
          <h2>Browser activity <span data-count>0</span></h2>
        </div>
        <div class="ic-activity-header-actions">
          <button id={@id <> "-live"} type="button" data-action="live" aria-pressed="true">
            <span class="ic-activity-dot"></span><span data-live-label>Live</span>
          </button>
          <button
            id={@id <> "-close"}
            type="button"
            class="ic-activity-close"
            phx-click="close_activity"
            aria-label="Hide activity graph"
            title="Hide activity graph"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </header>

      <div class="ic-activity-filters">
        <.input
          id={@id <> "-source"}
          name="source"
          type="select"
          value=""
          options={[
            {"All browser activity", ""},
            {"Shared browser", "shared"},
            {"Agent Mode", "agent"}
          ]}
          class="ic-activity-select"
          aria-label="Activity source"
          data-source
        />
        <.input
          id={@id <> "-run"}
          name="run"
          type="select"
          value=""
          options={[{"All runs", ""}]}
          class="ic-activity-select"
          aria-label="Agent run"
          data-run
        />
        <span class="ic-activity-status" data-status role="status">Connecting…</span>
      </div>

      <div class="ic-activity-canvas">
        <svg data-graph aria-label="Pages connected by agent actions" role="group">
          <defs>
            <marker
              id={@id <> "-arrow"}
              viewBox="0 0 10 10"
              refX="9"
              refY="5"
              markerWidth="5"
              markerHeight="5"
              orient="auto-start-reverse"
            >
              <path d="M 0 0 L 10 5 L 0 10 z" fill="currentColor" />
            </marker>
          </defs>
          <g data-scene></g>
        </svg>
        <div class="ic-activity-empty" data-empty>
          <.icon name="hero-share" class="size-8" />
          <h3>The next move starts here.</h3>
          <p>As the agent visits pages, reads, clicks, and fills fields, its path appears here.</p>
          <span>Shared browser + Agent Mode</span>
        </div>
        <div class="ic-activity-tools" aria-label="Graph controls">
          <button id={@id <> "-follow"} type="button" data-action="follow" aria-pressed="true">
            Follow
          </button>
          <button id={@id <> "-zoom-out"} type="button" data-action="zoom-out" aria-label="Zoom out">
            <.icon name="hero-minus" class="size-4" />
          </button>
          <span data-zoom>100%</span>
          <button id={@id <> "-zoom-in"} type="button" data-action="zoom-in" aria-label="Zoom in">
            <.icon name="hero-plus" class="size-4" />
          </button>
          <button id={@id <> "-fit"} type="button" data-action="fit">Fit</button>
        </div>
        <div class="ic-activity-legend"><i></i> Page <i></i> Action <i></i> Stopped / error</div>
      </div>

      <footer class="ic-activity-inspector" data-inspector>
        <p class="ic-activity-eyebrow">INSPECT A STEP</p>
        <p>Select an action to see its page, outcome, and time.</p>
      </footer>
    </section>
    """
  end
end
