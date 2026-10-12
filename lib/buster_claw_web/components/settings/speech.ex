defmodule BusterClawWeb.Settings.Speech do
  @moduledoc "Native macOS chat read-aloud controls; preferences stay on this device."
  use BusterClawWeb, :html

  attr :id, :string, default: "settings-speech"

  def panel(assigns) do
    ~H"""
    <section id={@id} class="ic-panel space-y-6 p-6">
      <header class="space-y-2">
        <p class="ic-eyebrow">Speech</p>
        <h2 class="font-display text-xl font-black uppercase tracking-tight">Spoken replies</h2>
        <p class="max-w-2xl text-sm leading-relaxed text-base-content/65">
          Your Mac's own speech synthesizer reads each reply as it arrives — <strong>on-device</strong>, nothing is sent anywhere. Toggle
          <strong>Voice on / off</strong>
          in the chat header; a new message stops
          whatever is being spoken. macOS desktop app only.
        </p>
      </header>
      <div id={"#{@id}-picker"} phx-hook="VoicePicker" phx-update="ignore" class="space-y-4">
        <p class="max-w-2xl text-sm text-base-content/65">
          Choosing a voice plays it straight away. More voices are available in <strong>System Settings → Accessibility → Spoken Content → System Voice</strong>.
        </p>
        <p data-voice-unavailable hidden class="rounded border border-base-content/15 p-3 text-sm">
          The speech synthesizer belongs to the desktop app, so there is nothing to pick from
          in a browser.
        </p>
        <div data-voice-controls hidden class="max-w-sm space-y-4">
          <.input
            id={"#{@id}-voice"}
            name="speech_voice"
            type="select"
            label="Voice"
            options={[]}
            value={nil}
            data-voice-select
            class="w-full rounded border border-base-content/25 bg-base-100 px-3 py-2 font-mono text-sm focus:border-primary focus:outline-none"
          />
          <div>
            <p class="flex items-center justify-between text-xs text-base-content/65">
              <span>Words per minute</span>
              <span data-voice-rate-label class="font-mono"></span>
            </p>
            <.input
              id={"#{@id}-rate"}
              name="speech_rate"
              type="range"
              label="Speed"
              value={175}
              data-voice-rate
              min="100"
              max="400"
              step="5"
              class="w-full cursor-pointer accent-primary"
            />
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              id={"#{@id}-audition"}
              type="button"
              data-voice-audition
              class="rounded border border-base-content/25 px-3 py-2 text-xs font-semibold transition hover:border-primary hover:text-primary focus-visible:outline-primary"
            >
              Hear it
            </button>
            <button
              id={"#{@id}-reset"}
              type="button"
              data-voice-reset
              class="rounded border border-base-content/25 px-3 py-2 text-xs font-semibold transition hover:border-primary hover:text-primary focus-visible:outline-primary"
            >
              Use system default
            </button>
          </div>
        </div>
      </div>
    </section>
    """
  end
end
