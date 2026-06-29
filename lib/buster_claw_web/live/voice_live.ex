defmodule BusterClawWeb.VoiceLive do
  @moduledoc """
  Voice settings: explains spoken replies (text-to-speech) and where to toggle
  them. Speech output runs through the native macOS synthesizer in the desktop
  app; there is no microphone/voice-input feature.
  """
  use BusterClawWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Voice")}
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
      </section>
    </Layouts.app>
    """
  end
end
