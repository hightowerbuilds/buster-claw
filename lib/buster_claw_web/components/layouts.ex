defmodule BusterClawWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use BusterClawWeb, :html

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
      |> assign(:nav_items, navigation_items())
      |> assign(:tab_labels, Jason.encode!(tab_labels()))

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
      </header>

      <main class={[
        "flex min-w-0 flex-1 flex-col",
        @full_bleed && "min-h-0 overflow-hidden"
      ]}>
        <div class={[
          "flex w-full flex-1 flex-col",
          if(@full_bleed,
            do: "min-h-0",
            else: "mx-auto max-w-7xl space-y-4 px-4 py-8 sm:px-6 lg:px-8"
          )
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
          <.link
            :for={item <- @nav_items}
            navigate={item.path}
            title={item.label}
            class="flex shrink-0 items-center gap-2 rounded px-3 py-2 text-sm transition hover:bg-base-200"
          >
            <.icon name={item.icon} class="size-5 shrink-0 text-base-content/70" />
            <span class="hidden sm:inline">{item.label}</span>
          </.link>
        </nav>

        <div class="ml-auto shrink-0">
          <.theme_toggle />
        </div>
      </footer>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp navigation_items do
    [
      %{label: "Home", path: "/", icon: "hero-home"},
      %{label: "Orchestration", path: "/orchestration", icon: "hero-queue-list"},
      %{label: "Chat", path: "/chat", icon: "hero-chat-bubble-left-right"},
      %{label: "Workspace", path: "/workspace", icon: "hero-folder"},
      %{label: "Browser", path: "/browse", icon: "hero-globe-alt"},
      %{label: "Terminal", path: "/terminal", icon: "hero-command-line"},
      %{label: "Calendar", path: "/calendar", icon: "hero-calendar-days"},
      %{label: "Advanced", path: "/advanced", icon: "hero-adjustments-horizontal"},
      %{label: "Settings", path: "/settings", icon: "hero-cog-6-tooth"}
    ]
  end

  # Path -> tab label for every route a tab can open, including routes reachable
  # via in-page tabs (Library/Advanced) rather than the dock. Serialized into
  # the tab strip for the client-side TabStrip hook to label tabs.
  defp tab_labels do
    base = Map.new(navigation_items(), &{&1.path, &1.label})

    Map.merge(base, %{
      "/documents" => "Library",
      "/sources" => "Sources",
      "/analysis" => "Analysis",
      "/delivery" => "Delivery",
      "/hooks" => "Hooks",
      "/webhooks" => "Webhooks",
      "/integrations" => "Integrations",
      "/mcp" => "MCP",
      "/memory" => "Memory",
      "/scheduler" => "Scheduler",
      "/security" => "Security",
      "/gws" => "GWS",
      "/appearance" => "Settings",
      "/workspace" => "Workspace"
    })
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

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
