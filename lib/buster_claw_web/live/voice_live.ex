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

  alias BusterClaw.Voice.Engine

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Voice")
     |> assign(:engine, Engine.probe())
     |> assign(:engine_check, nil)}
  end

  @impl true
  def handle_event("engine-recheck", _params, socket) do
    {:noreply, socket |> assign(:engine, Engine.refresh()) |> assign(:engine_check, nil)}
  end

  # `verify/0` runs the binary, which imports torch before it prints its own
  # usage — seconds, not milliseconds. Done in a task so the LiveView stays
  # answerable; blocking here would freeze the settings page on a slow disk.
  def handle_event("engine-verify", _params, socket) do
    task = Task.async(fn -> Engine.verify() end)
    {:noreply, assign(socket, :engine_check, {:running, task.ref})}
  end

  @impl true
  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, assign(socket, :engine_check, result)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

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

        <div class="ic-panel overflow-hidden">
          <header class="border-b-2 border-base-content/20 px-5 py-4">
            <p class="ic-eyebrow">Engine</p>
            <h2 class="font-display text-2xl font-black uppercase tracking-tight">
              A voice of its own
            </h2>
            <p class="mt-1 text-sm text-base-content/65">
              The voices above are your Mac's, and they read replies instantly.
              <strong>VoxCPM</strong>
              is a speech model that can be given a voice of its own — it is far slower than
              real time, so it is used for sounds that are made once and kept: notification
              chimes and the phone greeting. It is never used to read chat.
            </p>
          </header>

          <div class="flex flex-col gap-4 px-5 py-5 text-sm">
            <div class="flex items-center gap-3">
              <%= if @engine.available? do %>
                <.icon name="hero-check-circle" class="size-5 shrink-0 text-primary" />
                <span>
                  Installed at <code class="font-mono text-xs">{@engine.path}</code>, running on <code class="font-mono text-xs">{@engine.device}</code>.
                </span>
              <% else %>
                <.icon name="hero-x-circle" class="size-5 shrink-0 text-base-content/40" />
                <span class="text-base-content/70">
                  {absent_sentence(@engine.reason)}
                </span>
              <% end %>
            </div>

            <%= unless @engine.available? do %>
              <div class="flex flex-col gap-2">
                <p class="text-base-content/65">
                  It is not bundled — the weights alone are larger than this whole app. Install it
                  yourself, then press Check again:
                </p>
                <pre class="overflow-x-auto rounded border-2 border-base-content/20 bg-base-200 p-3 text-xs"><code>{Engine.install_hint()}</code></pre>
              </div>
            <% end %>

            <div class="flex flex-wrap items-center gap-3">
              <button type="button" phx-click="engine-recheck" class="btn btn-ghost btn-sm">
                <.icon name="hero-arrow-path" class="size-4" /> Check again
              </button>

              <%= if @engine.available? do %>
                <button
                  type="button"
                  phx-click="engine-verify"
                  disabled={match?({:running, _}, @engine_check)}
                  class="btn btn-ghost btn-sm"
                >
                  Run it
                </button>
              <% end %>

              <span class="text-xs text-base-content/60">{check_sentence(@engine_check)}</span>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # Two different problems deserve two different sentences: nothing installed is
  # a thing to go and do, a file that cannot be run is a broken install.
  defp absent_sentence(:not_executable),
    do: "Found, but it cannot be run — the install looks incomplete."

  defp absent_sentence(_),
    do: "Not installed. Replies are read by your Mac's own voices, which is the default."

  defp check_sentence(nil), do: ""

  defp check_sentence({:running, _ref}),
    do: "Running it — this takes a few seconds, it loads a model to say hello."

  defp check_sentence(:ok), do: "It answered."
  defp check_sentence({:error, :timeout}), do: "It did not answer in time."
  defp check_sentence({:error, :not_installed}), do: "It is gone."

  defp check_sentence({:error, {:exit, code}}),
    do: "It exited #{code} — the install is present but not working."

  defp check_sentence(_), do: ""
end
