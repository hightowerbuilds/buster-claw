defmodule BusterClawWeb.DockNavLive do
  @moduledoc """
  The dock's tab nav — Home, Workspace, Browser, Terminal, Settings.

  Mounted `sticky: true` inside `Layouts.app`, its own process, exactly like
  `DockLive` beside it.

  ## Why this is a LiveView and not markup in the layout

  It *was* markup in the layout, and that is precisely why brand art appeared not
  to work. **A Phoenix app layout is rendered once at mount and is never part of
  a later diff.** So an operator who swapped a dock icon in the Pockets tab saw
  the Pockets row update, saw the homepage banner update — that one is in
  `StatusLive`'s own template — and saw the dock keep the old icon until they
  navigated. The art had swapped; the dock simply could not say so.

  A nested LiveView has its own process and its own diff, so it can subscribe to
  `BusterClaw.Pockets.Brand.topic/0` and re-render itself in place. `DockLive`
  already existed for the same class of reason (a timer set on the homepage has
  to stay visible from /terminal), so this is the pattern rather than a new one.

  Display-only: the links navigate and the Terminal button is a JS hook. Nothing
  here holds state worth losing, which is what makes `sticky: true` safe.
  """
  use BusterClawWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    # No subscribe and no `handle_info` here on purpose: `BusterClawWeb.ChromeHook`
    # runs for every LiveView including this one, subscribes once, and assigns
    # `@nav_items`. It `:halt`s the message, so a clause here would never fire —
    # a second subscription would be a second source of truth that looks like it
    # works.
    {:ok, socket, layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="bc-dock-nav-root" class="contents">
      <BusterClawWeb.Layouts.dock_nav items={@nav_items} />
    </div>
    """
  end
end
