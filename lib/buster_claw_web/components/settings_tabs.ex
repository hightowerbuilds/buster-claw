defmodule BusterClawWeb.SettingsTabs do
  @moduledoc """
  The Settings section's shared header: the wordmark and the nav bar of links to
  each settings tab, with the active one highlighted.

  Seven tabs, flat (10-17). Four of them — Agents & models, Google Workspace,
  Credentials, Speech — are one LiveView, `SettingsLive`, opened on a section
  by `?tab=`; they used to sit behind a "Configuration" tab with a rail of
  their own, and About, which sat on that rail, is a panel on Security now.
  The legacy `/voice` route redirects to Speech.
  """
  use BusterClawWeb, :html

  @tabs [
    %{key: :appearance, label: "Appearance", path: "/appearance"},
    %{key: :notify, label: "Notify", path: "/notify-settings"},
    %{key: :models, label: "Agents & models", path: "/settings?tab=models"},
    %{key: :google, label: "Google Workspace", path: "/settings?tab=google"},
    %{key: :credentials, label: "Credentials", path: "/settings?tab=credentials"},
    %{key: :speech, label: "Speech", path: "/settings?tab=speech"},
    %{key: :security, label: "Security", path: "/security"}
  ]

  @doc "The tabs, in display order: `%{key, label, path}`."
  def tabs, do: @tabs

  @doc """
  Every settings route PATH, in display order, deduplicated — the four
  `SettingsLive` tabs share `/settings` and differ by query.

  The tab strip's JS has to know this same set — a route it doesn't recognize
  opens its own top-level tab instead of staying inside Settings, and it groups
  by `location.pathname`, so the query is not its business. Exposed so
  `BusterClawWeb.SettingsTabsTest` can hold the two in lockstep.
  """
  def paths, do: @tabs |> Enum.map(&(&1.path |> String.split("?") |> hd())) |> Enum.uniq()

  attr :active, :any, required: true, doc: "the active tab's key, as an atom or its string"
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
          aria-current={active?(@active, tab.key) && "page"}
          class={[
            "whitespace-nowrap rounded px-4 py-2 text-sm font-semibold transition",
            if(active?(@active, tab.key),
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

  # `SettingsLive` passes its section key as the string `Settings.Registry`
  # resolves; the other pages pass an atom.
  defp active?(active, key), do: to_string(active) == Atom.to_string(key)
end
