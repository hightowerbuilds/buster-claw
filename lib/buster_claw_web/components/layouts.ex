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

  slot :inner_block, required: true

  def app(assigns) do
    if BusterClawWeb.ChromeHook.embedded?() do
      bare(assigns)
    else
      shell(assigns)
    end
  end

  # A split pane: render only the view's content, no tab strip / dock / flash.
  defp bare(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100">
      <div class="space-y-4 p-4 sm:p-6">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  defp shell(assigns) do
    assigns =
      assigns
      |> assign(:runtime, BusterClaw.Runtime.Status.snapshot())
      |> assign(:agent_mode_on?, BusterClaw.AgentMode.on?())
      |> assign(:nav_items, navigation_items())
      |> assign(:tab_labels, Jason.encode!(tab_labels()))

    ~H"""
    <div id="app-shell" class="flex min-h-screen flex-col">
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

        <div class="border-b border-base-300 bg-base-100/95 px-4 py-2 backdrop-blur sm:px-6 lg:px-8">
          <div class="mx-auto flex max-w-7xl items-center justify-end gap-2 text-xs">
            <span
              :if={@agent_mode_on?}
              class="inline-flex items-center gap-2 rounded-full border border-success/40 bg-success/10 px-3 py-1 font-semibold text-success"
            >
              <span class="size-2 rounded-full bg-success" /> Agent mode on
            </span>
            <.runtime_chip label="PubSub" value={@runtime.pubsub} ok?={true} />
            <.runtime_chip label="Endpoint" value={@runtime.endpoint} ok?={true} />
          </div>
        </div>
      </header>

      <main class="min-w-0 flex-1">
        <div class="mx-auto max-w-7xl space-y-4 px-4 py-8 sm:px-6 lg:px-8">
          {render_slot(@inner_block)}
        </div>
      </main>

      <%!-- The former sidebar, now a dock across the bottom of the window. --%>
      <footer
        id="app-dock"
        class="sticky bottom-0 z-30 flex items-center gap-2 overflow-x-auto border-t border-base-300 bg-base-100/95 px-3 py-2 backdrop-blur"
      >
        <a href="/" title="Buster Claw" class="flex shrink-0 items-center">
          <div class="grid size-8 shrink-0 place-items-center rounded bg-base-content text-xs font-semibold text-base-100">
            BC
          </div>
        </a>

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

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :ok?, :boolean, required: true

  defp runtime_chip(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2 rounded-full border border-base-300 bg-base-100 px-3 py-1">
      <span class="font-semibold uppercase tracking-wide text-base-content/60">{@label}</span>
      <span class="font-mono text-base-content/80">{@value}</span>
      <span class={[
        "rounded-full px-2 py-0.5 font-semibold",
        if(@ok?, do: "bg-success/15 text-success", else: "bg-warning/15 text-warning")
      ]}>
        {if @ok?, do: "ready", else: "pending"}
      </span>
    </span>
    """
  end

  defp navigation_items do
    [
      %{label: "Home", path: "/", icon: "hero-home"},
      %{label: "Chat", path: "/chat", icon: "hero-chat-bubble-left-right"},
      %{label: "Documents", path: "/documents", icon: "hero-document-text"},
      %{label: "Browse", path: "/browse", icon: "hero-globe-alt"},
      %{label: "Calendar", path: "/calendar", icon: "hero-calendar-days"},
      %{label: "GWS", path: "/gws", icon: "hero-envelope"},
      %{label: "Memory", path: "/memory", icon: "hero-circle-stack"},
      %{label: "Scheduler", path: "/scheduler", icon: "hero-clock"},
      %{label: "Advanced", path: "/advanced", icon: "hero-adjustments-horizontal"}
    ]
  end

  # Path -> tab label for every route a tab can open, including routes reachable
  # via in-page tabs (Library/Advanced) rather than the dock. Serialized into
  # the tab strip for the client-side TabStrip hook to label tabs.
  defp tab_labels do
    base = Map.new(navigation_items(), &{&1.path, &1.label})

    Map.merge(base, %{
      "/sources" => "Sources",
      "/analysis" => "Analysis",
      "/delivery" => "Delivery",
      "/hooks" => "Hooks",
      "/webhooks" => "Webhooks",
      "/integrations" => "Integrations",
      "/mcp" => "MCP"
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
