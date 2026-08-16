defmodule BusterClawWeb.Pockets.AppIconSlot do
  @moduledoc """
  The macOS Dock icon's row in the Pockets tab — `APP_ICON_ROADMAP` Phase 2.

  Its own section rather than a seventh `BrandSlots` row, because it is the only
  slot with a **verb**. The six app-art slots follow their folder: put one image
  in and it renders. This one has a gap between the folder and the effect, and
  the button is that gap — an agent can write a file into the Pocket without any
  command at all, so a Dock icon that simply followed the folder would hand an
  unattended run the app's identity in the OS chrome (Phase 0, option 2).

  Markup only; the events live in `BusterClawWeb.PocketsPanel`.

  ## Why the status line is wordy

  Because `:replaced` is a state the operator has to be able to reason about, and
  it looks like a bug from the outside: they had a custom icon, the file on disk
  is still there, and the Dock has gone back to the shipped one. Saying "the file
  changed since you applied it" is the difference between a feature that seems
  broken and one that seems careful.
  """
  use BusterClawWeb, :html

  attr :status, :any, required: true
  attr :target, :any, required: true

  def app_icon_slot(assigns) do
    ~H"""
    <section id="pockets-app-icon" class="border-b-2 border-base-content/15 bg-base-200/25">
      <header class="flex flex-wrap items-baseline justify-between gap-2 px-4 py-3">
        <h3 class="font-display text-xs font-black uppercase tracking-tight">Dock icon</h3>
        <p class="font-mono text-[10px] uppercase tracking-wide text-base-content/45">
          macOS only · while the app runs
        </p>
      </header>

      <div class="flex flex-wrap items-center gap-3 px-4 pb-3">
        <div class="min-w-0 flex-1">
          <p id="app-icon-status" class="text-sm text-base-content/80">
            {status_line(@status)}
          </p>
          <p class="mt-0.5 font-mono text-[10px] uppercase tracking-wide text-base-content/45">
            pockets/app-icon
          </p>
        </div>

        <button
          :if={@status in [:pending, :replaced]}
          id="app-icon-apply"
          type="button"
          phx-click="apply_app_icon"
          phx-target={@target}
          class="shrink-0 border-2 border-accent bg-accent/15 px-3 py-1.5 font-mono text-[11px] font-bold uppercase transition hover:bg-accent/30"
        >
          Use this icon
        </button>

        <button
          :if={@status == :applied}
          id="app-icon-revoke"
          type="button"
          phx-click="revoke_app_icon"
          phx-target={@target}
          class="shrink-0 border-2 border-base-content/25 px-3 py-1.5 font-mono text-[11px] font-bold uppercase text-base-content/70 transition hover:bg-base-content/10"
        >
          Stop using it
        </button>
      </div>
    </section>
    """
  end

  # `:empty` names the folder rather than the app, because the next thing the
  # operator does is go and put something in it.
  defp status_line(:empty),
    do:
      "Drop one image into this Pocket, then apply it here. Until you do, the Dock shows the icon the app shipped with."

  defp status_line(:pending),
    do:
      "An image is waiting. Applying it changes the Dock for as long as the app is running — quitting puts the shipped icon back."

  defp status_line(:applied),
    do:
      "Your icon is on the Dock. It lasts until you quit; the app in Finder is unchanged, because its own icon is sealed by the signature."

  # The state most likely to be read as a fault. Says what happened, who could
  # have done it, and what to do.
  defp status_line(:replaced),
    do:
      "The file changed since you applied it, so the Dock went back to the shipped icon. " <>
        "That is deliberate: anything that can write to this folder — including the agent — " <>
        "could have replaced it, and what you approved was the picture you looked at. Apply it again to accept the new one."

  defp status_line({:error, :too_many, count}),
    do: "#{count} images are in this Pocket, so none is the icon. Leave one and apply it."

  defp status_line(_other), do: "This Pocket is not in a state the Dock can use."
end
