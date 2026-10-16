defmodule BusterClawWeb.DockNavLive do
  @moduledoc """
  The persistent sidebar menu. The original dock process now lives in the
  sidebar, preserving live brand updates across route changes.
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
      <BusterClawWeb.Workbench.menu banner_url={@banner_url} nav_items={@nav_items} />
    </div>
    """
  end
end
