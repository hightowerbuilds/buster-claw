defmodule BusterClawWeb.Explained.Sites do
  @moduledoc """
  The two outbound tabs — busterclaw.lol and notesthatfloat.com.

  Both open in the app's own browser tab rather than the system browser: this
  app has a browser, and using it is the point.
  """
  use BusterClawWeb, :html
  import BusterClawWeb.Explained.Shared

  alias BusterClawWeb.Explained.Registry

  # busterclaw.lol — the download, the docs, the source and the terms. Nothing
  # is sold there (EXPLAINED_REWRITE D4; the site's own copy was cut to match
  # on 10-16).
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
          is where the app lives on the web: the macOS download, the
          documentation, and the terms and privacy policy. The app is a free
          download — no account to create, no license to buy.
        </p>
        <p>
          The source is readable so the runtime can be audited rather than
          trusted on faith — source-available, not open source. Releases are
          announced there and nowhere else, so it is also where to look when you
          want to know whether the build you are running is the latest.
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
