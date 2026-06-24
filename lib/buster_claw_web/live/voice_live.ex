defmodule BusterClawWeb.VoiceLive do
  @moduledoc """
  Voice settings: explains on-device speech-to-text, offers a microphone test
  (reusing the `Mic` hook), and points at the macOS permission if it's silent.
  """
  use BusterClawWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Voice")}
  end

  # The Mic hook reports capture/permission problems here.
  @impl true
  def handle_event("voice_error", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :error, message)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:voice} />

        <div class="ic-panel overflow-hidden">
          <header class="border-b-2 border-base-content/20 px-5 py-4">
            <p class="ic-eyebrow">Voice</p>
            <h2 class="font-display text-2xl font-black uppercase tracking-tight">
              Voice input
            </h2>
            <p class="mt-1 text-sm text-base-content/65">
              Talk to Buster Claw instead of typing. Speech-to-text runs
              <strong>on-device</strong> (whisper) in the desktop app — nothing is sent anywhere.
            </p>
          </header>

          <ul class="flex flex-col gap-3 px-5 py-5 text-sm text-base-content/75">
            <li class="flex gap-3">
              <.icon name="hero-microphone" class="size-5 shrink-0 text-primary" />
              <span>
                Click the mic on the left of any chat composer (or press <kbd class="font-mono">⌘/</kbd>)
                to start listening; click again to stop. Your words fill the box — review, then send.
              </span>
            </li>
            <li class="flex gap-3">
              <.icon name="hero-computer-desktop" class="size-5 shrink-0 text-primary" />
              <span>Available in the macOS desktop app only (it uses your Mac's microphone).</span>
            </li>
          </ul>
        </div>

        <div id="voice-devices" phx-hook="VoiceDevices" class="ic-panel overflow-hidden">
          <header class="border-b-2 border-base-content/20 px-5 py-4">
            <p class="ic-eyebrow">Microphone</p>
            <h2 class="font-display text-2xl font-black uppercase tracking-tight">
              Input device
            </h2>
            <p class="mt-1 text-sm text-base-content/65">
              Choose which microphone Buster Claw listens to. Detected from your Mac.
            </p>
          </header>

          <div class="flex flex-col gap-3 p-5 sm:flex-row sm:items-end">
            <label class="min-w-0 flex-1">
              <span class="ic-eyebrow">Device</span>
              <select
                data-voice-device-select
                class="mt-1 w-full rounded-sm border-2 border-base-content/25 bg-base-100 px-3 py-2 text-sm focus:border-primary focus:outline-none"
              >
                <option value="">Default microphone</option>
              </select>
            </label>
            <button
              type="button"
              data-voice-device-refresh
              class="inline-flex shrink-0 items-center gap-2 rounded border-2 border-base-content/25 px-4 py-2 text-sm font-semibold transition hover:border-primary hover:text-primary"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </button>
          </div>

          <p data-voice-device-status class="px-5 pb-5 text-sm text-base-content/60">
            Finding microphones…
          </p>
        </div>

        <div class="ic-panel overflow-hidden">
          <header class="border-b-2 border-base-content/20 px-5 py-4">
            <p class="ic-eyebrow">Test</p>
            <h2 class="font-display text-2xl font-black uppercase tracking-tight">
              Test your microphone
            </h2>
            <p class="mt-1 text-sm text-base-content/65">
              Click the mic, say a sentence, then click again. Your words should appear below —
              if they do, voice is working.
            </p>
          </header>

          <div class="flex items-start gap-2 p-5">
            <button
              id="voice-test-mic"
              type="button"
              phx-hook="Mic"
              data-voice-target="[data-voice-test-input]"
              data-voice-overlay="[data-voice-test-overlay]"
              aria-label="Test microphone — click to talk"
              title="Click to talk · ⌘/"
              class="inline-grid size-11 shrink-0 place-items-center rounded border-2 border-base-content/25 text-base-content/70 transition hover:border-primary hover:text-primary data-[state=listening]:border-primary data-[state=listening]:bg-primary/10 data-[state=listening]:text-primary data-[state=listening]:animate-pulse data-[state=transcribing]:border-primary/60 data-[state=transcribing]:text-primary"
            >
              <span data-mic-idle class="inline-grid place-items-center">
                <.icon name="hero-microphone" class="size-5" />
              </span>
              <span
                data-mic-busy
                hidden
                class="size-3.5 animate-spin rounded-full border-2 border-current border-t-transparent"
              >
              </span>
            </button>

            <div class="relative flex-1">
              <textarea
                data-voice-test-input
                rows="3"
                placeholder="Your transcribed words will appear here…"
                class="min-h-0 w-full resize-none rounded-sm border-2 border-base-content/25 bg-base-100 px-3 py-2 text-[17px] focus:border-primary focus:outline-none"
              ></textarea>
              <div
                data-voice-test-overlay
                hidden
                class="pointer-events-none absolute inset-0 flex items-center justify-center gap-3 rounded-sm bg-base-100/85 backdrop-blur-sm"
              >
                <span class="ic-voice-bars" aria-hidden="true">
                  <i></i><i></i><i></i><i></i><i></i>
                </span>
                <span class="font-display text-xs font-bold uppercase tracking-wide text-primary">
                  Listening…
                </span>
              </div>
            </div>
          </div>
        </div>

        <div class="ic-panel overflow-hidden">
          <header class="border-b-2 border-base-content/20 px-5 py-4">
            <p class="ic-eyebrow">Microphone access</p>
          </header>
          <p class="px-5 py-5 text-sm text-base-content/75">
            If the test stays empty or transcribes nonsense, macOS is feeding the app silence —
            grant microphone access in <strong>System Settings → Privacy &amp; Security →
            Microphone</strong>, enable <strong>Buster Claw</strong>, then relaunch the app.
          </p>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
