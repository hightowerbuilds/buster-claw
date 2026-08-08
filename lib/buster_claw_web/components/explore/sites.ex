defmodule BusterClawWeb.Explore.Sites do
  @moduledoc """
  The two outbound tabs — busterclaw.lol and notesthatfloat.com.

  Both open in the app's own browser tab rather than the system browser: this
  app has a browser, and using it is the point.
  """
  use BusterClawWeb, :html
  import BusterClawWeb.Explore.Shared

  alias BusterClawWeb.Explore.Registry

  # busterclaw.lol — headquarters and the future counter for the agent's phone
  # number. Keep vending in future tense until the store is actually live.
  def site_panel(assigns) do
    assigns = assign(assigns, :site_url, Registry.site_url())

    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-5 px-6 py-8">
      <div>
        <p class="ic-eyebrow">Headquarters</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          busterclaw.lol
        </h2>
      </div>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/80">
        <p>
          <span class="font-semibold text-base-content">busterclaw.lol</span>
          is where the app lives on the web — releases, docs, and the planned
          counter where your agent will be able to get its own phone number.
        </p>
        <p>
          The plan is deliberately simple: one purchasable asset, a real line
          issued to you on one bill. Until number vending opens, use the Phone tab
          to understand the answering-machine and relay workflow that line enables.
        </p>
      </div>

      <.external_link url={@site_url} label="Open busterclaw.lol" />
    </div>
    """
  end

  def ntf_panel(assigns) do
    assigns = assign(assigns, :ntf_url, Registry.ntf_url())

    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-5 px-6 py-8">
      <div>
        <p class="ic-eyebrow">From the same bench</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          Notes That Float
        </h2>
      </div>

      <p class="text-sm leading-relaxed text-base-content/80">
        <span class="font-semibold text-base-content">Notes That Float</span>
        is a separate creative-writing and journaling app on the open web. It turns
        notes into a spatial, 3D view for exploring ideas and connections; it is a
        sibling project, not Buster Claw's operator notebook or command surface.
      </p>

      <.external_link url={@ntf_url} label="Open notesthatfloat.com" />
    </div>
    """
  end
end
