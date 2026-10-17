defmodule BusterClawWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Pockets.Brand

  @navigation_items [
    %{label: "Browser", path: "/browse", icon: "hero-globe-alt", role: "nav_browser"},
    %{label: "Settings", path: "/appearance", icon: "hero-cog-6-tooth", role: "nav_settings"}
  ]

  # Path -> tab label for every route a tab can open, including routes reachable
  # via in-page tabs (e.g. Settings) rather than the dock. Serialized into the
  # tab strip for the client-side TabStrip hook to label tabs. The labels are a
  # compile-time constant, so the JSON is encoded once here rather than on every
  # `shell/1` render.
  @tab_labels Map.merge(
                Map.new(@navigation_items, &{&1.path, &1.label}),
                %{
                  # Reachable via the Home "Calendar" sub-tab and SplitLive, but
                  # no longer a dock item — label it here so the tab strip still
                  # names it when opened directly.
                  "/" => "Work area",
                  "/calendar" => "Calendar",
                  "/terminal" => "Terminal",
                  "/duty" => "On duty",
                  "/security" => "Security",
                  "/settings" => "Settings",
                  "/appearance" => "Settings",
                  "/workspace" => "Workspace",
                  "/manual" => "Manual"
                }
              )

  @tab_labels_json Jason.encode!(@tab_labels)

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :full_bleed, :boolean,
    default: false,
    doc: "drop the centered max-width/padding so content fills the window (e.g. split panes)"

  attr :wide, :boolean,
    default: false,
    doc:
      "drop only the centered max-width (keep padding + normal scroll) so content fills the window width"

  attr :fit_viewport, :boolean,
    default: false,
    doc:
      "clamp the shell to the window height (no page scroll) while keeping the centered max-width/padding — inner panes scroll themselves"

  attr :socket, :any,
    default: nil,
    doc:
      "the caller's LiveView socket — enables the sticky dock status widget (DockLive); pages that omit it just render the dock without the widget"

  slot :inner_block, required: true

  def app(assigns) do
    if BusterClawWeb.ChromeHook.embedded?() do
      bare(assigns)
    else
      shell(assigns)
    end
  end

  # A split pane: render only the view's content, no tab strip / dock / flash.
  # Full-bleed (no padding) so panes like the terminal can sit flush against the
  # pane partition; views that want breathing room add their own padding.
  #
  # No background of its own: the pane section in SplitLive decides whether it
  # is opaque, a veil, or transparent, and a `bg-base-100` here sat between that
  # decision and the split's shared shader, hiding it behind every pane (10-13).
  defp bare(assigns) do
    ~H"""
    <div class="flex h-full min-h-0 flex-col">{render_slot(@inner_block)}</div>
    """
  end

  # Resolve each dock item's art at render time, so an operator's own icon shows
  # the moment it lands and disappears the moment their Pocket goes over-full.
  #
  # `Brand.image_url/1` answers `nil` for a slot in error, and the markup below
  # already renders `item.label` when there is no image — that arm has existed
  # since Calendar shipped without a PNG. **The failure state is not new
  # behaviour; it is the behaviour that was already there.**
  @doc """
  The dock items with their art resolved now.

  Public because `BusterClawWeb.ChromeHook` assigns the result — the dock must
  update when an operator swaps an icon, and a value computed inside this
  module with no assign behind it is invisible to LiveView's change tracking.
  """
  def nav_items do
    Enum.map(@navigation_items, fn item ->
      Map.put(item, :image, Brand.image_url(item.role))
    end)
  end

  defp shell(assigns) do
    assigns =
      assigns
      |> assign(:tab_labels, @tab_labels_json)

    ~H"""
    <div
      id="app-shell"
      class="flex h-dvh flex-col overflow-hidden"
    >
      <header class="sticky top-0 z-30">
        {@socket &&
          live_render(@socket, BusterClawWeb.DutyTabLive, id: "bc-duty-tab", sticky: true)}
        <%!-- Browser-style tab strip; populated client-side by the TabStrip hook. --%>
        <div
          id="tab-strip"
          phx-hook="TabStrip"
          phx-update="ignore"
          data-labels={@tab_labels}
          data-joinable={Jason.encode!(BusterClawWeb.PaneRoutes.paths())}
          role="tablist"
          aria-label="Open tabs"
          class="flex min-h-9 items-end gap-1 overflow-x-auto border-b border-base-300 bg-base-200/80 px-2 pt-1 backdrop-blur"
        >
        </div>
        <%!-- Invisible bridge: invokes the Tauri browser_screenshot command when
             the agent requests a capture, then POSTs the PNG back. --%>
        <div id="screenshot-bridge" phx-hook="ScreenshotBridge" phx-update="ignore" hidden></div>
        <%!-- Invisible bridge: speaks assistant replies via the Tauri `speak`
             command when the server pushes "bc:speak" (gated on the Voice toggle). --%>
        <div id="voice-bridge" phx-hook="VoiceBridge" phx-update="ignore" hidden></div>
        <div id="app-icon-bridge" phx-hook="AppIconBridge" phx-update="ignore" hidden></div>
      </header>

      <div id="app-body" class="ic-app-body">
        <aside id="app-sidebar" class="ic-workbench-menu" aria-label="Application sidebar">
          {(@socket &&
              live_render(@socket, BusterClawWeb.DockNavLive, id: "bc-dock-nav", sticky: true)) ||
            BusterClawWeb.Workbench.menu(%{
              banner_url: Brand.image_url("home_banner"),
              nav_items: nav_items()
            })}
          <div id="sidebar-status" class="ic-sidebar-status">
            {@socket &&
              live_render(@socket, BusterClawWeb.DutyDockLive, id: "bc-duty-dock-live", sticky: true)}
            <BusterClawWeb.Workbench.layout_picker />
            {@socket && live_render(@socket, BusterClawWeb.DockLive, id: "bc-dock", sticky: true)}
          </div>
        </aside>
        <main class={[
          "flex min-h-0 min-w-0 flex-1 flex-col",
          if(@full_bleed or @fit_viewport, do: "overflow-hidden", else: "overflow-y-auto")
        ]}>
          <div class={[
            "flex w-full flex-1 flex-col",
            cond do
              @full_bleed -> "min-h-0"
              @fit_viewport -> "mx-auto min-h-0 max-w-7xl space-y-4 px-4 py-8 sm:px-6 lg:px-8"
              @wide -> "space-y-4 px-4 py-8 sm:px-6 lg:px-8"
              true -> "mx-auto max-w-7xl space-y-4 px-4 py-8 sm:px-6 lg:px-8"
            end
          ]}>
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
