defmodule BusterClawWeb.SettingsTabs do
  @moduledoc """
  The Settings section's shared header: the wordmark and the nav bar of links to
  each settings sub-tab (Appearance, Notify, Integrations, Configuration,
  Cmd List, Security), with the active one highlighted. (Get Started's 3-step
  onboarding moved to the home Explained tab's Intro, 08-02.)

  **Voice left this rail on 09-05**, when the whole surface became the homepage's
  Vox2B sub-tab (`VOX_TAB_ROADMAP`). The `/voice` route still exists for deep
  links and split panes, exactly as `/calendar` and `/phone` do — but it is no
  longer a *settings* page, so it is neither listed here nor grouped under the
  Settings tab in the strip. Its tab-strip label moved to `Layouts`'s
  `@tab_labels` for that reason.
  """
  use BusterClawWeb, :html

  @tabs [
    %{key: :appearance, label: "Appearance", path: "/appearance"},
    %{key: :notify, label: "Notify", path: "/notify-settings"},
    %{key: :integrations, label: "Integrations", path: "/integrations"},
    %{key: :configuration, label: "Configuration", path: "/settings"},
    %{key: :cmd_list, label: "Cmd List", path: "/cmd-list"},
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

  def tabs(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <div class="space-y-4">
      <.page_wordmark src={~p"/images/brand/settings-icon.png"} alt="Settings" />
      <nav
        id="settings-tabs"
        aria-label="Settings sections"
        class="flex gap-2 overflow-x-auto rounded-lg border border-base-300 bg-base-100 p-1"
      >
        <.link
          :for={tab <- @tabs}
          id={"settings-tab-#{tab.key}"}
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
