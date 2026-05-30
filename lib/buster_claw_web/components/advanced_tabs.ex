defmodule BusterClawWeb.AdvancedTabs do
  use BusterClawWeb, :html

  @tabs [
    %{key: :delivery, label: "Delivery", path: "/advanced"},
    %{key: :hooks, label: "Hooks", path: "/hooks"},
    %{key: :webhooks, label: "Webhooks", path: "/webhooks"},
    %{key: :integrations, label: "Integrations", path: "/integrations"},
    %{key: :mcp, label: "MCP", path: "/mcp"},
    %{key: :runtime, label: "Runtime", path: "/runtime"}
  ]

  attr :active, :atom, required: true

  def tabs(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <nav
      id="advanced-tabs"
      aria-label="Advanced sections"
      class="flex gap-2 overflow-x-auto rounded-lg border border-base-300 bg-base-100 p-1"
    >
      <.link
        :for={tab <- @tabs}
        id={"advanced-tab-#{tab.key}"}
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
    """
  end
end
