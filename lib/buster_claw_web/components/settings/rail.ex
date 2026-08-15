defmodule BusterClawWeb.Settings.Rail do
  @moduledoc """
  The Configuration page's sub-tab rail.

  Presentation only: it renders `BusterClawWeb.Settings.Registry.tabs/0` and
  pushes `select_settings_tab` at the parent LiveView, which owns the
  `:settings_tab` assign and the dispatch. Same shape as
  `BusterClawWeb.StudioPanel`'s rail, minus the dispatch — three of the four
  sections are still inline in `SettingsLive.render/1`, so the branch lives
  there.

  The rail deliberately does **not** patch the URL. `assets/js/lib/tabs.js`
  groups the Settings routes into one top-level browser tab by **exact path**,
  so `/settings?tab=google` would miss the group and spawn its own top tab
  labelled with the raw path — the `/notify-settings` regression
  `SettingsTabsTest` exists to catch. `SettingsLive` still *reads* `?tab=` at
  mount so a link or a test can open a specific tab; making the rail write it is
  a change to `tabs.js` first.
  """
  use BusterClawWeb, :html

  alias BusterClawWeb.Settings.Registry

  attr :active, :string, required: true

  def rail(assigns) do
    assigns = assign(assigns, :tabs, Registry.tabs())

    ~H"""
    <div
      id="settings-config-rail"
      role="tablist"
      aria-label="Configuration sections"
      class="flex flex-wrap gap-1 border-b-2 border-base-content/20"
    >
      <button
        :for={t <- @tabs}
        type="button"
        role="tab"
        id={"settings-config-tab-#{t.key}"}
        title={t.blurb}
        aria-selected={to_string(@active == t.key)}
        phx-click="select_settings_tab"
        phx-value-tab={t.key}
        class={[
          "-mb-0.5 border-b-2 px-3 py-1.5 font-display text-xs font-bold uppercase tracking-wide transition",
          if(@active == t.key,
            do: "border-primary text-primary",
            else: "border-transparent text-base-content/55 hover:text-base-content"
          )
        ]}
      >
        {t.label}
      </button>
    </div>
    """
  end
end
