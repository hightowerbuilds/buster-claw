defmodule BusterClawWeb.VoiceLive do
  @moduledoc """
  Voice settings: which voice reads the replies, how fast, and where to switch
  speech on. Speech output runs through the native macOS synthesizer in the
  desktop app; there is no microphone/voice-input feature.

  ## Why the picker holds no server state

  The voice, the rate and the on/off toggle all live in `localStorage`, read by
  `hooks/voice.js` on every reply. Nothing on the server needs to know what the
  app sounds like on one particular Mac — and the list of voices to choose from
  cannot come from here anyway, because it is whatever that machine has
  downloaded. `list_voices` (Rust) is the only thing that can answer it, so the
  page renders an empty shell and `VoicePicker` fills it in.
  """
  use BusterClawWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Voice")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket}>
      <section class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:voice} />

        <div class="ic-panel overflow-hidden">
          <header class="border-b-2 border-base-content/20 px-5 py-4">
            <p class="ic-eyebrow">Voice</p>
            <h2 class="font-display text-2xl font-black uppercase tracking-tight">
              Spoken replies
            </h2>
            <p class="mt-1 text-sm text-base-content/65">
              Buster Claw can read its replies aloud using your Mac's built-in speech
              synthesizer — <strong>on-device</strong>, nothing is sent anywhere.
            </p>
          </header>

          <ul class="flex flex-col gap-3 px-5 py-5 text-sm text-base-content/75">
            <li class="flex gap-3">
              <.icon name="hero-speaker-wave" class="size-5 shrink-0 text-primary" />
              <span>
                Toggle <strong>Voice on / off</strong> from the button in the chat header.
                When it's on, each assistant reply is spoken as it arrives.
              </span>
            </li>
            <li class="flex gap-3">
              <.icon name="hero-bolt" class="size-5 shrink-0 text-primary" />
              <span>
                Sending a new message (or cutting a run) stops whatever is being spoken,
                so a fresh turn never talks over the last one.
              </span>
            </li>
            <li class="flex gap-3">
              <.icon name="hero-computer-desktop" class="size-5 shrink-0 text-primary" />
              <span>Available in the macOS desktop app only.</span>
            </li>
          </ul>
        </div>

        <div class="ic-panel overflow-hidden" id="voice-picker" phx-hook="VoicePicker">
          <header class="border-b-2 border-base-content/20 px-5 py-4">
            <p class="ic-eyebrow">Voice</p>
            <h2 class="font-display text-2xl font-black uppercase tracking-tight">
              Which voice
            </h2>
            <p class="mt-1 text-sm text-base-content/65">
              Pick the voice Buster Claw speaks in. Choosing one plays it straight away.
              More voices — including higher-quality ones — install from <strong>System Settings → Accessibility → Spoken Content → System Voice</strong>,
              and show up here once they have downloaded.
            </p>
          </header>

          <div data-voice-unavailable hidden class="px-5 py-5 text-sm text-base-content/65">
            <p>
              The speech synthesizer belongs to the desktop app, so there is nothing to
              pick from in a browser. Open Buster Claw on macOS to choose a voice.
            </p>
          </div>

          <div data-voice-controls hidden class="flex flex-col gap-5 px-5 py-5">
            <label class="flex flex-col gap-2">
              <span class="ic-eyebrow">Voice</span>
              <select
                data-voice-select
                class="select select-bordered w-full max-w-md font-mono text-sm"
              >
              </select>
            </label>

            <label class="flex flex-col gap-2">
              <span class="ic-eyebrow">
                Speed <span data-voice-rate-label class="font-mono normal-case"></span>
              </span>
              <input
                type="range"
                data-voice-rate
                min="100"
                max="400"
                step="5"
                class="range range-primary w-full max-w-md"
              />
            </label>

            <div class="flex flex-wrap gap-3">
              <button type="button" data-voice-audition class="btn btn-ghost btn-sm">
                <.icon name="hero-play" class="size-4" /> Hear it
              </button>
              <button type="button" data-voice-reset class="btn btn-ghost btn-sm">
                Use system default
              </button>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
