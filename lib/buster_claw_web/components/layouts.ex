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
    assigns =
      assigns
      |> assign(:runtime, BusterClaw.Runtime.Status.snapshot())
      |> assign(:agent_mode_on?, BusterClaw.AgentMode.on?())

    ~H"""
    <div class="flex min-h-screen">
      <aside class="sticky top-0 flex h-screen w-60 shrink-0 flex-col border-r border-base-300 bg-base-100/95">
        <a
          href="/"
          class="flex shrink-0 items-center gap-3 border-b border-base-300 px-4 py-4"
        >
          <div class="grid size-9 place-items-center rounded bg-base-content text-base-100">
            BC
          </div>
          <div class="min-w-0">
            <div class="truncate text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Elixir Rewrite
            </div>
            <div class="truncate text-base font-semibold">Buster Claw</div>
          </div>
        </a>

        <nav class="flex flex-1 flex-col gap-1 overflow-y-auto p-3 text-sm">
          <a
            :for={item <- navigation_items()}
            href={item.path}
            class="rounded px-3 py-2 hover:bg-base-200"
          >
            {item.label}
          </a>
        </nav>

        <div class="shrink-0 border-t border-base-300 p-3">
          <.theme_toggle />
        </div>
      </aside>

      <main class="min-w-0 flex-1">
        <div class="sticky top-0 z-10 border-b border-base-300 bg-base-100/95 px-4 py-2 backdrop-blur sm:px-6 lg:px-8">
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

        <div class="mx-auto max-w-7xl space-y-4 px-4 py-8 sm:px-6 lg:px-8">
          {render_slot(@inner_block)}
        </div>
      </main>
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
      %{label: "Home", path: "/"},
      %{label: "Chat", path: "/chat"},
      %{label: "Sources", path: "/sources"},
      %{label: "Documents", path: "/documents"},
      %{label: "Analysis", path: "/analysis"},
      %{label: "Calendar", path: "/calendar"},
      %{label: "GWS", path: "/gws"},
      %{label: "Memory", path: "/memory"},
      %{label: "Scheduler", path: "/scheduler"},
      %{label: "Advanced", path: "/advanced"}
    ]
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
