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

  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Voice.Chimes
  alias BusterClaw.Voice.Engine
  alias BusterClaw.Voice.Renderer

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Renderer.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Voice")
     |> assign(:engine, Engine.probe())
     |> assign(:engine_check, nil)
     # render key -> chime key, so a finished render knows which chime it is.
     # The renderer addresses work by content hash and has no idea these are
     # notification lines; this map is the only thing that does.
     |> assign(:chime_jobs, %{})
     |> assign(:chime_note, nil)
     |> load_chimes()}
  end

  defp load_chimes(socket) do
    assign(socket, :chimes, Enum.map(Chimes.keys(), &chime_row/1))
  end

  defp chime_row(key) do
    %{
      key: key,
      label: Sound.route_label(key),
      line: Chimes.line(key),
      installed?: Chimes.installed?(key)
    }
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

  def handle_event("chime-lines-save", %{"lines" => lines}, socket) do
    Enum.each(lines, fn {key, text} -> Chimes.put_line(key, text) end)

    {:noreply, socket |> load_chimes() |> assign(:chime_note, "Lines saved.")}
  end

  def handle_event("chime-lines-reset", _params, socket) do
    Chimes.reset_all()
    {:noreply, socket |> load_chimes() |> assign(:chime_note, "Back to the seeded lines.")}
  end

  # Ask for the whole set. Cache hits install immediately; the rest arrive on the
  # renderer's topic and are installed as they land, so the page fills in rather
  # than waiting for the slowest line.
  def handle_event("chime-render-all", _params, socket) do
    {socket, queued} =
      Enum.reduce(Chimes.render_all(), {socket, 0}, fn {key, result}, {acc, queued} ->
        case result do
          {:ok, path} ->
            Chimes.install(key, path)
            {acc, queued}

          {:queued, render_key} ->
            {update(acc, :chime_jobs, &Map.put(&1, render_key, key)), queued + 1}

          {:error, _reason} ->
            {acc, queued}
        end
      end)

    note =
      if queued == 0,
        do: "Every line was already made — they are installed.",
        else: "Making #{queued} line#{if queued == 1, do: "", else: "s"}. This takes a while."

    {:noreply, socket |> load_chimes() |> assign(:chime_note, note)}
  end

  @impl true
  def handle_info({:voice_render, render_key, result}, socket) do
    case Map.pop(socket.assigns.chime_jobs, render_key) do
      {nil, _jobs} ->
        # Somebody else's render. The topic is shared.
        {:noreply, socket}

      {chime_key, jobs} ->
        note =
          case result do
            {:ok, path} ->
              Chimes.install(chime_key, path)
              "Installed #{Sound.route_label(chime_key)}."

            {:error, reason} ->
              "#{Sound.route_label(chime_key)} failed: #{inspect(reason)}"
          end

        {:noreply,
         socket |> assign(:chime_jobs, jobs) |> assign(:chime_note, note) |> load_chimes()}
    end
  end

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

        <div class="ic-panel overflow-hidden">
          <header class="border-b-2 border-base-content/20 px-5 py-4">
            <p class="ic-eyebrow">Spoken notifications</p>
            <h2 class="font-display text-2xl font-black uppercase tracking-tight">
              What it says
            </h2>
            <p class="mt-1 text-sm text-base-content/65">
              A chime tells you something happened. A spoken one tells you <strong>what</strong>,
              from across the room. These are your machine's words — change any of them.
              Each is made once and kept, so nothing is rendered while a timer is going off.
            </p>
          </header>

          <form phx-submit="chime-lines-save" class="flex flex-col gap-3 px-5 py-5">
            <div :for={row <- @chimes} class="flex flex-wrap items-center gap-3">
              <span class="w-28 shrink-0 text-xs uppercase tracking-wide text-base-content/60">
                {row.label}
              </span>
              <input
                type="text"
                name={"lines[#{row.key}]"}
                value={row.line}
                maxlength="120"
                class="input input-bordered input-sm min-w-0 flex-1 text-sm"
              />
              <span class="w-20 shrink-0 text-xs text-base-content/50">
                <%= if row.installed? do %>
                  <.icon name="hero-check" class="size-4 text-primary" /> spoken
                <% end %>
              </span>
            </div>

            <div class="mt-2 flex flex-wrap items-center gap-3">
              <button type="submit" class="btn btn-primary btn-sm">Save lines</button>
              <button type="button" phx-click="chime-lines-reset" class="btn btn-ghost btn-sm">
                Reset to defaults
              </button>
              <button
                type="button"
                phx-click="chime-render-all"
                disabled={not @engine.available?}
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-microphone" class="size-4" /> Speak them
              </button>
              <span class="text-xs text-base-content/60">{@chime_note}</span>
            </div>

            <p :if={not @engine.available?} class="text-xs text-base-content/55">
              Editing works without an engine — speaking them needs one. Install it above,
              then come back.
            </p>
          </form>
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
