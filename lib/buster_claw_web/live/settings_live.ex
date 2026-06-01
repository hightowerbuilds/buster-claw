defmodule BusterClawWeb.SettingsLive do
  @moduledoc """
  Settings → Configuration sub-tab. Holds the profile, onboarding progress, and
  links out to the per-feature config surfaces. Sits alongside the Appearance
  sub-tab (see `BusterClawWeb.SettingsTabs` / `BusterClawWeb.AppearanceLive`).
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Delivery
  alias BusterClaw.Google
  alias BusterClaw.Hooks
  alias BusterClaw.Integrations
  alias BusterClaw.MCP
  alias BusterClaw.Scheduler
  alias BusterClaw.Setup
  alias BusterClaw.Webhooks

  @config_links [
    %{label: "Google Workspace", path: "/gws", icon: "hero-envelope", desc: "Gmail and Calendar"},
    %{
      label: "Integrations",
      path: "/integrations",
      icon: "hero-puzzle-piece",
      desc: "Sentry, GitHub, Umami"
    },
    %{
      label: "Delivery",
      path: "/delivery",
      icon: "hero-paper-airplane",
      desc: "Slack, email destinations"
    },
    %{
      label: "MCP",
      path: "/mcp",
      icon: "hero-server-stack",
      desc: "Model Context Protocol servers"
    },
    %{label: "Scheduler", path: "/scheduler", icon: "hero-clock", desc: "Recurring jobs"},
    %{label: "Hooks", path: "/hooks", icon: "hero-bolt", desc: "Shell and webhook hooks"},
    %{label: "Webhooks", path: "/webhooks", icon: "hero-link", desc: "Incoming triggers"},
    %{label: "Security", path: "/security", icon: "hero-shield-check", desc: "Audit feed"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:config_links, config_links_with_status())
     |> assign(:profile_name, Setup.profile_name())
     |> assign(:profile_org, Setup.profile_org())
     |> assign(:profile_note, nil)
     |> assign_status()}
  end

  @impl true
  def handle_event("save_profile", %{"name" => name, "org" => org}, socket) do
    Setup.put_profile(name, org)

    {:noreply,
     socket
     |> assign(:profile_name, String.trim(name))
     |> assign(:profile_org, String.trim(org))
     |> assign(:profile_note, "Saved.")
     |> assign_status()}
  end

  def handle_event("rerun_setup", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/setup")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="settings" class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:configuration} />

        <section class="ic-panel space-y-4 p-6">
          <h2 class="ic-eyebrow">Profile</h2>
          <form phx-submit="save_profile" class="grid gap-3 sm:grid-cols-2">
            <label class="block">
              <span class="ic-eyebrow">Your name</span>
              <input
                type="text"
                name="name"
                value={@profile_name}
                autocomplete="off"
                placeholder="Ada Lovelace"
                class="input mt-1 w-full"
              />
            </label>
            <label class="block">
              <span class="ic-eyebrow">Organization</span>
              <input
                type="text"
                name="org"
                value={@profile_org}
                autocomplete="off"
                placeholder="Analytical Engines Ltd."
                class="input mt-1 w-full"
              />
            </label>
            <button type="submit" class={["sm:col-span-2 sm:justify-self-start", button_outline()]}>
              Save profile
            </button>
          </form>
          <p
            :if={@profile_note}
            class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
          >
            {@profile_note}
          </p>
        </section>

        <section class="ic-panel space-y-4 p-6">
          <div class="flex items-center justify-between gap-4">
            <h2 class="ic-eyebrow">Setup progress</h2>
            <span class="font-mono text-xs text-base-content/60">
              {@status.completed} of {@status.total} complete
            </span>
          </div>
          <ul class="space-y-2 text-sm">
            <li :for={s <- @status.steps} class="flex items-center gap-2">
              <.icon
                name={if s.complete, do: "hero-check-circle-solid", else: "hero-minus-circle"}
                class={[
                  "size-5 shrink-0",
                  if(s.complete, do: "text-success", else: "text-base-content/40")
                ]}
              />
              <span class={if s.complete, do: "", else: "text-base-content/60"}>{s.label}</span>
            </li>
          </ul>
          <button type="button" phx-click="rerun_setup" class={button_outline()}>
            {if @status.complete?, do: "Re-run setup wizard", else: "Finish setup"}
          </button>
        </section>

        <section class="space-y-3">
          <h2 class="ic-eyebrow">Configure</h2>
          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <.link
              :for={link <- @config_links}
              navigate={link.path}
              class="ic-panel flex items-start gap-3 p-4 transition hover:bg-base-200"
            >
              <.icon name={link.icon} class="size-5 shrink-0 text-primary" />
              <span class="min-w-0">
                <span class="block font-display text-sm font-black uppercase tracking-tight">
                  {link.label}
                </span>
                <span class="block text-xs text-base-content/60">{link.desc}</span>
              </span>
              <.icon
                :if={link.done?}
                name="hero-check-circle-solid"
                class="ml-auto size-5 shrink-0 text-success"
              />
            </.link>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp assign_status(socket), do: assign(socket, :status, Setup.status())

  # Tag each Configure card with whether that surface has anything set up yet.
  defp config_links_with_status do
    Enum.map(@config_links, &Map.put(&1, :done?, config_done?(&1.path)))
  end

  defp config_done?("/gws"), do: Google.list_account_summaries() != []
  defp config_done?("/integrations"), do: Integrations.list_integrations() != []
  defp config_done?("/delivery"), do: Delivery.list_destinations() != []
  defp config_done?("/mcp"), do: MCP.list_servers() != []
  defp config_done?("/scheduler"), do: Scheduler.list_jobs() != []
  defp config_done?("/hooks"), do: Hooks.list_hooks() != []
  defp config_done?("/webhooks"), do: Webhooks.list_webhooks() != []
  defp config_done?(_path), do: false

  defp button_outline,
    do:
      "rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:bg-base-200"
end
