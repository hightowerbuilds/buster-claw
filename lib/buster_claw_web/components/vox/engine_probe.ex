defmodule BusterClawWeb.Vox.EngineProbe do
  @moduledoc """
  Vox2B's **A voice of its own** panel: whether VoxCPM is installed, where, and
  the line to install it if not.

  It reports what is INSTALLED and never claims to know whether it RUNS — the
  liveness button that used to sit here was deleted on 09-05 because clicking it
  produced a sentence and no experience. `BusterClaw.Voice.Engine`'s moduledoc
  carries that argument and the reason a check cannot simply be run on load.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Voice.Engine

  attr :engine, :map, required: true
  attr :target, :any, required: true

  def panel(assigns) do
    ~H"""
    <section class="ic-vox-section">
      <h3>A voice of its own</h3>
      <p class="ic-vox-hint">
        <strong>VoxCPM</strong>
        can be given a voice of its own. It is far slower than real time, so it is used for
        sounds made once and kept — chimes and the phone greeting, never chat.
      </p>

      <div class="flex flex-col gap-3 text-sm">
        <div class="flex items-center gap-2">
          <%= if @engine.available? do %>
            <.icon name="hero-check-circle" class="size-4 shrink-0 text-primary" />
            <span class="ic-vox-note">
              {@engine.path} · {@engine.device}
            </span>
          <% else %>
            <.icon name="hero-x-circle" class="size-4 shrink-0 text-base-content/40" />
            <span class="ic-vox-note">{absent_sentence(@engine.reason)}</span>
          <% end %>
        </div>

        <pre
          :if={not @engine.available?}
          class="overflow-x-auto rounded border border-base-content/15 bg-base-200 p-2.5 text-[0.6875rem]"
        ><code>{Engine.install_hint()}</code></pre>

        <div class="flex flex-wrap items-center gap-2">
          <button
            type="button"
            phx-click="engine-recheck"
            phx-target={@target}
            class="btn btn-ghost btn-xs"
          >
            Check again
          </button>
        </div>
      </div>
    </section>
    """
  end

  # Two different problems deserve two different sentences: nothing installed is
  # a thing to go and do, a file that cannot be run is a broken install. Moved
  # here with the markup that says it — it was never state, only wording.
  defp absent_sentence(:not_executable),
    do: "Found, but it cannot be run — the install looks incomplete."

  defp absent_sentence(_),
    do: "Not installed. Replies are read by your Mac's own voices, which is the default."
end
