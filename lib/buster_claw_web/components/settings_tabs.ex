defmodule BusterClawWeb.SettingsTabs do
  use BusterClawWeb, :html

  @tabs [
    %{key: :get_started, label: "Get Started", path: "/get-started"},
    %{key: :appearance, label: "Appearance", path: "/appearance"},
    %{key: :voice, label: "Voice", path: "/voice"},
    %{key: :gws, label: "GWS", path: "/gws"},
    %{key: :integrations, label: "Integrations", path: "/integrations"},
    %{key: :configuration, label: "Configuration", path: "/settings"},
    %{key: :security, label: "Security", path: "/security"}
  ]

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
