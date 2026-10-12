defmodule BusterClawWeb.SettingsTabs do
  @moduledoc """
  The Settings section's shared header: the wordmark and the nav bar of links to
  each settings sub-tab (Appearance, Notify, Integrations, Configuration,
  Security), with the active one highlighted. (Get Started's 3-step
  onboarding moved to the home Explained tab's Intro, 08-02.)

  Native read-aloud controls live under Configuration → Speech. The legacy
  `/voice` route redirects there, so it needs no separate rail entry.
  """
  use BusterClawWeb, :html

  @tabs [
    %{key: :appearance, label: "Appearance", path: "/appearance"},
    %{key: :notify, label: "Notify", path: "/notify-settings"},
    %{key: :integrations, label: "Integrations", path: "/integrations"},
    %{key: :configuration, label: "Configuration", path: "/settings"},
    %{key: :security, label: "Security", path: "/security"}
  ]

  @doc """
  Every settings sub-tab path, in display order.

  The tab strip's JS has to know this same set — a sub-tab it doesn't recognize
  opens its own top-level tab instead of staying inside Settings. Exposed so
  `BusterClawWeb.SettingsTabsTest` can hold the two in lockstep.
  """
  def paths, do: Enum.map(@tabs, & &1.path)

  attr :active, :atom, required: true
  attr :id_prefix, :string, default: ""

  def tabs(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <div class="space-y-4">
      <.page_wordmark src={~p"/images/brand/settings-icon.png"} alt="Settings" />
      <nav
        id={"#{@id_prefix}settings-tabs"}
        aria-label="Settings sections"
        class="flex gap-2 overflow-x-auto rounded-lg border border-base-300 bg-base-100 p-1"
      >
        <.link
          :for={tab <- @tabs}
          id={"#{@id_prefix}settings-tab-#{tab.key}"}
          navigate={tab.path}
          class={[
            "whitespace-nowrap rounded px-4 py-2 text-sm font-semibold transition",
            if(@active == tab.key,
              do: "bg-base-content text-base-100",
              else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
            )
          ]}
        >
          {tab.label}
        </.link>
      </nav>
    </div>
    """
  end
end
