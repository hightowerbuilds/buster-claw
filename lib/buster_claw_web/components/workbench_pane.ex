defmodule BusterClawWeb.WorkbenchPane do
  @moduledoc "A stable panel frame shared by singleton content and streamed terminals."
  use BusterClawWeb, :html
  alias BusterClawWeb.WorkbenchState, as: State

  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :state, :map, required: true
  attr :open, :any, required: true
  slot :inner_block, required: true

  def pane(assigns) do
    ~H"""
    <section
      id={@id}
      data-workbench-pane={@key}
      data-active={to_string(@state.active == @key)}
      phx-mounted={JS.ignore_attributes(["style", "class"])}
      aria-labelledby={"workbench-title-#{@key}"}
      hidden={
        not MapSet.member?(@open, @key) or
          (@state.zoom != nil and @state.zoom != @key)
      }
      class="ic-workbench-pane"
    >
      <header class="ic-workbench-pane-header">
        <span class="ic-workbench-pane-mark" aria-hidden="true"></span>
        <h2
          id={"workbench-title-#{@key}"}
          tabindex="0"
          aria-label={"#{State.label(@key)}. In Overlap, use arrow keys to move, Enter to save, Escape to cancel."}
        >
          {State.label(@key)}
        </h2>
        <div class="ml-auto flex items-center gap-0.5">
          <button
            id={"workbench-zoom-#{@key}"}
            type="button"
            phx-click="workbench_zoom"
            phx-value-key={@key}
            aria-label={
              if(@state.zoom == @key,
                do: "Restore panels",
                else: "Maximize #{State.label(@key)}"
              )
            }
            title={if(@state.zoom == @key, do: "Restore panels", else: "Maximize panel")}
            class="ic-workbench-pane-action"
          >
            <.icon
              name={
                if(@state.zoom == @key,
                  do: "hero-arrows-pointing-in",
                  else: "hero-arrows-pointing-out"
                )
              }
              class="size-3.5"
            />
          </button>
          <%!-- A terminal's × CLOSES its shell (TERMINAL_PANELS D4), so the
                      Workbench hook owns that click: busy check, confirm, end the
                      PTY, then `workbench_close`. Every other pane just hides. --%>
          <button
            :if={State.terminal_slot?(@key)}
            id={"workbench-close-#{@key}"}
            type="button"
            data-workbench-close-terminal={@key}
            aria-label={"Close #{State.label(@key)}"}
            title="Close terminal"
            class="ic-workbench-pane-action"
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
          <button
            :if={not State.terminal_slot?(@key)}
            id={"workbench-close-#{@key}"}
            type="button"
            phx-click="workbench_close"
            phx-value-key={@key}
            aria-label={"Hide #{State.label(@key)}"}
            title="Hide panel"
            class="ic-workbench-pane-action"
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </div>
      </header>
      <div class="ic-workbench-pane-body">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end
end
