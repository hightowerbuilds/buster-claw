defmodule BusterClawWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use BusterClawWeb, :html

  @navigation_items [
    %{label: "Home", path: "/", icon: "hero-home", image: "/images/brand/home-icon.png"},
    %{
      label: "Workspace",
      path: "/workspace",
      icon: "hero-folder",
      image: "/images/brand/workspace-icon.png"
    },
    %{
      label: "Browser",
      path: "/browse",
      icon: "hero-globe-alt",
      image: "/images/brand/browser-icon.png"
    },
    %{
      label: "Terminal",
      path: "/terminal",
      icon: "hero-command-line",
      image: "/images/brand/terminal-icon.png",
      # Opens a NEW shell every click (fresh session key + tab), like Cmd-T —
      # a plain /terminal navigation would reattach to the shared "main" shell.
      new_terminal: true
    },
    # Calendar is no longer a dock tab — it lives on the Home page as a sub-tab
    # (see StatusLive). The /calendar route still exists (deep links + SplitLive
    # split pane), so its tab-strip label is preserved in @tab_labels below.
    # No brand PNG yet — the dock falls back to the text label (see render below).
    %{
      label: "Phone",
      path: "/phone",
      icon: "hero-phone"
    },
    %{
      label: "Wallets",
      path: "/wallets",
      icon: "hero-wallet"
    },
    %{
      label: "Settings",
      path: "/appearance",
      icon: "hero-cog-6-tooth",
      image: "/images/brand/settings-icon.png"
    }
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
                  "/calendar" => "Calendar",
                  "/integrations" => "Integrations",
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
  defp bare(assigns) do
    ~H"""
    <div class="flex h-full min-h-0 flex-col bg-base-100">{render_slot(@inner_block)}</div>
    """
  end

  defp shell(assigns) do
    assigns =
      assigns
      |> assign(:nav_items, @navigation_items)
      |> assign(:tab_labels, @tab_labels_json)

    ~H"""
    <div
      id="app-shell"
      class={[
        "flex flex-col",
        if(@full_bleed, do: "h-screen overflow-hidden", else: "min-h-screen")
      ]}
    >
      <header class="sticky top-0 z-30">
        <%!-- Browser-style tab strip; populated client-side by the TabStrip hook. --%>
        <div
          id="tab-strip"
          phx-hook="TabStrip"
          phx-update="ignore"
          data-labels={@tab_labels}
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
      </header>

      <main class={[
        "flex min-w-0 flex-1 flex-col",
        @full_bleed && "min-h-0 overflow-hidden"
      ]}>
        <div class={[
          "flex w-full flex-1 flex-col",
          cond do
            @full_bleed -> "min-h-0"
            @wide -> "space-y-4 px-4 py-8 sm:px-6 lg:px-8"
            true -> "mx-auto max-w-7xl space-y-4 px-4 py-8 sm:px-6 lg:px-8"
          end
        ]}>
          {render_slot(@inner_block)}
        </div>
      </main>

      <%!-- The former sidebar, now a dock across the bottom of the window. --%>
      <footer
        id="app-dock"
        class="sticky bottom-0 z-30 flex items-center gap-2 overflow-x-auto border-t border-base-300 bg-base-100/95 px-3 py-2 backdrop-blur"
      >
        <nav class="flex items-center gap-1" aria-label="Open a tab">
          <div :for={item <- @nav_items} class="contents">
            <%!-- Terminal opens a fresh shell per click via JS (see the marker
            on @navigation_items); everything else is a normal tab navigation. --%>
            <button
              :if={item[:new_terminal]}
              type="button"
              id="dock-new-terminal"
              phx-hook="DockNewTerminal"
              title={item.label}
              class="flex shrink-0 items-center gap-2 rounded px-3 py-2 text-sm transition hover:bg-base-200"
            >
              <img :if={item[:image]} src={item[:image]} alt={item.label} class="h-6 w-auto shrink-0" />
              <span :if={!item[:image]} class="font-medium">{item.label}</span>
            </button>
            <.link
              :if={!item[:new_terminal]}
              navigate={item.path}
              title={item.label}
              class="flex shrink-0 items-center gap-2 rounded px-3 py-2 text-sm transition hover:bg-base-200"
            >
              <img :if={item[:image]} src={item[:image]} alt={item.label} class="h-6 w-auto shrink-0" />
              <span :if={!item[:image]} class="font-medium">{item.label}</span>
            </.link>
          </div>
        </nav>

        <%!-- Right side: the sticky status widget (upcoming alarms/timers/
              reminders + temperature + clock). A separate LiveView process
              (sticky), so it survives page navigation — armed notifications
              stay visible even with the homepage closed. --%>
        <div class="ml-auto shrink-0">
          {@socket && live_render(@socket, BusterClawWeb.DockLive, id: "bc-dock", sticky: true)}
        </div>
      </footer>
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
