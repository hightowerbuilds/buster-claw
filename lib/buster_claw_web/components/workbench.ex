defmodule BusterClawWeb.Workbench do
  @moduledoc "The work-area menu and stable panel frames. Panes never move in the DOM."
  use BusterClawWeb, :html
  alias BusterClawWeb.WorkbenchState, as: State

  attr :state, :map, required: true
  attr :mounted, :any, required: true

  slot :panel, required: true do
    attr :key, :string, required: true
  end

  def shell(assigns) do
    assigns =
      assigns
      |> assign(:open, MapSet.new(State.leaves(assigns.state.tree)))

    ~H"""
    <section id="workbench" class="ic-workbench" aria-label="Work area">
      <div
        id="workbench-controller"
        phx-hook="Workbench"
        phx-update="ignore"
        data-state={Jason.encode!(State.payload(@state))}
        hidden
      >
      </div>
      <div class="ic-workbench-main">
        <div id="workbench-canvas" class="ic-workbench-canvas">
          <section
            :for={panel <- @panel}
            id={"workbench-pane-#{panel.key}"}
            data-workbench-pane={panel.key}
            data-active={to_string(@state.active == panel.key)}
            aria-labelledby={"workbench-title-#{panel.key}"}
            hidden={
              not MapSet.member?(@open, panel.key) or
                (@state.zoom != nil and @state.zoom != panel.key)
            }
            class="ic-workbench-pane"
          >
            <header class="ic-workbench-pane-header">
              <span class="ic-workbench-pane-mark" aria-hidden="true"></span>
              <h2 id={"workbench-title-#{panel.key}"} tabindex="-1">{State.label(panel.key)}</h2>
              <div class="ml-auto flex items-center gap-0.5">
                <button
                  id={"workbench-zoom-#{panel.key}"}
                  type="button"
                  phx-click="workbench_zoom"
                  phx-value-key={panel.key}
                  aria-label={
                    if(@state.zoom == panel.key,
                      do: "Restore panels",
                      else: "Maximize #{State.label(panel.key)}"
                    )
                  }
                  title={if(@state.zoom == panel.key, do: "Restore panels", else: "Maximize panel")}
                  class="ic-workbench-pane-action"
                >
                  <.icon
                    name={
                      if(@state.zoom == panel.key,
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
                  :if={State.terminal_slot?(panel.key)}
                  id={"workbench-close-#{panel.key}"}
                  type="button"
                  data-workbench-close-terminal={panel.key}
                  aria-label={"Close #{State.label(panel.key)}"}
                  title="Close terminal"
                  class="ic-workbench-pane-action"
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
                <button
                  :if={not State.terminal_slot?(panel.key)}
                  id={"workbench-close-#{panel.key}"}
                  type="button"
                  phx-click="workbench_close"
                  phx-value-key={panel.key}
                  aria-label={"Hide #{State.label(panel.key)}"}
                  title="Hide panel"
                  class="ic-workbench-pane-action"
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </div>
            </header>
            <div class="ic-workbench-pane-body">
              {MapSet.member?(@mounted, panel.key) && render_slot(panel)}
            </div>
          </section>
          <div id="workbench-dividers" phx-update="ignore"></div>
          <div :if={MapSet.size(@open) == 0} id="workbench-empty" class="ic-workbench-empty">
            <.icon name="hero-view-columns" class="size-8 text-primary/65" />
            <h2>Your space, your arrangement.</h2>
            <p>Choose a panel from the menu to start working.</p>
            <button
              id="workbench-start-chat"
              type="button"
              phx-click="select_home_tab"
              phx-value-tab="chat"
              class="ic-workbench-start"
            >
              Open Chat <.icon name="hero-arrow-right" class="size-3.5" />
            </button>
          </div>
        </div>
      </div>
    </section>
    """
  end

  def layout_picker(assigns) do
    ~H"""
    <div
      id="workbench-layout-picker"
      phx-update="ignore"
      data-layouts={Jason.encode!(State.payload(State.new()).layouts)}
      class="ic-workbench-layouts"
      role="group"
      aria-label="Panel arrangement"
    >
      <button
        :for={layout <- State.payload(State.new()).layouts}
        id={"workbench-layout-#{layout.key}"}
        type="button"
        data-workbench-layout={layout.key}
        aria-label={layout.label}
        aria-pressed="false"
        title={layout.label}
        disabled
        class="ic-workbench-layout"
      >
        <span class="ic-workbench-layout-dots" aria-hidden="true"></span>
      </button>
    </div>
    """
  end

  attr :banner_url, :string, default: nil
  attr :nav_items, :list, default: []

  def menu(assigns) do
    assigns = assign(assigns, :panels, State.panels())

    ~H"""
    <div id="workbench-menu" class="ic-workbench-menu-content">
      <div id="workbench-menu-controller" phx-hook="WorkbenchMenu" phx-update="ignore" hidden></div>
      <div class="ic-workbench-brand">
        <BusterClawWeb.BrandArt.banner url={@banner_url} />
        <span class="ic-eyebrow">Your work area</span>
      </div>
      <nav class="ic-workbench-launcher" aria-label="Panels">
        <%!-- Terminal always CREATES (TERMINAL_PANELS D3): the hook routes the
              click to the next free slot, up to four, and paints the count. The
              href is the fallback — and the deep link, which only ensures one. --%>
        <.link
          :for={panel <- @panels}
          id={"home-tab-#{panel.key}"}
          navigate={"/?panel=#{panel.key}"}
          data-workbench-open={panel.key}
          data-workbench-terminal-new={State.terminal_slot?(panel.key) && "true"}
          data-active="false"
          class="ic-workbench-menu-button"
        >
          <.icon name={panel.icon} class="size-4 shrink-0" />
          <span>{panel.label}</span>
          <span
            :if={State.terminal_slot?(panel.key)}
            class="ic-workbench-count"
            data-workbench-terminal-count
            aria-live="polite"
            hidden
          >
          </span>
          <span class="ic-workbench-open-dot" aria-hidden="true" hidden></span>
        </.link>
      </nav>
      <nav class="ic-workbench-destinations" aria-label="Separate tabs">
        <span class="ic-eyebrow">Separate tabs</span>
        <.link
          :for={item <- @nav_items}
          id={"workbench-#{String.downcase(item.label)}"}
          navigate={item.path}
          class="ic-workbench-menu-button"
        >
          <img :if={item.image} src={item.image} alt="" class="size-4 shrink-0 object-contain" />
          <.icon :if={!item.image} name={item.icon} class="size-4" />
          <span>{item.label}</span>
          <.icon name="hero-arrow-up-right" class="ml-auto size-3 text-base-content/35" />
        </.link>
      </nav>
    </div>
    """
  end
end
