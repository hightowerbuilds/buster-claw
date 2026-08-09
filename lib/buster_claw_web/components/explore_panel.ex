defmodule BusterClawWeb.ExplorePanel do
  @moduledoc """
  The home Explore tab: guided tours of Buster Claw, one surface at a time.

  Presentation only — `select_explore_tab` is handled by the parent LiveView
  (`StatusLive`), which owns the sub-tab assign for the usual home-tab reason:
  the panel renders behind `:if`, so state kept here would not survive a glance
  at Chat.

  ## What lives where

  This module is the **rail and the dispatch**, and nothing else. Each tutorial
  is its own module under `BusterClawWeb.Explore`, and they are `import`ed here
  so a dispatch line reads `<.models_panel />` exactly as it did when all
  fourteen hundred lines shared one file:

  | Module | Tab |
  |---|---|
  | `Explore.Registry` | the tab / tile / feature registries — **add a tab here** |
  | `Explore.Intro` | the launcher grid and Get Started |
  | `Explore.Sites` | busterclaw.lol, Notes That Float |
  | `Explore.Stub` | any feature tab whose tutorial is unwritten (none today) |
  | `Explore.Models`, `.Shaders`, `.Phone`, `.Browser`, `.Cmd`, `.Gws` | the six tutorials |
  | `Explore.Shared` | the leaf components tutorials are built from |

  The rail, the Intro grid, the parent's event whitelist (via `tab_keys/0`) and
  the dispatch below all read from `Explore.Registry`, so a tab cannot exist in
  one of them and not the others.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Explore.Browser
  import BusterClawWeb.Explore.Cmd
  import BusterClawWeb.Explore.Gws
  import BusterClawWeb.Explore.Intro
  import BusterClawWeb.Explore.Models
  import BusterClawWeb.Explore.Phone
  import BusterClawWeb.Explore.Shaders
  import BusterClawWeb.Explore.Sites
  import BusterClawWeb.Explore.Stub

  alias BusterClawWeb.Explore.Registry

  @doc "Sub-tab keys, in rail order — the parent's `select_explore_tab` whitelist."
  def tab_keys, do: Enum.map(Registry.tabs(), &elem(&1, 0))

  attr :tab, :string, required: true

  def explore_panel(assigns) do
    assigns = assign(assigns, tabs: Registry.tabs(), stubs: Registry.stubs())

    ~H"""
    <section
      id="home-explore"
      class="ic-panel ic-scanlines flex min-h-0 flex-1 flex-col overflow-hidden"
    >
      <div
        role="tablist"
        aria-label="Explore"
        class="flex shrink-0 flex-wrap gap-1 border-b-2 border-base-content/20 px-2 pt-2"
      >
        <button
          :for={{key, label} <- @tabs}
          type="button"
          role="tab"
          aria-selected={to_string(@tab == key)}
          phx-click="select_explore_tab"
          phx-value-tab={key}
          class={[
            "-mb-0.5 border-b-2 px-3 py-1.5 font-display text-xs font-bold uppercase tracking-wide transition",
            if(@tab == key,
              do: "border-primary text-primary",
              else: "border-transparent text-base-content/55 hover:text-base-content"
            )
          ]}
        >
          {label}
        </button>
      </div>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <.intro_panel :if={@tab == "intro"} />
        <.site_panel :if={@tab == "site"} />
        <.ntf_panel :if={@tab == "ntf"} />
        <.models_panel :if={@tab == "models"} />
        <.shaders_panel :if={@tab == "shaders"} />
        <.phone_panel :if={@tab == "phone"} />
        <.gws_panel :if={@tab == "gws"} />
        <.cmd_panel :if={@tab == "cmd"} />
        <.browser_panel :if={@tab == "browser"} />
        <.stub_panel :for={stub <- @stubs} :if={@tab == stub.key} stub={stub} />
      </div>
    </section>
    """
  end
end
