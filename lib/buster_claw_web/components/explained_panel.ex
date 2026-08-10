defmodule BusterClawWeb.ExplainedPanel do
  @moduledoc """
  The home Explained tab: guided tours of Buster Claw, one surface at a time.

  Presentation only — `select_explained_tab` is handled by the parent LiveView
  (`StatusLive`), which owns the sub-tab assign for the usual home-tab reason:
  the panel renders behind `:if`, so state kept here would not survive a glance
  at Chat.

  ## What lives where

  This module is the **rail and the dispatch**, and nothing else. Each tutorial
  is its own module under `BusterClawWeb.Explained`, and they are `import`ed here
  so a dispatch line reads `<.models_panel />` exactly as it did when all
  fourteen hundred lines shared one file:

  | Module | Tab |
  |---|---|
  | `Explained.Registry` | the tab / tile / feature registries — **add a tab here** |
  | `Explained.Intro` | the launcher grid and Get Started |
  | `Explained.Sites` | busterclaw.lol, Notes That Float |
  | `Explained.Stub` | any feature tab whose tutorial is unwritten (none today) |
  | `Explained.Models`, `.Shaders`, `.Phone`, `.Browser`, `.Cmd`, `.Gws`, `.Studio`, `.Ramshackle` | the eight tutorials |
  | `Explained.Shared` | the leaf components tutorials are built from |

  The rail, the Intro grid, the parent's event whitelist (via `tab_keys/0`) and
  the dispatch below all read from `Explained.Registry`, so a tab cannot exist in
  one of them and not the others.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Explained.Browser
  import BusterClawWeb.Explained.Cmd
  import BusterClawWeb.Explained.Gws
  import BusterClawWeb.Explained.Intro
  import BusterClawWeb.Explained.Models
  import BusterClawWeb.Explained.Phone
  import BusterClawWeb.Explained.Ramshackle
  import BusterClawWeb.Explained.Shaders
  import BusterClawWeb.Explained.Sites
  import BusterClawWeb.Explained.Studio
  import BusterClawWeb.Explained.Stub

  alias BusterClawWeb.Explained.Registry

  @doc "Sub-tab keys, in rail order — the parent's `select_explained_tab` whitelist."
  def tab_keys, do: Enum.map(Registry.tabs(), &elem(&1, 0))

  attr :tab, :string, required: true

  def explained_panel(assigns) do
    assigns = assign(assigns, tabs: Registry.tabs(), stubs: Registry.stubs())

    ~H"""
    <section id="home-explained" class="ic-panel flex min-h-0 flex-1 overflow-hidden">
      <%!-- Scanlines and aberration live on the RAIL ONLY: they used to sit on
            this `<section>` and laid a CRT overlay over the tutorial text, which
            is long-form reading. The wrapper exists because
            `.ic-scanlines::after` is `absolute; inset: 0` — on the scrolling
            element it sizes to the visible box and then scrolls away with the
            content, baring the bottom of a scrolled rail. This one cannot. --%>
      <div class="ic-scanlines flex w-40 shrink-0 flex-col border-r-2 border-base-content/20 lg:w-48">
        <%!-- The rail scrolls on its own: eleven tabs outgrow a short panel, and
              a rail that scrolled with the tutorial hides the tab you want. --%>
        <div
          role="tablist"
          aria-label="Explained"
          aria-orientation="vertical"
          class="flex min-h-0 flex-1 flex-col gap-0.5 overflow-y-auto py-2"
        >
          <%!-- Marker on the LEFT edge, not mirroring the divider on the right:
              this box scrolls, and a child overhanging one whose `overflow-y` is
              `auto` makes `overflow-x` `auto` too, so the faithful mirror of the
              old `-mb-0.5` would have bought a stray horizontal scrollbar. --%>
          <button
            :for={{key, label} <- @tabs}
            type="button"
            role="tab"
            aria-selected={to_string(@tab == key)}
            phx-click="select_explained_tab"
            phx-value-tab={key}
            class={[
              "ic-rail-tab border-l-2 px-3 py-1.5 text-left font-display text-xs font-bold uppercase leading-tight tracking-wide transition",
              if(@tab == key,
                do: "border-primary bg-primary/10 text-primary",
                else:
                  "border-transparent text-base-content/55 hover:border-base-content/25 hover:text-base-content"
              )
            ]}
          >
            {label}
          </button>
        </div>
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
        <.studio_panel :if={@tab == "studio"} />
        <.ramshackle_panel :if={@tab == "ramshackle"} />
        <.stub_panel :for={stub <- @stubs} :if={@tab == stub.key} stub={stub} />
      </div>
    </section>
    """
  end
end
