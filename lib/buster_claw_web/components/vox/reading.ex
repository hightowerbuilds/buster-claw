defmodule BusterClawWeb.Vox.Reading do
  @moduledoc """
  Vox2B's **Reading aloud** tab: the Mac's own speech synthesizer, which reads
  chat replies as they arrive.

  A different engine from everything else on this surface — `say(1)`, instant and
  local, against VoxCPM, which is minutes per line and makes files. Keeping them
  on one tab was the operator's call (`VOX_TAB_ROADMAP` `D1`); keeping them in one
  SECTION would have been a claim that they are the same feature.
  """
  use BusterClawWeb, :html

  attr :id, :string, required: true

  def panel(assigns) do
    ~H"""
    <section class="ic-vox-section">
      <h3>Spoken replies</h3>
      <p class="ic-vox-hint">
        Your Mac's own speech synthesizer reads each reply as it arrives — <strong>on-device</strong>, nothing is sent anywhere. Toggle
        <strong>Voice on / off</strong>
        in the chat header; a new message stops whatever is being spoken. macOS desktop app only.
      </p>
    </section>
    <section class="ic-vox-section" id={"#{@id}-picker"} phx-hook="VoicePicker">
      <h3>Which voice</h3>
      <p class="ic-vox-hint">
        Choosing one plays it straight away. More install from <strong>System Settings → Accessibility → Spoken Content → System Voice</strong>.
      </p>

      <div data-voice-unavailable hidden class="ic-vox-note">
        The speech synthesizer belongs to the desktop app, so there is nothing to pick from in a
        browser.
      </div>

      <div data-voice-controls hidden class="flex flex-col gap-3 text-sm">
        <label class="flex flex-col gap-1">
          <span class="ic-eyebrow">Voice</span>
          <select
            data-voice-select
            class="select select-bordered select-sm w-full max-w-sm font-mono text-xs"
          >
          </select>
        </label>

        <label class="flex flex-col gap-1">
          <span class="ic-eyebrow">
            Speed <span data-voice-rate-label class="font-mono normal-case"></span>
          </span>
          <input
            type="range"
            data-voice-rate
            min="100"
            max="400"
            step="5"
            class="range range-primary range-xs w-full max-w-sm"
          />
        </label>

        <div class="flex flex-wrap gap-2">
          <button type="button" data-voice-audition class="btn btn-ghost btn-xs">
            Hear it
          </button>
          <button type="button" data-voice-reset class="btn btn-ghost btn-xs">
            Use system default
          </button>
        </div>
      </div>
    </section>
    """
  end
end
