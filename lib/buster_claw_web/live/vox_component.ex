defmodule BusterClawWeb.VoxComponent do
  @moduledoc """
  Vox — everything the app's voice is made of, in one embeddable surface.

  Nine panels in three acts: **train** it (the engine, its settings, and a
  recording of your own voice), **make** phrases with it, and **assign** those
  phrases to the places they will be heard — the notification chimes and the
  phone greeting.

  ## An embeddable component, and why

  This renders inline with no layout of its own, so a host page provides the
  chrome. Two hosts use it: `BusterClawWeb.VoiceLive` (the `/voice` route, which
  the Settings rail points at) and `BusterClawWeb.StatusLive` (the homepage "Vox"
  sub-tab). Keeping the behavior here means both surfaces stay in sync — the same
  reason `PhoneComponent` and `CalendarComponent` exist, and the shape
  `VOX_TAB_ROADMAP` `D2` asks for by name.

  ## The host contract

  A `LiveComponent` has no process, so it cannot subscribe and it cannot receive
  a message. **The host subscribes and forwards**, through `notify/2` so no host
  has to hand-roll the message shapes. Two things arrive that way:

    * `{:voice_render, key, result}` — a `Voice.Renderer` job landed. The host
      holds the `Renderer.subscribe/0`.
    * `{:task, ref, result}` — a reply from one of the two long operations below.

  Hosts deliberately subscribe rather than having this component call
  `Renderer.subscribe/0` in `update/2`: a component shares its host's process, so
  a host that already subscribes would receive every broadcast twice.

  ## Why the task replies need forwarding too

  `chime-render-all` is tens of minutes of work, so it runs in a `Task`. A
  component shares its host's process, which means `Task.async/1` here monitors
  from the **host**, and the `{ref, result}` reply lands in the *host's* mailbox
  rather than anywhere this module can see. Hence the second forwarded shape.

  A host may run tasks of its own, so this never assumes an unrecognised ref is
  ours: `handle_notify/2` checks the ref against the one we started and silently
  drops anything else.
  """
  use BusterClawWeb, :live_component

  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Voice.Chimes
  alias BusterClaw.Voice.Clips
  alias BusterClaw.Voice.Config
  alias BusterClaw.Voice.Engine
  alias BusterClaw.Voice.Greeting
  alias BusterClaw.Voice.Reference

  @doc """
  Forward a host's `Voice.Renderer` broadcast, or a `Task` reply. See the
  moduledoc: the host owns the subscription and the mailbox, this component owns
  the response.
  """
  def notify(id, message), do: send_update(__MODULE__, id: id, notify: message)

  @impl true
  def update(%{notify: message}, socket), do: {:ok, handle_notify(message, socket)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns[:loaded] do
      {:ok, socket}
    else
      {:ok, socket |> assign(:loaded, true) |> load_initial()}
    end
  end

  # Every read here touches the disk (the recordings dir, the clip manifest, the
  # chime cache), so it runs once on first update rather than on every parent
  # re-render. That matters more on the homepage than it did on a settings route:
  # StatusLive re-renders on every streamed chat token.
  defp load_initial(socket) do
    socket
    |> assign(:engine, Engine.probe())
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
    |> load_clips()
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
    {:noreply, assign(socket, :engine, Engine.refresh())}
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
           "Expect tens of minutes; you can leave this tab."
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

  # --- what the host forwards --------------------------------------------------

  # A Renderer job landed. Which of the three things it was is decided by the
  # bookkeeping maps, not by the renderer, which addresses everything by content
  # hash and knows nothing about greetings, clips or chimes.
  defp handle_notify({:voice_render, render_key, result}, socket) when is_binary(render_key) do
    cond do
      render_key == socket.assigns.greeting_job ->
        socket = assign(socket, :greeting_job, nil)

        case result do
          {:ok, path} ->
            socket |> publish_greeting(path) |> load_greeting()

          {:error, reason} ->
            assign(socket, :greeting_note, "Recording failed: #{inspect(reason)}")
        end

      Map.has_key?(socket.assigns.clip_jobs, render_key) ->
        {text, jobs} = Map.pop(socket.assigns.clip_jobs, render_key)
        socket = assign(socket, :clip_jobs, jobs)

        case result do
          {:ok, path} ->
            Clips.record(text, path)
            socket |> load_clips() |> assign(:clip_note, "Made: “#{text}”")

          {:error, reason} ->
            assign(socket, :clip_note, "“#{text}” failed: #{inspect(reason)}")
        end

      true ->
        chime_render(render_key, result, socket)
    end
  end

  # A `Task` we started replied. `Process.demonitor/2` is correct here even though
  # this is a component: a component runs *in* its host's process, so the monitor
  # being flushed is the one `Task.async/1` installed a few lines above.
  #
  # An unrecognised ref belongs to the host, not to us. Dropping it is the whole
  # reason both refs are tracked explicitly.
  defp handle_notify({:task, ref, result}, socket) when is_reference(ref) do
    if ref == socket.assigns.chime_task do
      Process.demonitor(ref, [:flush])
      socket = assign(socket, :chime_task, nil)

      case result do
        {:ok, results} -> install_set(socket, results)
        {:error, reason} -> assign(socket, :chime_note, "Failed: #{inspect(reason)}")
      end
    else
      socket
    end
  end

  defp handle_notify(_message, socket), do: socket

  defp chime_render(render_key, result, socket) do
    case Map.pop(socket.assigns.chime_jobs, render_key) do
      {nil, _jobs} ->
        # Somebody else's render. The topic is shared.
        socket

      {chime_key, jobs} ->
        note =
          case result do
            {:ok, path} ->
              Chimes.install(chime_key, path)
              "Installed #{Sound.route_label(chime_key)}."

            {:error, reason} ->
              "#{Sound.route_label(chime_key)} failed: #{inspect(reason)}"
          end

        socket |> assign(:chime_jobs, jobs) |> assign(:chime_note, note) |> load_chimes()
    end
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
  def render(assigns) do
    ~H"""
    <div class="ic-vox ic-panel">
      <%!-- Four acts, in the order the work happens: teach it a voice, make
            something with it, put that somewhere, and — separately — the Mac's
            own synthesizer that reads chat aloud. The act labels are sticky, so
            scrolling nine sections never loses which half of the surface you are
            in. See `.ic-vox` in app.css for why this is hairlines rather than
            nine bordered cards. --%>
      <p class="ic-vox-act">Train</p>

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
              phx-target={@myself}
              class="btn btn-ghost btn-xs"
            >
              Check again
            </button>
          </div>
        </div>
      </section>

      <section class="ic-vox-section">
        <h3>How it speaks</h3>
        <p class="ic-vox-hint">
          Blank means the engine's own default. The one that matters is the reference clip — point
          it at your voice and every line is spoken in it.
        </p>

        <form
          phx-submit="engine-config-save"
          phx-target={@myself}
          class="flex flex-col gap-3 text-sm"
        >
          <label class="flex flex-col gap-1">
            <span class="ic-eyebrow">Reference clip</span>
            <input
              type="text"
              name="config[reference_audio]"
              value={@engine_config.reference_audio}
              placeholder="~/Desktop/me-ten-seconds.wav"
              class="input input-bordered input-sm w-full font-mono text-xs"
            />
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

          <div class="grid gap-3 sm:grid-cols-3">
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
                placeholder="default"
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
                placeholder="default"
                class="input input-bordered input-sm font-mono text-xs"
              />
            </label>
          </div>

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

          <div class="flex flex-wrap items-center gap-2">
            <button type="submit" class="btn btn-primary btn-xs">Save</button>
            <button
              type="button"
              phx-click="engine-config-reset"
              phx-target={@myself}
              class="btn btn-ghost btn-xs"
            >
              Engine defaults
            </button>
            <span class="ic-vox-note">{@config_note}</span>
          </div>

          <p class="ic-vox-note">
            {elem(@chimes_made, 0)} of {elem(@chimes_made, 1)} chimes are made with these settings.<span :if={
              elem(@chimes_made, 0) < elem(@chimes_made, 1)
            }>
              Changing the voice remakes all of them.</span>
          </p>
        </form>
      </section>

      <section class="ic-vox-section">
        <h3>Record it once</h3>
        <p class="ic-vox-hint">
          Ten seconds of you talking normally. There is no training step: the recording
          <strong>is</strong>
          the learning, and the moment it saves every chime, clip and greeting is spoken in your
          voice.
        </p>

        <div class="flex flex-col gap-3 text-sm">
          <p class="border-l-2 border-base-content/20 pl-3 text-sm italic text-base-content/70">
            “The quick way to check a microphone is to read a sentence you didn't write,
            at the speed you'd say it to a friend across a kitchen.”
          </p>

          <%!-- phx-update="ignore": the hook owns this subtree — the meter, the
                status line, the button label — and a LiveView re-render must not
                wipe them mid-take. Same discipline as the Studio's recorder.

                `phx-target` is what routes the hook's two pushes at this component
                rather than at the host LiveView. A container's ATTRIBUTES still
                patch when its children are ignored, so the two directives do not
                fight. See `voice_recorder.js`: it pushes with `pushEventTo(this.el,
                …)`, which resolves to the LiveView when no `phx-target` is present
                — which is how the Studio's recorder keeps working untouched. --%>
          <div
            id={"#{@id}-recorder"}
            phx-hook="VoiceRecorder"
            phx-update="ignore"
            phx-target={@myself}
            data-event-take="reference_take"
            data-event-report="reference_report"
            class="flex flex-col gap-2"
          >
            <div data-role="format" class="font-mono text-[0.625rem] text-base-content/55">
              opening the microphone…
            </div>

            <div class="relative h-2 overflow-hidden rounded-sm bg-base-300">
              <div data-role="target-zone" class="absolute inset-y-0 bg-success/25"></div>
              <div
                data-role="meter"
                class="relative h-full w-0 bg-success transition-[width] duration-75"
              >
              </div>
            </div>

            <div class="flex flex-wrap items-center gap-2 font-mono text-[0.6875rem]">
              <button type="button" data-role="record" class="btn btn-primary btn-xs">
                ● Record
              </button>
              <span data-role="peak" class="text-base-content/55">peak —</span>
              <span data-role="clip" class="text-error" hidden>clipped</span>
              <span data-role="status" class="text-base-content/55"></span>
            </div>
          </div>

          <p :if={match?({"denied", _}, @mic_state)} class="ic-vox-note text-error">
            The microphone was refused. macOS asks once — System Settings → Privacy &amp;
            Security → Microphone, and allow Buster Claw.
          </p>
          <p :if={match?({"unsupported", _}, @mic_state)} class="ic-vox-note">
            No microphone here. Recording works in the desktop app, not in a browser tab.
          </p>

          <span class="ic-vox-note">{@ref_note}</span>

          <ul :if={@references != []} class="flex flex-col gap-1.5">
            <li :for={ref <- @references} class="flex flex-wrap items-center gap-2">
              <audio
                controls
                preload="none"
                src={~p"/voice-audio/#{ref.name}"}
                class="h-7 max-w-[15rem]"
              >
              </audio>
              <span class="font-mono text-[0.6875rem] text-base-content/55">{ref.name}</span>
              <span :if={ref.current?} class="text-[0.6875rem] text-primary">in use</span>
              <button
                :if={not ref.current?}
                type="button"
                phx-click="reference_use"
                phx-target={@myself}
                phx-value-name={ref.name}
                class="btn btn-ghost btn-xs"
              >
                Use this one
              </button>
              <button
                type="button"
                phx-click="reference_delete"
                phx-target={@myself}
                phx-value-name={ref.name}
                data-claw-confirm={"Delete #{ref.name}?" <> if(ref.current?, do: " It is the voice in use — renders go back to a designed voice.", else: "")}
                class="btn btn-ghost btn-xs text-error"
              >
                Delete
              </button>
            </li>
          </ul>
        </div>
      </section>

      <p class="ic-vox-act">Make</p>

      <section class="ic-vox-section">
        <h3>Hear yourself</h3>
        <p class="ic-vox-hint">
          Type a line and it comes back in your voice — the fastest way to judge a recording.
        </p>

        <div class="flex flex-col gap-3 text-sm">
          <form phx-submit="clip_make" phx-target={@myself} class="flex flex-col gap-2">
            <textarea
              name="clip[text]"
              rows="2"
              maxlength="400"
              placeholder="Something you'd actually say."
              class="textarea textarea-bordered w-full text-sm"
            ><%= @clip_text %></textarea>

            <div class="flex flex-wrap items-center gap-2">
              <button type="submit" disabled={not @engine.available?} class="btn btn-primary btn-xs">
                Make it
              </button>
              <span :if={not Config.cloning?()} class="ic-vox-note">
                No recording yet — a designed voice, not yours.
              </span>
              <span class="ic-vox-note">{@clip_note}</span>
            </div>
          </form>

          <ul :if={@clips != []} class="flex flex-col gap-1.5">
            <li :for={clip <- @clips} class="flex flex-wrap items-center gap-2">
              <audio
                controls
                preload="none"
                src={~p"/voice-audio/#{clip.name}"}
                class="h-7 max-w-[15rem]"
              >
              </audio>
              <span class="min-w-0 flex-1 truncate text-xs">{clip.text}</span>
              <button
                type="button"
                phx-click="clip_forget"
                phx-target={@myself}
                phx-value-path={clip.path}
                class="btn btn-ghost btn-xs"
              >
                Forget
              </button>
            </li>
          </ul>
        </div>
      </section>

      <p class="ic-vox-act">Assign</p>

      <section class="ic-vox-section">
        <h3>What it says</h3>
        <p class="ic-vox-hint">
          One line per notification. Each is made once and kept, so nothing renders while a timer
          is going off.
        </p>

        <form phx-submit="chime-lines-save" phx-target={@myself} class="flex flex-col gap-3">
          <div class="ic-vox-lines">
            <%!-- Three columns rather than sixteen flex rows that each decide
                  their own width: at this density the labels not lining up is
                  the first thing the eye catches.

                  The per-row wrapper is `display: contents` so the three cells
                  are the grid's items, not the wrapper. `:for` has to wrap SOME
                  element, and the tempting one — `<template>` — is a trap: its
                  contents are inert, so the rows would render invisible and the
                  inputs would never submit, while every string assertion in the
                  suite still passed because the markup is present in the HTML. --%>
            <div :for={row <- @chimes} class="ic-vox-line">
              <span class="font-mono text-[0.6875rem] uppercase tracking-wide text-base-content/55">
                {row.label}
              </span>
              <input
                type="text"
                name={"lines[#{row.key}]"}
                value={row.line}
                maxlength="120"
                class="input input-bordered input-xs min-w-0 text-sm"
              />
              <span class="w-4 text-primary">
                <.icon :if={row.installed?} name="hero-check" class="size-3.5" />
              </span>
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <button type="submit" class="btn btn-primary btn-xs">Save lines</button>
            <button
              type="button"
              phx-click="chime-lines-reset"
              phx-target={@myself}
              class="btn btn-ghost btn-xs"
            >
              Reset
            </button>
            <button
              type="button"
              phx-click="chime-render-all"
              phx-target={@myself}
              disabled={not @engine.available?}
              class="btn btn-ghost btn-xs"
            >
              Speak them
            </button>
            <span class="ic-vox-note">{@chime_note}</span>
          </div>

          <p :if={not @engine.available?} class="ic-vox-note">
            Editing works without an engine — speaking them needs one.
          </p>
        </form>
      </section>

      <section class="ic-vox-section">
        <h3>What callers hear</h3>
        <p class="ic-vox-hint">
          The phone greeting, in your voice instead of Amazon's. It is one recording, instructions
          included — the whole line is yours to write.
        </p>

        <div class="flex flex-col gap-3 text-sm">
          <div class="flex items-center gap-2">
            <%= cond do %>
              <% @greeting_status.stale? -> %>
                <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-warning" />
                <span class="ic-vox-note">
                  Published — but callers hear the old recording. Publish again.
                </span>
              <% @greeting_status.published? -> %>
                <.icon name="hero-check-circle" class="size-4 shrink-0 text-primary" />
                <span class="ic-vox-note">Published. This is what callers hear.</span>
              <% true -> %>
                <.icon name="hero-x-circle" class="size-4 shrink-0 text-base-content/40" />
                <span class="ic-vox-note">
                  Not published — callers hear the synthesized voice.
                </span>
            <% end %>
          </div>

          <form phx-submit="greeting-save" phx-target={@myself} class="flex flex-col gap-2">
            <textarea
              name="greeting"
              rows="3"
              maxlength="600"
              class="textarea textarea-bordered w-full text-sm"
            ><%= @greeting_text %></textarea>

            <div class="flex flex-wrap items-center gap-2">
              <button type="submit" class="btn btn-primary btn-xs">Save wording</button>

              <button
                type="button"
                phx-click="greeting-publish"
                phx-target={@myself}
                disabled={not @engine.available?}
                data-claw-confirm="This changes what every caller hears when they phone your number. Record and publish it?"
                class="btn btn-ghost btn-xs"
              >
                Record and publish
              </button>

              <button
                :if={@greeting_status.published?}
                type="button"
                phx-click="greeting-unpublish"
                phx-target={@myself}
                data-claw-confirm="Callers will go back to the synthesized voice. Take it down?"
                class="btn btn-ghost btn-xs"
              >
                Take it down
              </button>

              <span class="ic-vox-note">{@greeting_note}</span>
            </div>
          </form>

          <p :if={not @engine.available?} class="ic-vox-note">
            Recording needs the engine above. The wording can be saved without it.
          </p>
        </div>
      </section>

      <%!-- A different engine entirely, and last for that reason: everything
            above is VoxCPM making a file, this is the Mac's own synthesizer
            reading chat as it arrives. Keeping them on one surface was the
            operator's call (`D1`); keeping them in one ACT would have been a
            claim that they are the same feature. --%>
      <p class="ic-vox-act">Reading aloud</p>

      <section class="ic-vox-section">
        <h3>Spoken replies</h3>
        <p class="ic-vox-hint">
          Your Mac's own speech synthesizer reads each reply as it arrives — <strong>on-device</strong>, nothing is sent anywhere. Toggle
          <strong>Voice on / off</strong>
          in the chat header; a new message stops whatever is being spoken. macOS desktop app only.
        </p>
      </section>

      <%!-- The picker's DOM id is namespaced by the component id: two hosts render
            this surface, and `SplitLive` can put both on one page. A duplicate id
            would leave `VoicePicker` bound to whichever half mounted first. --%>
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
    </div>
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
end
