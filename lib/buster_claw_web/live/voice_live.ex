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
  alias BusterClaw.Voice.Clips
  alias BusterClaw.Voice.Config
  alias BusterClaw.Voice.Engine
  alias BusterClaw.Voice.Greeting
  alias BusterClaw.Voice.Reference
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
     |> assign(:chime_task, nil)
     |> assign(:chime_note, nil)
     # The render key of a greeting being made, so its completion knows to
     # publish rather than just sit in the cache.
     |> assign(:greeting_job, nil)
     |> assign(:greeting_note, nil)
     |> assign(:config_note, nil)
     |> load_chimes()
     |> load_greeting()
     |> load_engine_config()
     # The recorder's capability report, the recordings, and the typed clips.
     # `clip_jobs` maps a render key back to the text that asked for it, for the
     # same reason `chime_jobs` does: the renderer addresses work by content hash
     # and has no idea what it is for.
     |> assign(:mic_state, nil)
     |> assign(:ref_note, nil)
     |> assign(:clip_text, "")
     |> assign(:clip_jobs, %{})
     |> assign(:clip_note, nil)
     |> load_reference()
     |> load_clips()}
  end

  defp load_reference(socket), do: assign(socket, :references, Reference.list())
  defp load_clips(socket), do: assign(socket, :clips, Clips.list())

  # The stored knobs plus the one number they change: how many chimes are already
  # made under them. The cache is keyed on the argv, so a new device or a
  # reference clip turns every made chime into a miss, and the page says so in
  # numbers rather than letting the operator find out at the button.
  defp load_engine_config(socket) do
    socket
    |> assign(:engine_config, Config.get())
    |> assign(:chimes_made, Chimes.made_count())
  end

  defp load_greeting(socket) do
    socket
    |> assign(:greeting_text, Greeting.text())
    |> assign(:greeting_status, Greeting.status())
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

  # One engine invocation for the whole set, in a task.
  #
  # The obvious alternative — one Renderer job per line — reports progress as each
  # lands, which is nicer, and costs the model load sixteen times. Measured on
  # this machine that is 2 min 29 s of warm-up each, so the pretty version takes
  # roughly twice as long as the whole job needs to. For a forty-minute grind the
  # operator runs whenever they change the voice, halving it beats watching a
  # progress line.
  def handle_event("chime-render-all", _params, socket) do
    if socket.assigns.chime_task do
      {:noreply, assign(socket, :chime_note, "Already making them.")}
    else
      task = Task.async(fn -> Chimes.render_set() end)

      {:noreply,
       socket
       |> assign(:chime_task, task.ref)
       |> assign(
         :chime_note,
         "Making all #{length(Chimes.keys())} — one model load for the set. " <>
           "Expect tens of minutes; you can leave this page."
       )}
    end
  end

  def handle_event("engine-config-save", %{"config" => attrs}, socket) do
    case Config.put(attrs) do
      :ok ->
        # A new engine path changes what `probe/0` finds; a new device or clip
        # changes which chimes count as made and whether the published greeting
        # still matches. All three re-read, because all three may have moved.
        socket =
          socket
          |> assign(:engine, Engine.refresh())
          |> load_engine_config()
          |> load_greeting()

        {made, total} = socket.assigns.chimes_made

        note =
          cond do
            made == total ->
              "Saved. Every chime is already made with these settings."

            made == 0 ->
              "Saved. These settings change the voice — all #{total} chimes need making again."

            true ->
              "Saved. #{total - made} of #{total} chimes need making again."
          end

        {:noreply, assign(socket, :config_note, note)}

      {:error, {field, :not_found}} ->
        {:noreply, assign(socket, :config_note, "#{humanize(field)}: no file there.")}

      {:error, {field, value}} ->
        {:noreply,
         assign(
           socket,
           :config_note,
           "#{humanize(field)}: #{inspect(value)} is not a value the engine accepts."
         )}
    end
  end

  def handle_event("engine-config-reset", _params, socket) do
    Config.reset()

    {:noreply,
     socket
     |> assign(:engine, Engine.refresh())
     |> load_engine_config()
     |> load_greeting()
     |> assign(:config_note, "Back to the engine's own defaults.")}
  end

  # --- the reference clip -------------------------------------------------------

  # The recorder reports what the browser found — ready, denied, unsupported —
  # rather than the page assuming. Kept as a state the markup can read.
  def handle_event("reference_report", %{"do" => "capability", "state" => state} = params, socket) do
    {:noreply, assign(socket, :mic_state, {state, Map.get(params, "detail")})}
  end

  def handle_event("reference_report", _params, socket), do: {:noreply, socket}

  def handle_event("reference_take", %{"pcm" => pcm, "sample_rate" => rate}, socket) do
    note =
      case Reference.save(pcm, rate) do
        {:ok, %{duration_ms: ms, peak: peak, clipped?: clipped?}} ->
          seconds = Float.round(ms / 1000, 1)
          base = "Saved #{seconds}s. This is your voice now — every render clones it."

          if clipped?,
            do: base <> " It clipped; a quieter take will clone cleaner.",
            else: base <> peak_hint(peak)

        {:error, :too_short} ->
          "Too short — the engine needs a few seconds to clone from. Ten is comfortable."

        {:error, :silent_take} ->
          "Nothing but silence came through. Check the input in System Settings → Sound."

        {:error, reason} ->
          "Could not save it: #{inspect(reason)}"
      end

    # A new reference makes every made chime a miss and the published greeting
    # stale, so both counts re-read alongside the recordings list.
    {:noreply,
     socket
     |> load_reference()
     |> load_engine_config()
     |> load_greeting()
     |> assign(:ref_note, note)}
  end

  def handle_event("reference_use", %{"name" => name}, socket) do
    note =
      case Reference.use(name) do
        :ok -> "Using that one."
        {:error, reason} -> "Could not: #{inspect(reason)}"
      end

    {:noreply,
     socket
     |> load_reference()
     |> load_engine_config()
     |> load_greeting()
     |> assign(:ref_note, note)}
  end

  def handle_event("reference_delete", %{"name" => name}, socket) do
    Reference.delete(name)

    {:noreply,
     socket
     |> load_reference()
     |> load_engine_config()
     |> load_greeting()
     |> assign(:ref_note, "Deleted.")}
  end

  # --- say anything ----------------------------------------------------------

  def handle_event("clip_make", %{"clip" => %{"text" => text}}, socket) do
    case Clips.make(text) do
      {:ok, _path} ->
        {:noreply,
         socket
         |> load_clips()
         |> assign(:clip_text, "")
         |> assign(:clip_note, "Already made — it is in the list.")}

      {:queued, key} ->
        {:noreply,
         socket
         |> update(:clip_jobs, &Map.put(&1, key, String.trim(text)))
         |> assign(:clip_text, "")
         |> assign(:clip_note, "Making it. A short line is a few minutes on this machine.")}

      {:error, :empty_text} ->
        {:noreply, assign(socket, :clip_note, "Type something first.")}

      {:error, :engine_unavailable} ->
        {:noreply, assign(socket, :clip_note, "No engine — install it above.")}

      {:error, :reference_missing} ->
        {:noreply,
         assign(
           socket,
           :clip_note,
           "The reference clip is gone. Record a new one, or clear it in the engine settings."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, :clip_note, "Could not make it: #{inspect(reason)}")}
    end
  end

  def handle_event("clip_forget", %{"path" => path}, socket) do
    Clips.forget(path)
    {:noreply, socket |> load_clips() |> assign(:clip_note, nil)}
  end

  def handle_event("greeting-save", %{"greeting" => text}, socket) do
    Greeting.put_text(text)

    note =
      if Greeting.status().stale?,
        do: "Saved — but callers still hear the old recording until you publish.",
        else: "Saved."

    {:noreply, socket |> load_greeting() |> assign(:greeting_note, note)}
  end

  # Render, then publish when it lands. Two steps rather than one because the
  # render can take minutes and publishing is the part that changes what
  # strangers hear.
  def handle_event("greeting-publish", _params, socket) do
    case Greeting.render() do
      {:ok, path} ->
        {:noreply, socket |> publish_greeting(path) |> load_greeting()}

      {:queued, key} ->
        {:noreply,
         socket
         |> assign(:greeting_job, key)
         |> assign(:greeting_note, "Recording the greeting. This takes a while.")}

      {:error, reason} ->
        {:noreply, assign(socket, :greeting_note, "Could not record it: #{inspect(reason)}")}
    end
  end

  def handle_event("greeting-unpublish", _params, socket) do
    note =
      case Greeting.unpublish() do
        :ok -> "Taken down. Callers hear the synthesized voice again."
        {:error, reason} -> "Could not take it down: #{inspect(reason)}"
      end

    {:noreply, socket |> load_greeting() |> assign(:greeting_note, note)}
  end

  # Installing is fast and local — it is a copy and a settings write — so the
  # whole set goes in at once rather than trickling.
  defp install_set(socket, results) do
    installed =
      Enum.count(results, fn {key, result} ->
        match?({:ok, _}, result) and match?({:ok, _}, Chimes.install(key, elem(result, 1)))
      end)

    failed = length(results) - installed

    note =
      if failed == 0,
        do: "All #{installed} installed. That is what your notifications say now.",
        else: "#{installed} installed, #{failed} failed — the rest are unchanged."

    socket |> assign(:chime_note, note) |> load_chimes()
  end

  defp publish_greeting(socket, path) do
    case Greeting.publish(path) do
      :ok ->
        assign(socket, :greeting_note, "Published. That is what callers hear now.")

      {:error, reason} ->
        assign(socket, :greeting_note, "Recorded, but publishing failed: #{inspect(reason)}")
    end
  end

  @impl true
  def handle_info({:voice_render, render_key, result}, socket)
      when is_binary(render_key) do
    cond do
      render_key == socket.assigns.greeting_job ->
        socket = assign(socket, :greeting_job, nil)

        case result do
          {:ok, path} ->
            {:noreply, socket |> publish_greeting(path) |> load_greeting()}

          {:error, reason} ->
            {:noreply, assign(socket, :greeting_note, "Recording failed: #{inspect(reason)}")}
        end

      Map.has_key?(socket.assigns.clip_jobs, render_key) ->
        {text, jobs} = Map.pop(socket.assigns.clip_jobs, render_key)
        socket = assign(socket, :clip_jobs, jobs)

        case result do
          {:ok, path} ->
            Clips.record(text, path)
            {:noreply, socket |> load_clips() |> assign(:clip_note, "Made: “#{text}”")}

          {:error, reason} ->
            {:noreply, assign(socket, :clip_note, "“#{text}” failed: #{inspect(reason)}")}
        end

      true ->
        handle_chime_render(render_key, result, socket)
    end
  end

  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    if ref == socket.assigns.chime_task do
      socket = assign(socket, :chime_task, nil)

      case result do
        {:ok, results} -> {:noreply, install_set(socket, results)}
        {:error, reason} -> {:noreply, assign(socket, :chime_note, "Failed: #{inspect(reason)}")}
      end
    else
      {:noreply, assign(socket, :engine_check, result)}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

  defp handle_chime_render(render_key, result, socket) do
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
            <p class="ic-eyebrow">Engine settings</p>
            <h2 class="font-display text-2xl font-black uppercase tracking-tight">
              How it speaks
            </h2>
            <p class="mt-1 text-sm text-base-content/65">
              Leave anything blank to use the engine's own default. The one that matters is
              the <strong>reference clip</strong>: point it at a few seconds of your own voice
              and every line is spoken in it, instead of a voice the model invents.
            </p>
          </header>

          <form phx-submit="engine-config-save" class="flex flex-col gap-4 px-5 py-5 text-sm">
            <label class="flex flex-col gap-1">
              <span class="ic-eyebrow">Reference clip — a WAV of your voice</span>
              <input
                type="text"
                name="config[reference_audio]"
                value={@engine_config.reference_audio}
                placeholder="~/Desktop/me-ten-seconds.wav"
                class="input input-bordered input-sm w-full font-mono text-xs"
              />
              <span class="text-xs text-base-content/55">
                Ten seconds of clean speech on a laptop mic is enough. With this set, every
                render clones it; without it, the engine designs a voice from the description below.
              </span>
            </label>

            <label class="flex flex-col gap-1">
              <span class="ic-eyebrow">Voice description — when not cloning</span>
              <input
                type="text"
                name="config[control]"
                value={@engine_config.control}
                placeholder="warm, low, unhurried"
                class="input input-bordered input-sm w-full text-sm"
              />
            </label>

            <div class="grid gap-4 sm:grid-cols-3">
              <label class="flex flex-col gap-1">
                <span class="ic-eyebrow">Device</span>
                <select
                  name="config[device]"
                  class="select select-bordered select-sm font-mono text-xs"
                >
                  <option value="" selected={is_nil(@engine_config.device)}>
                    auto ({Engine.device()})
                  </option>
                  <option value="cpu" selected={@engine_config.device == "cpu"}>cpu</option>
                  <option value="mps" selected={@engine_config.device == "mps"}>
                    mps — Apple silicon
                  </option>
                  <option value="cuda" selected={@engine_config.device == "cuda"}>cuda</option>
                </select>
              </label>

              <label class="flex flex-col gap-1">
                <span class="ic-eyebrow">Steps</span>
                <input
                  type="number"
                  name="config[inference_timesteps]"
                  value={@engine_config.inference_timesteps}
                  min="1"
                  placeholder="engine default"
                  class="input input-bordered input-sm font-mono text-xs"
                />
              </label>

              <label class="flex flex-col gap-1">
                <span class="ic-eyebrow">Guidance</span>
                <input
                  type="number"
                  name="config[cfg_value]"
                  value={@engine_config.cfg_value}
                  min="0.1"
                  step="0.1"
                  placeholder="engine default"
                  class="input input-bordered input-sm font-mono text-xs"
                />
              </label>
            </div>

            <p class="text-xs text-base-content/55">
              Fewer steps is faster and rougher; more guidance follows the text more literally.
              On this machine a line takes minutes, so these are real levers.
            </p>

            <label class="flex flex-col gap-1">
              <span class="ic-eyebrow">Engine path — only if it is somewhere unusual</span>
              <input
                type="text"
                name="config[engine_path]"
                value={@engine_config.engine_path}
                placeholder={Engine.resolve() || "~/.buster-claw/voxcpm/bin/voxcpm"}
                class="input input-bordered input-sm w-full font-mono text-xs"
              />
            </label>

            <div class="flex flex-wrap items-center gap-3 border-t-2 border-base-content/10 pt-4">
              <button type="submit" class="btn btn-primary btn-sm">Save settings</button>
              <button type="button" phx-click="engine-config-reset" class="btn btn-ghost btn-sm">
                Engine defaults
              </button>
              <span class="text-xs text-base-content/60">{@config_note}</span>
            </div>

            <p class="text-xs text-base-content/70">
              <strong>{elem(@chimes_made, 0)} of {elem(@chimes_made, 1)}</strong>
              chimes are made with these settings.
              <span :if={elem(@chimes_made, 0) < elem(@chimes_made, 1)}>
                Changing the voice changes every line, so <em>Speak them</em> below will make the
                other {elem(@chimes_made, 1) - elem(@chimes_made, 0)} — minutes each on this machine.
              </span>
            </p>
          </form>
        </div>

        <div class="ic-panel overflow-hidden">
          <header class="border-b-2 border-base-content/20 px-5 py-4">
            <p class="ic-eyebrow">Your voice</p>
            <h2 class="font-display text-2xl font-black uppercase tracking-tight">
              Record it once
            </h2>
            <p class="mt-1 text-sm text-base-content/65">
              Ten seconds of you talking normally — read the next line out loud, or just say
              anything. There is no training step: the recording <strong>is</strong>
              the learning. The moment it saves, every chime, clip and greeting is spoken in
              your voice.
            </p>
          </header>

          <div class="flex flex-col gap-4 px-5 py-5 text-sm">
            <p class="rounded border-2 border-base-content/10 bg-base-200 px-4 py-3 font-display text-base">
              “The quick way to check a microphone is to read a sentence you didn't write,
              at the speed you'd say it to a friend across a kitchen.”
            </p>

            <%!-- phx-update="ignore": the hook owns this subtree — the meter, the
                  status line, the button label — and a LiveView re-render must not
                  wipe them mid-take. Same discipline as the Studio's recorder. --%>
            <div
              id="voice-reference-recorder"
              phx-hook="VoiceRecorder"
              phx-update="ignore"
              data-event-take="reference_take"
              data-event-report="reference_report"
              class="flex flex-col gap-3"
            >
              <div data-role="format" class="font-mono text-[0.65rem] text-base-content/60">
                opening the microphone…
              </div>

              <div class="relative h-3 overflow-hidden rounded-sm border-2 border-base-content/20 bg-base-200">
                <div data-role="target-zone" class="absolute inset-y-0 bg-success/20"></div>
                <div
                  data-role="meter"
                  class="relative h-full w-0 bg-success transition-[width] duration-75"
                >
                </div>
              </div>

              <div class="flex flex-wrap items-center gap-3 font-mono text-xs">
                <span data-role="peak" class="text-base-content/60">peak —</span>
                <span data-role="clip" class="text-error" hidden>clipped</span>
                <button type="button" data-role="record" class="btn btn-primary btn-sm">
                  ● Record
                </button>
                <span data-role="status" class="text-base-content/60"></span>
              </div>
            </div>

            <p :if={match?({"denied", _}, @mic_state)} class="text-xs text-error">
              The microphone was refused. macOS asks once — System Settings → Privacy &amp;
              Security → Microphone, and allow Buster Claw.
            </p>
            <p :if={match?({"unsupported", _}, @mic_state)} class="text-xs text-base-content/55">
              No microphone here. Recording works in the desktop app, not in a browser tab.
            </p>

            <span class="text-xs text-base-content/70">{@ref_note}</span>

            <ul
              :if={@references != []}
              class="flex flex-col gap-2 border-t-2 border-base-content/10 pt-4"
            >
              <li :for={ref <- @references} class="flex flex-wrap items-center gap-3">
                <audio controls preload="none" src={~p"/voice-audio/#{ref.name}"} class="h-8 max-w-xs">
                </audio>
                <span class="font-mono text-xs text-base-content/60">{ref.name}</span>
                <span :if={ref.current?} class="text-xs text-primary">
                  <.icon name="hero-check" class="size-4" /> in use
                </span>
                <button
                  :if={not ref.current?}
                  type="button"
                  phx-click="reference_use"
                  phx-value-name={ref.name}
                  class="btn btn-ghost btn-xs"
                >
                  Use this one
                </button>
                <button
                  type="button"
                  phx-click="reference_delete"
                  phx-value-name={ref.name}
                  data-claw-confirm={"Delete #{ref.name}?" <> if(ref.current?, do: " It is the voice in use — renders go back to a designed voice.", else: "")}
                  class="btn btn-ghost btn-xs text-error"
                >
                  Delete
                </button>
              </li>
            </ul>
          </div>
        </div>

        <div class="ic-panel overflow-hidden">
          <header class="border-b-2 border-base-content/20 px-5 py-4">
            <p class="ic-eyebrow">Say anything</p>
            <h2 class="font-display text-2xl font-black uppercase tracking-tight">
              Hear yourself
            </h2>
            <p class="mt-1 text-sm text-base-content/65">
              Type a line, and it comes back in your voice. The fastest way to judge a
              recording — one sentence is minutes, the whole chime set is most of an hour.
            </p>
          </header>

          <div class="flex flex-col gap-4 px-5 py-5 text-sm">
            <form phx-submit="clip_make" class="flex flex-col gap-3">
              <textarea
                name="clip[text]"
                rows="2"
                maxlength="400"
                placeholder="Something you'd actually say."
                class="textarea textarea-bordered w-full text-sm"
              ><%= @clip_text %></textarea>

              <div class="flex flex-wrap items-center gap-3">
                <button type="submit" disabled={not @engine.available?} class="btn btn-primary btn-sm">
                  <.icon name="hero-speaker-wave" class="size-4" /> Make it
                </button>
                <span :if={not Config.cloning?()} class="text-xs text-base-content/55">
                  No recording yet — this will use a designed voice, not yours.
                </span>
                <span class="text-xs text-base-content/70">{@clip_note}</span>
              </div>
            </form>

            <ul :if={@clips != []} class="flex flex-col gap-2 border-t-2 border-base-content/10 pt-4">
              <li :for={clip <- @clips} class="flex flex-wrap items-center gap-3">
                <audio
                  controls
                  preload="none"
                  src={~p"/voice-audio/#{clip.name}"}
                  class="h-8 max-w-xs"
                >
                </audio>
                <span class="min-w-0 flex-1 truncate">{clip.text}</span>
                <button
                  type="button"
                  phx-click="clip_forget"
                  phx-value-path={clip.path}
                  class="btn btn-ghost btn-xs"
                >
                  Forget
                </button>
              </li>
            </ul>
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

        <div class="ic-panel overflow-hidden">
          <header class="border-b-2 border-base-content/20 px-5 py-4">
            <p class="ic-eyebrow">Phone</p>
            <h2 class="font-display text-2xl font-black uppercase tracking-tight">
              What callers hear
            </h2>
            <p class="mt-1 text-sm text-base-content/65">
              Right now anyone phoning your number hears Amazon's synthesized voice. This
              records the greeting in <strong>your</strong>
              voice instead. It is one recording, instructions included —
              a greeting in your voice followed by a robot reading the access-code prompt
              is worse than all-robot, so the whole line is yours to write.
            </p>
          </header>

          <div class="flex flex-col gap-4 px-5 py-5 text-sm">
            <div class="flex items-center gap-3">
              <%= cond do %>
                <% @greeting_status.stale? -> %>
                  <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-warning" />
                  <span>
                    Published — but <strong>callers hear the old recording</strong>.
                    You have edited the words since. Publish again to catch them up.
                  </span>
                <% @greeting_status.published? -> %>
                  <.icon name="hero-check-circle" class="size-5 shrink-0 text-primary" />
                  <span>Published. This is what callers hear.</span>
                <% true -> %>
                  <.icon name="hero-x-circle" class="size-5 shrink-0 text-base-content/40" />
                  <span class="text-base-content/70">
                    Not published — callers hear the synthesized voice.
                  </span>
              <% end %>
            </div>

            <form phx-submit="greeting-save" class="flex flex-col gap-3">
              <textarea
                name="greeting"
                rows="3"
                maxlength="600"
                class="textarea textarea-bordered w-full text-sm"
              ><%= @greeting_text %></textarea>

              <div class="flex flex-wrap items-center gap-3">
                <button type="submit" class="btn btn-primary btn-sm">Save wording</button>

                <button
                  type="button"
                  phx-click="greeting-publish"
                  disabled={not @engine.available?}
                  data-claw-confirm="This changes what every caller hears when they phone your number. Record and publish it?"
                  class="btn btn-ghost btn-sm"
                >
                  <.icon name="hero-phone-arrow-up-right" class="size-4" /> Record and publish
                </button>

                <button
                  :if={@greeting_status.published?}
                  type="button"
                  phx-click="greeting-unpublish"
                  data-claw-confirm="Callers will go back to the synthesized voice. Take it down?"
                  class="btn btn-ghost btn-sm"
                >
                  Take it down
                </button>

                <span class="text-xs text-base-content/60">{@greeting_note}</span>
              </div>
            </form>

            <p :if={not @engine.available?} class="text-xs text-base-content/55">
              Recording needs the engine above. The wording can be saved without it.
            </p>
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

  defp peak_hint(peak) when peak < 0.1, do: " It is quiet — closer to the mic next time."
  defp peak_hint(_peak), do: ""

  defp humanize(:reference_audio), do: "Reference clip"
  defp humanize(:inference_timesteps), do: "Steps"
  defp humanize(:cfg_value), do: "Guidance"
  defp humanize(:engine_path), do: "Engine path"
  defp humanize(field), do: field |> to_string() |> String.capitalize()

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
