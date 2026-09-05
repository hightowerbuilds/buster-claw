defmodule BusterClawWeb.Vox.Greeting do
  @moduledoc """
  Vox2B's **What callers hear** panel: the phone greeting, written here and
  rendered in the operator's own voice instead of Amazon's.

  Extracted from `BusterClawWeb.VoxComponent` on 09-05 to fund the spoken-messages
  panel moving in (`VOX_TAB_ROADMAP` Phase 2), which is the file-size gate working
  rather than being worked around: `vox_component.ex` is FROZEN, so an arriving
  feature is paid for by a panel leaving. Second time in a day, and the second
  cut of Phase 3's per-panel shape.

  ## The greeting is one recording, not two

  The wording here is the WHOLE line, access-code instructions included, because
  the Edge Function speaks it as a single `<Say>` element. A greeting in the
  operator's voice followed by Polly reading the instructions is worse than
  all-Polly, and the TwiML gives no way to have it both ways without splitting
  the element. `BusterClaw.Voice.Greeting` carries the argument.
  """
  use BusterClawWeb, :html

  alias BusterClawWeb.Vox.Progress

  @doc "The greeting panel. `since` is nil unless a render is in flight."
  attr :text, :string, required: true
  attr :status, :map, required: true
  attr :engine, :map, required: true
  attr :note, :string, default: nil
  attr :since, :integer, default: nil
  attr :id, :string, required: true
  attr :target, :any, required: true

  def panel(assigns) do
    ~H"""
    <section class="ic-vox-section">
      <h3>What callers hear</h3>
      <p class="ic-vox-hint">
        The phone greeting, in your voice instead of Amazon's. It is one recording, instructions
        included — the whole line is yours to write.
      </p>

      <div class="flex flex-col gap-3 text-sm">
        <div class="flex items-center gap-2">
          <%= cond do %>
            <% @status.stale? -> %>
              <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-warning" />
              <span class="ic-vox-note">
                Published — but callers hear the old recording. Publish again.
              </span>
            <% @status.published? -> %>
              <.icon name="hero-check-circle" class="size-4 shrink-0 text-primary" />
              <span class="ic-vox-note">Published. This is what callers hear.</span>
            <% true -> %>
              <.icon name="hero-x-circle" class="size-4 shrink-0 text-base-content/40" />
              <span class="ic-vox-note">
                Not published — callers hear the synthesized voice.
              </span>
          <% end %>
        </div>

        <form phx-submit="greeting-save" phx-target={@target} class="flex flex-col gap-2">
          <textarea
            name="greeting"
            rows="3"
            maxlength="600"
            class="textarea textarea-bordered w-full text-sm"
          ><%= @text %></textarea>

          <div class="flex flex-wrap items-center gap-2">
            <button type="submit" class="btn btn-primary btn-xs">Save wording</button>

            <button
              type="button"
              phx-click="greeting-publish"
              phx-target={@target}
              disabled={not @engine.available? or @since != nil}
              data-claw-confirm="This changes what every caller hears when they phone your number. Record and publish it?"
              class="btn btn-ghost btn-xs"
            >
              Record and publish
            </button>

            <button
              :if={@status.published?}
              type="button"
              phx-click="greeting-unpublish"
              phx-target={@target}
              data-claw-confirm="Callers will go back to the synthesized voice. Take it down?"
              class="btn btn-ghost btn-xs"
            >
              Take it down
            </button>

            <Progress.chip
              :if={@since}
              id={"#{@id}-greeting"}
              since={@since}
              label="Recording"
            />
            <span :if={is_nil(@since)} class="ic-vox-note">{@note}</span>
          </div>
        </form>

        <p :if={not @engine.available?} class="ic-vox-note">
          Recording needs the engine above. The wording can be saved without it.
        </p>
      </div>
    </section>
    """
  end
end
