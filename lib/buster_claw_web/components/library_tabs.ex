defmodule BusterClawWeb.LibraryTabs do
  use BusterClawWeb, :html

  @tabs [
    %{key: :documents, label: "Library", path: "/documents"},
    %{key: :sources, label: "Sources", path: "/sources"},
    %{key: :analysis, label: "Analysis", path: "/analysis"}
  ]

  attr :active, :atom, required: true

  def tabs(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <nav
      id="library-tabs"
      aria-label="Library sections"
      class="flex gap-2 overflow-x-auto rounded-lg border border-base-300 bg-base-100 p-1"
    >
      <.link
        :for={tab <- @tabs}
        id={"library-tab-#{tab.key}"}
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
