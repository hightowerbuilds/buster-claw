defmodule BusterClawWeb.BrandArt do
  @moduledoc """
  The app's own art, rendered from `BusterClaw.Pockets.Brand`.

  One function component per brand surface that is more than a bare `<img>`. The
  dock icons are not here — they are a plain image inside an existing link, and
  `Layouts` resolves them at assign time.

  ## Why this module exists at all

  `status_live.ex` was at 944 lines against a 945 cap when the homepage banner
  became swappable. The cap's own note said the next thing to land there owed an
  extraction rather than a raise, so the heading moved out instead of the file
  growing — which is the gate working exactly as intended.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Pockets.Brand

  @role "home_banner"

  @doc """
  The BusterClaw heading at the top of the homepage.

  Renders the operator's banner if their Pocket holds exactly one image, the
  shipped art if it holds none, and **the word mark as text** if it holds two or
  more — `Brand.image_url/1` returns `nil` in that last case, which is the whole
  signal.

  The doubled `<img>` is not a mistake: the second is the CRT focus layer the
  `CrtAberration` hook drives, and it has to be the same source as the first.
  """
  def banner(assigns) do
    assigns = assign(assigns, :url, Brand.image_url(@role))

    ~H"""
    <div
      :if={@url}
      id="bc-heading"
      phx-hook="CrtAberration"
      class="ic-scanlines block w-full max-w-[28rem]"
    >
      <img src={@url} alt="Buster Claw" class="block h-auto w-full" />
      <img src={@url} alt="" aria-hidden="true" class="ic-crt-focus h-auto w-full" />
    </div>
    <div
      :if={!@url}
      id="bc-heading-text"
      class="block w-full max-w-[28rem] font-display text-4xl font-bold tracking-tight text-base-content"
    >
      {Brand.label(@role)}
    </div>
    """
  end
end
