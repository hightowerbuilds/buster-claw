defmodule BusterClawWeb.Workbench do
  @moduledoc "The work-area menu and stable panel frames. Panes never move in the DOM."
  use BusterClawWeb, :html
  alias BusterClawWeb.WorkbenchState, as: State

  attr :state, :map, required: true
  attr :mounted, :any, required: true
  attr :terminals, :any, required: true
  slot :terminal, required: true

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
        data-state={Jason.encode!(@state)}
        hidden
      >
      </div>
      <div class="ic-workbench-main">
        <p id="workbench-notice" class="ic-workbench-notice" role="status" phx-update="ignore" hidden>
        </p>
        <%!-- The Workbench hook lays the panes out with inline custom
              properties (and marks a narrow canvas `data-stacked`). The server
              renders neither, so without these, any patch — a chat token, a
              clock tick — stripped the geometry and every open pane fell back
              to the full canvas, the last one in DOM order on top. --%>
        <div
          id="workbench-canvas"
          class="ic-workbench-canvas"
          phx-mounted={JS.ignore_attributes(["data-stacked", "data-mode"])}
        >
          <BusterClawWeb.WorkbenchPane.pane
            :for={panel <- @panel}
            id={"workbench-pane-#{panel.key}"}
            key={panel.key}
            state={@state}
            open={@open}
          >
            {MapSet.member?(@mounted, panel.key) && render_slot(panel)}
          </BusterClawWeb.WorkbenchPane.pane>
          <div id="workbench-terminals" phx-update="stream" class="contents">
            <BusterClawWeb.WorkbenchPane.pane
              :for={{id, terminal} <- @terminals}
              id={id}
              key={terminal.id}
              state={@state}
              open={@open}
            >
              {render_slot(@terminal, terminal.id)}
            </BusterClawWeb.WorkbenchPane.pane>
          </div>
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
      <div class="ic-workbench-modes" role="group" aria-label="Layout mode">
        <button
          :for={mode <- ["grid", "overlap"]}
          id={"workbench-mode-#{mode}"}
          type="button"
          data-workbench-mode={mode}
          aria-pressed="false"
          disabled
        >
          {String.capitalize(mode)}
        </button>
      </div>
      <div data-workbench-presets class="ic-workbench-presets">
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
      <button id="workbench-reset-positions" type="button" data-workbench-reset hidden>
        Reset positions
      </button>
      <span data-workbench-narrow-hint class="ic-workbench-layout-hint" hidden>
        Widen the work area to move panels.
      </span>
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
              click to the next terminal instance and paints the count. The
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
